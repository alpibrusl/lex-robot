#!/usr/bin/env python3
"""Measure a joint's real, collision-free travel — and be honest about why it stopped.

Written after an ad-hoc version of this repeatedly reported phantom mechanical
stops. It swept ~1100 ticks one way, waited a FIXED 0.9 s, then began probing
the other direction — but the arm was still travelling back, so `|goal - pos|`
was hundreds of ticks and the stall test fired on the first sample. Every
"inward hard stop at 0 ticks, load 300" was the arm in transit. The operator
twice said the arms turned freely both ways, and was right both times.

Two rules follow, and they are the whole point of this file:

  1. NEVER infer arrival from elapsed time. `settle_to` polls the encoder until
     the joint is actually within tolerance of the target, or gives up loudly.
  2. NEVER call a stall on one sample. A stall must persist for
     `stall_confirm` consecutive reads; one transient bus hiccup is not a wall.

It also separates the two reasons a joint stops, which the old version conflated:
a SOFTWARE limit (the servo's own Min/Max_Position_Limit, recorded by lerobot's
calibration) and a MECHANICAL stop (something physically in the way). Only the
second is a property of the robot's surroundings.

Probing runs at reduced torque so meeting an obstruction is a gentle give
rather than a grind, and the joint's torque limit, position and torque state
are all restored on the way out, including on error.

    python sidecar/probe_range.py --port /dev/cu.usbmodem5B3D0437151
    python sidecar/probe_range.py --port /dev/cu.usbmodem5B610332201 --joint shoulder_lift
"""

from __future__ import annotations

import argparse
import time
from dataclasses import dataclass

TICKS_PER_REV = 4096
MODEL = "sts3215"

SOFTWARE_LIMIT = "software limit"
MECHANICAL_STOP = "mechanical stop"
TRAVEL_CAP = "travel cap"


def ticks_to_deg(t: float) -> float:
    return t * 360.0 / TICKS_PER_REV


class StallDetector:
    """Turns a stream of (goal, position) samples into a stall verdict.

    Requires `confirm` CONSECUTIVE samples over the error threshold. A single
    sample is never enough: a joint that is merely lagging — accelerating, or
    still returning from a previous sweep — briefly looks identical to one that
    is jammed, and that confusion is exactly what produced false stops before.
    """

    def __init__(self, error_threshold: int = 35, confirm: int = 3):
        self.error_threshold = error_threshold
        self.confirm = confirm
        self.streak = 0
        self.worst = 0

    def update(self, goal: int, position: int) -> bool:
        err = abs(goal - position)
        self.worst = max(self.worst, err)
        self.streak = self.streak + 1 if err > self.error_threshold else 0
        return self.streak >= self.confirm

    @property
    def stalled(self) -> bool:
        return self.streak >= self.confirm


@dataclass
class DirectionResult:
    direction: int
    start: int
    end: int
    reason: str
    detail: str
    peak_load: int

    @property
    def ticks(self) -> int:
        return abs(self.end - self.start)

    @property
    def degrees(self) -> float:
        return ticks_to_deg(self.ticks)


class RangeProbe:
    """Probes one joint in both directions on an already-connected bus."""

    def __init__(self, bus, joint, *, probe_torque=400, step=15, dwell_s=0.12,
                 error_threshold=35, stall_confirm=3, travel_cap=3000,
                 settle_tol=20, settle_timeout_s=40.0):
        self.bus, self.joint = bus, joint
        self.probe_torque, self.step, self.dwell_s = probe_torque, step, dwell_s
        self.error_threshold, self.stall_confirm = error_threshold, stall_confirm
        self.travel_cap = travel_cap
        self.settle_tol, self.settle_timeout_s = settle_tol, settle_timeout_s

    # -- raw access ----------------------------------------------------------

    def _r(self, reg):
        return self.bus.read(reg, self.joint, normalize=False)

    def _w(self, reg, val):
        self.bus.write(reg, self.joint, int(val), normalize=False)

    # -- the rule that was missing -------------------------------------------

    def settle_to(self, target: int) -> bool:
        """Command *target* and wait until the joint has ACTUALLY arrived.

        Returns False on timeout rather than proceeding — a probe that starts
        from an unknown position measures nothing.
        """
        self._w("Goal_Position", target)
        deadline = time.time() + self.settle_timeout_s
        while time.time() < deadline:
            if abs(self._r("Present_Position") - target) <= self.settle_tol:
                time.sleep(0.3)          # let the last bit of overshoot damp out
                return True
            time.sleep(0.2)
        return False

    # -- one direction -------------------------------------------------------

    def probe_direction(self, direction: int, lo: int, hi: int) -> DirectionResult:
        base = self._r("Present_Position")
        det = StallDetector(self.error_threshold, self.stall_confirm)
        goal = reached = base
        peak_load = 0
        reason, detail = TRAVEL_CAP, f"no stop within {self.travel_cap} ticks"

        while abs(goal - base) < self.travel_cap:
            nxt = goal + direction * self.step
            if not (lo <= nxt <= hi):
                reason = SOFTWARE_LIMIT
                detail = f"servo's own limit ({lo if direction < 0 else hi})"
                break
            goal = nxt
            self._w("Goal_Position", goal)
            time.sleep(self.dwell_s)
            pos = self._r("Present_Position")
            peak_load = max(peak_load, abs(self._r("Present_Load")))
            if det.update(goal, pos):
                reason = MECHANICAL_STOP
                detail = f"tracking error {det.worst} ticks over {det.confirm} samples, load {peak_load}"
                break
            reached = pos
        return DirectionResult(direction, base, reached, reason, detail, peak_load)

    # -- both, restoring everything -----------------------------------------

    def run(self) -> dict:
        home = self._r("Present_Position")
        lo, hi = self._r("Min_Position_Limit"), self._r("Max_Position_Limit")
        prev_torque_limit = self._r("Torque_Limit")
        prev_torque = self._r("Torque_Enable")
        out = {"joint": self.joint, "home": home, "limits": (lo, hi), "directions": {}}
        try:
            self._w("Torque_Limit", self.probe_torque)
            self._w("Goal_Position", home)
            self._w("Torque_Enable", 1)
            time.sleep(0.4)
            for direction, label in ((1, "increasing"), (-1, "decreasing")):
                if not self.settle_to(home):
                    out["directions"][label] = None      # never guess from a bad start
                    continue
                out["directions"][label] = self.probe_direction(direction, lo, hi)
                self.settle_to(home)
        finally:
            self.settle_to(home)
            self._w("Torque_Limit", prev_torque_limit)
            self._w("Torque_Enable", prev_torque)
            out["restored_to"] = self._r("Present_Position")
            out["temperature_c"] = self._r("Present_Temperature")
        return out


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--port", required=True)
    p.add_argument("--joint", default="shoulder_pan")
    p.add_argument("--id", type=int, default=1, help="servo id of --joint")
    p.add_argument("--torque", type=int, default=400, help="probe Torque_Limit out of 1000")
    p.add_argument("--cap", type=int, default=3000, help="max ticks to explore per direction")
    a = p.parse_args()

    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    bus = FeetechMotorsBus(port=a.port,
                           motors={a.joint: Motor(a.id, MODEL, MotorNormMode.DEGREES)})
    bus.connect(handshake=False)
    try:
        res = RangeProbe(bus, a.joint, probe_torque=a.torque, travel_cap=a.cap).run()
        lo, hi = res["limits"]
        print(f"{a.joint} on {a.port}")
        print(f"  home {res['home']}   servo limits [{lo}, {hi}] "
              f"= {hi - lo} ticks / {ticks_to_deg(hi - lo):.1f} deg")
        ends = []
        for label, r in res["directions"].items():
            if r is None:
                print(f"  {label:<11} FAILED to return to home; not measured")
                continue
            ends.append(r.end)
            print(f"  {label:<11} {r.ticks:>4} ticks / {r.degrees:>5.1f} deg "
                  f"[ends {r.end}]  {r.reason}: {r.detail}  peak load {r.peak_load}")
        if len(ends) == 2:
            span = abs(ends[0] - ends[1])
            print(f"  => usable span {min(ends)} .. {max(ends)} "
                  f"= {span} ticks / {ticks_to_deg(span):.1f} deg")
        print(f"  restored to {res['restored_to']}, {res['temperature_c']}C")
    finally:
        bus.disconnect()


if __name__ == "__main__":
    main()
