#!/usr/bin/env python3
"""Pan/tilt driver for the XLeRobot's central camera tower (servos 7, 8).

`SIDECAR.md` has listed these servos as having "no code path at all" since they
were assigned IDs. This fills that gap. The immediate reason is not looking
around — it is that **the head camera rides this tower, and the tower ships
limp** (`Torque_Enable=0`). A camera on an unpowered pan/tilt mount can sag or
be knocked, and `vision_reset_teleop` assumes a STATIC `CameraModel`: if the
tower moves after calibration, `project_to_plane` keeps returning confidently
wrong world positions with nothing to signal it. `hold()` is therefore the
load-bearing method here — lock the tower at a known pose, then calibrate.

Shared bus, same discipline as the base (#145). On this unit the tower servos
sit on the *left arm's* physical bus, so this reuses that arm's already-
connected `FeetechMotorsBus` and NEVER touches its `.motors`/`.calibration`
dicts. Those belong to the owning `SO101Follower`, whose `get_observation()`
sync-reads the calibration-normalized `Present_Position` for every motor in
`.motors` with no explicit list — registering the tower there would KeyError
the moment anything polled arm pose. All access here goes through the bus's
private ID-based primitives (`_read`/`_write` with addresses resolved once via
`get_address`), which never consult those dicts.

Units: the tower is UNCALIBRATED (`Homing_Offset=85`, range `[0, 4095]` —
factory defaults, no calibration sweep has been run on it). So ticks are the
honest unit, and the degree helpers are relative to a documented reference of
tick 2048 == 0 deg. They are NOT anchored to any mechanical zero until someone
calibrates the tower.

Which servo is pan and which is tilt is NOT established — both are plausible
and it was never recorded. Defaults are pan=7, tilt=8; verify by moving one and
watching which way the head camera view shifts (horizontal => pan).

    python sidecar/tower.py --port /dev/cu.usbmodem5B3D0437151 --read
    python sidecar/tower.py --port /dev/cu.usbmodem5B3D0437151 --hold
    python sidecar/tower.py --port /dev/cu.usbmodem5B3D0437151 --pan 1600 --tilt 2800
"""

from __future__ import annotations

import argparse
import logging
import time

logger = logging.getLogger(__name__)

MODEL = "sts3215"
TICKS_PER_REV = 4096
CENTRE_TICKS = 2048

# Envelopes, from a bench probe at reduced torque (Torque_Limit 300/1000,
# 15-tick steps, stall detected by position-tracking error).
#
# TILT HAS A REAL MECHANICAL STOP AT 2483 ticks (+38.2 deg): the servo stopped
# tracking with 46 ticks of error at load 300. The minimum below leaves a 40-
# tick margin above it. An earlier version of this file applied one symmetric
# +/-90 deg envelope to BOTH axes, which allowed commanding tilt down to 1024 --
# straight through that stop and into a stall. Per-axis limits are not a nicety.
#
# The other three bounds were NOT found: the probe hit its own +/-600-tick
# excursion cap first, so these are "verified traversable", not measured limits.
# The real stops are somewhere beyond. Widening is a deliberate decision, not a
# default, because the failure mode out there is straining the head camera's
# USB cable -- which no servo-side protection detects.
TILT_HARD_STOP_MIN = 2483          # measured; do not command below this
DEFAULT_PAN_LIMITS = (1000, 2100)          # traversed clean; true stops unknown
DEFAULT_TILT_LIMITS = (TILT_HARD_STOP_MIN + 40, 3400)   # (2523, 3400)


# ── pure helpers (no hardware; unit-tested in test_tower.py) ────────────────

def ticks_to_deg(ticks: float) -> float:
    """Degrees relative to tick 2048. Not a mechanical zero — see module docs."""
    return (ticks - CENTRE_TICKS) * 360.0 / TICKS_PER_REV


def deg_to_ticks(deg: float) -> int:
    return int(round(CENTRE_TICKS + deg * TICKS_PER_REV / 360.0))


def clamp_ticks(ticks: float, limits: tuple[int, int]) -> int:
    lo, hi = limits
    return int(round(min(max(ticks, lo), hi)))


def plan_steps(start: int, target: int, step: int) -> list[int]:
    """Intermediate goals from *start* to *target*, at most *step* ticks apart.

    Stepping keeps the motion slow by construction regardless of the servo's
    speed setting — the same approach used to jog the arms safely — which
    matters because this mount carries the camera and its cable.
    """
    if step <= 0:
        raise ValueError("step must be positive")
    if start == target:
        return [target]
    direction = 1 if target > start else -1
    out, cur = [], start
    while cur != target:
        cur += direction * min(step, abs(target - cur))
        out.append(cur)
    return out


# ── the driver ──────────────────────────────────────────────────────────────

class TowerDriver:
    """Position-mode control of the two tower servos over a (possibly shared) bus."""

    def __init__(self, shared_bus=None, port=None, pan_id=7, tilt_id=8,
                 pan_limits=DEFAULT_PAN_LIMITS, tilt_limits=DEFAULT_TILT_LIMITS,
                 step_ticks=15, dwell_s=0.05):
        if (port is None) == (shared_bus is None):
            raise ValueError("TowerDriver needs exactly one of port or shared_bus")
        from lerobot.motors.feetech import FeetechMotorsBus
        from lerobot.motors.motors_bus import get_address

        self.pan_id, self.tilt_id = pan_id, tilt_id
        self.pan_limits, self.tilt_limits = tuple(pan_limits), tuple(tilt_limits)
        self.step_ticks, self.dwell_s = step_ticks, dwell_s
        self._owns_bus = shared_bus is None
        if shared_bus is not None:
            self.bus = shared_bus
        else:
            self.bus = FeetechMotorsBus(port=port, motors={})
            self.bus.connect(handshake=False)

        t = self.bus.model_ctrl_table
        self._a_mode = get_address(t, MODEL, "Operating_Mode")
        self._a_torque = get_address(t, MODEL, "Torque_Enable")
        self._a_goal = get_address(t, MODEL, "Goal_Position")
        self._a_pos = get_address(t, MODEL, "Present_Position")
        self._a_temp = get_address(t, MODEL, "Present_Temperature")

        for sid in (self.pan_id, self.tilt_id):
            self.bus._write(*self._a_mode, sid, 0)          # 0 == position mode

    # -- state ---------------------------------------------------------------

    def _rd(self, addr_len, sid: int) -> int:
        """lerobot's `_read` returns (value, comm_result, error) -- take the value."""
        return self.bus._read(*addr_len, sid)[0]

    def _pos(self, sid: int) -> int:
        return self._rd(self._a_pos, sid)

    def read(self) -> dict:
        pan, tilt = self._pos(self.pan_id), self._pos(self.tilt_id)
        return {
            "pan_ticks": pan, "tilt_ticks": tilt,
            "pan_deg": round(ticks_to_deg(pan), 2), "tilt_deg": round(ticks_to_deg(tilt), 2),
            "pan_temp_c": self._rd(self._a_temp, self.pan_id),
            "tilt_temp_c": self._rd(self._a_temp, self.tilt_id),
            "held": bool(self._rd(self._a_torque, self.pan_id))
                    and bool(self._rd(self._a_torque, self.tilt_id)),
        }

    # -- torque --------------------------------------------------------------

    def hold(self) -> dict:
        """Lock the tower where it is. Goal is synced to present BEFORE torque
        is enabled, so engaging cannot snap the camera to a stale target."""
        for sid in (self.pan_id, self.tilt_id):
            self.bus._write(*self._a_goal, sid, self._pos(sid))
            self.bus._write(*self._a_torque, sid, 1)
        return self.read()

    def release(self) -> dict:
        for sid in (self.pan_id, self.tilt_id):
            self.bus._write(*self._a_torque, sid, 0)
        return self.read()

    # -- motion --------------------------------------------------------------

    def move_to(self, pan_ticks=None, tilt_ticks=None) -> dict:
        """Creep to a clamped target. Either axis may be None to leave it be."""
        targets = []
        if pan_ticks is not None:
            targets.append((self.pan_id, clamp_ticks(pan_ticks, self.pan_limits)))
        if tilt_ticks is not None:
            targets.append((self.tilt_id, clamp_ticks(tilt_ticks, self.tilt_limits)))
        if not targets:
            return self.read()

        for sid, _ in targets:                       # no-jump engage, as in hold()
            self.bus._write(*self._a_goal, sid, self._pos(sid))
            self.bus._write(*self._a_torque, sid, 1)

        plans = {sid: plan_steps(self._pos(sid), tgt, self.step_ticks) for sid, tgt in targets}
        for i in range(max(len(p) for p in plans.values())):
            for sid, plan in plans.items():
                self.bus._write(*self._a_goal, sid, plan[min(i, len(plan) - 1)])
            time.sleep(self.dwell_s)
        time.sleep(0.3)
        return self.read()

    def move_deg(self, pan_deg=None, tilt_deg=None) -> dict:
        return self.move_to(
            None if pan_deg is None else deg_to_ticks(pan_deg),
            None if tilt_deg is None else deg_to_ticks(tilt_deg),
        )

    def close(self) -> None:
        if self._owns_bus:
            self.bus.disconnect()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--port", required=True, help="serial port carrying the tower servos")
    p.add_argument("--pan-id", type=int, default=7)
    p.add_argument("--tilt-id", type=int, default=8)
    p.add_argument("--read", action="store_true")
    p.add_argument("--hold", action="store_true", help="lock at the current pose (do this before calibrating the camera)")
    p.add_argument("--release", action="store_true")
    p.add_argument("--pan", type=int, help="target pan in ticks")
    p.add_argument("--tilt", type=int, help="target tilt in ticks")
    a = p.parse_args()

    d = TowerDriver(port=a.port, pan_id=a.pan_id, tilt_id=a.tilt_id)
    try:
        if a.pan is not None or a.tilt is not None:
            print(d.move_to(a.pan, a.tilt))
        elif a.hold:
            print(d.hold())
        elif a.release:
            print(d.release())
        else:
            print(d.read())
    finally:
        d.close()


if __name__ == "__main__":
    main()
