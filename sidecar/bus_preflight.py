#!/usr/bin/env python3
"""Refuse to start an unattended session on a servo bus that drops responses.

Written after the right bus (`5B61033220`, right arm ids 1-6 plus base wheels
9 and 10) was measured on 2026-08-23 dropping a large fraction of its replies:

    right id 9   55.0% of reads failed        <- base wheel, dominated
    right ids 1-6  18.8% idle, 52.5% under camera load
    left  ids 1-8   0.0% under every condition

lerobot's own handshake is what that breaks first: `_assert_motors_exist` pings
each id exactly once with `num_retry=0`, so three consecutive fresh processes
found `{}`, `{4,5,6}` and `{}` of six motors and `SO101Follower` refused the arm.

Three days later, after a power cycle, the same measurement came back clean --
16,000 reads across both buses under full camera load, zero failures, and 40 of
40 fresh handshakes finding every motor. **That is the reason this file exists.**
A fault that disappears when power drops is not a fixed fault; it is an
intermittent one that happens to be in its good state, and the failure mode
matters more than the odds:

    a bus that drops a reply also drops a COMMANDED POSITION, and a dropped
    command raises nothing at all.

Read failures are loud. Write failures are silent. So an unattended run -- 200
episodes overnight with nobody watching (#153) -- is precisely where a marginal
bus does its damage, and precisely where nobody is present to notice. This gate
converts the silent failure mode into a loud one, BEFORE any torque is enabled.

## What it does, and what it deliberately does not

It pings and it reads. It never writes a register and it never enables torque,
so running it is safe at any time, on any tier, with no hand on the e-stop.

It does NOT retry. That is the whole point and it is worth stating plainly,
because adding `num_retry` here would be the obvious "fix" and it is exactly
wrong: retries would hide the signal the gate exists to detect, and they would
not help the commanded positions that fail silently later. If this gate is
failing, the answer is a physical repair, not a more forgiving gate.

Two independent checks, because they fail differently:

  1. HANDSHAKE -- one ping per id, no retries, on a fresh connection. This is a
     faithful reproduction of what `_assert_motors_exist` does, so a pass here
     means the follower will actually come up.
  2. READ RELIABILITY -- N reads of `Present_Position` per servo, counting
     dropped responses. Catches a bus that answers a single ping but cannot
     sustain traffic, which is what "18.8% idle" looked like.

The default threshold is ZERO failures, which sounds strict and is not: the
measured good state is 0.0% over 16,000 reads and the measured bad state is
55%. There is no observed middle, so anything above zero is a real signal rather
than noise. `--max-fail-pct` exists for a caller who has evidence for a
different number, not as a knob to turn until the gate goes quiet.

Usage:

    python sidecar/bus_preflight.py                      # both buses, exit 1 on failure
    python sidecar/bus_preflight.py --bus right --reads 200
    python sidecar/bus_preflight.py --json              # machine-readable, for run logs

Exit status is the contract, and it separates THREE states rather than two:

    0  every configured bus answered cleanly — safe to start
    1  a bus is DROPPING responses — the fault this file exists for
    2  a bus could not be OPENED — inconclusive, not a verdict

That third case is deliberate and it earned itself immediately: the serial port
is exclusive, so the robot being unplugged, or the sidecar (or a second gate)
already holding the port, all produce "could not open". None of those is a
marginal bus, and reporting them as one would train everybody to ignore the
gate — which is the practical way a safety check dies. A soak run therefore
counts drops and unavailability separately, and only drops make it exit 1.

Shell callers should `set -e` and let it stop them.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

MODEL = "sts3215"

#: Read this many times per servo unless told otherwise. 60 is enough to see a
#: 5% fault with near-certainty and takes well under a second per bus.
DEFAULT_READS = 60

#: Any dropped response fails the gate. See the module docstring for why zero
#: is the honest default rather than a strict one.
DEFAULT_MAX_FAIL_PCT = 0.0

#: Said whenever a bus cannot be opened. The serial port is exclusive, so this
#: is far more often contention or a cable than a fault.
PORT_BUSY_HINT = ("the port is exclusive — check the robot is plugged in, and "
                  "that the sidecar or another bus_preflight is not already "
                  "holding it")

#: The register every servo answers and nothing moves to produce.
PROBE_REGISTER = "Present_Position"

#: Tower pan/tilt servo ids. They share the LEFT arm's physical bus (see
#: SIDECAR.md) and carry the head camera, so their pose is part of the camera
#: calibration's validity rather than a separate concern.
TOWER_PAN_ID, TOWER_TILT_ID = 7, 8

#: How far the tower may drift before the CameraModel calibrated against it is
#: no longer trustworthy. Bench measurement: 70 ticks moved the head camera
#: image by 40 px (pan) and 71 px (tilt), so one tick is roughly one pixel and
#: 8 ticks is a ~5-8 px shift — small enough to tolerate thermal settle, large
#: enough that a knock or a sag fails the check.
TOWER_DEFAULT_TOLERANCE_TICKS = 8

#: Stable per-adapter paths. `/dev/ttyACM*` numbering is assignment-ordered and
#: can swap between boots, which on this robot means the arms silently trading
#: places (see #174).
BY_ID = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_{serial}-if00"

#: name -> (env var, adapter serial, expected ids). Left carries the tower
#: (7, 8); right carries the base wheels (9, 10).
BUS_SPECS = {
    "left":  ("LEX_XLE_LEFT_PORT",  "5B3D043715", (1, 2, 3, 4, 5, 6, 7, 8)),
    "right": ("LEX_XLE_RIGHT_PORT", "5B61033220", (1, 2, 3, 4, 5, 6, 9, 10)),
}


def port_for(name: str) -> str:
    """Where bus `name` lives: the env var if set, else its by-id path."""
    env_var, serial, _ = BUS_SPECS[name]
    return os.environ.get(env_var) or BY_ID.format(serial=serial)


def motor_name(motor_id: int) -> str:
    """The key a bus built by `open_bus` answers to for `motor_id`."""
    return f"m{motor_id}"


@dataclass
class TowerReference:
    """The tower pose a CameraModel was calibrated at.

    The head camera rides the pan/tilt tower, and the tower ships with torque
    OFF. If it sags or is knocked after calibration, `project_to_plane` keeps
    returning confidently wrong world positions and NOTHING signals it — the
    third silent failure mode on this robot, after dropped reads and a wrong
    calibration. Recording the pose next to the calibration makes it checkable.
    """

    pan_ticks: int
    tilt_ticks: int
    pan_id: int = TOWER_PAN_ID
    tilt_id: int = TOWER_TILT_ID
    tolerance_ticks: int = TOWER_DEFAULT_TOLERANCE_TICKS

    @staticmethod
    def from_calibration(path):
        """Read the `tower` block out of a CameraModel JSON. None if absent.

        Absent is not an error: a calibration may predate this check, and a
        missing reference is reported as "not checked" rather than as a pass.
        """
        payload = json.loads(Path(path).read_text())
        block = payload.get("tower")
        if not block:
            return None
        return TowerReference(
            pan_ticks=int(block["pan_ticks"]), tilt_ticks=int(block["tilt_ticks"]),
            pan_id=int(block.get("pan_id", TOWER_PAN_ID)),
            tilt_id=int(block.get("tilt_id", TOWER_TILT_ID)),
            tolerance_ticks=int(block.get("tolerance_ticks",
                                          TOWER_DEFAULT_TOLERANCE_TICKS)))


def check_tower(bus, ref):
    """Read the tower's raw ticks and compare against `ref`. Read-only.

    Returns (reasons, observed). `reasons` empty means the tower is where the
    calibration says it was.
    """
    reasons, observed = [], {}
    for axis, motor_id, want in (("pan", ref.pan_id, ref.pan_ticks),
                                 ("tilt", ref.tilt_id, ref.tilt_ticks)):
        try:
            got = int(bus.read(PROBE_REGISTER, motor_name(motor_id),
                               normalize=False))
        except Exception as exc:
            reasons.append(f"tower {axis} (id {motor_id}) unreadable: "
                           f"{type(exc).__name__}")
            continue
        observed[axis] = got
        drift = abs(got - want)
        if drift > ref.tolerance_ticks:
            reasons.append(
                f"tower {axis} moved {drift} ticks since calibration "
                f"(now {got}, calibrated at {want}, tolerance "
                f"{ref.tolerance_ticks}) — the CameraModel is no longer valid")
    return reasons, observed


@dataclass
class ServoResult:
    """How one servo answered."""

    id: int
    reads: int
    failures: int
    median_ms: float | None = None

    @property
    def fail_pct(self) -> float:
        return 100.0 * self.failures / self.reads if self.reads else 0.0

    def as_dict(self) -> dict:
        return {"id": self.id, "reads": self.reads, "failures": self.failures,
                "fail_pct": round(self.fail_pct, 2), "median_ms": self.median_ms}


@dataclass
class BusResult:
    """How one bus answered, and whether that is good enough to start."""

    name: str
    port: str
    expected_ids: tuple
    handshake_found: tuple = ()
    servos: list = field(default_factory=list)
    #: Set when the bus could not be opened at all — a different failure from
    #: "opened and dropped responses", and reported as such.
    error: str | None = None
    #: Why the tower is not where the camera calibration says. Empty means
    #: either "checked and fine" or "not checked" — `tower_checked` separates
    #: those, because an unchecked tower must not read as a passed tower.
    tower_reasons: list = field(default_factory=list)
    tower_observed: dict = field(default_factory=dict)
    tower_checked: bool = False

    @property
    def missing_ids(self) -> list:
        return [i for i in self.expected_ids if i not in self.handshake_found]

    @property
    def worst_fail_pct(self) -> float:
        return max((s.fail_pct for s in self.servos), default=0.0)

    def reasons(self, max_fail_pct: float = DEFAULT_MAX_FAIL_PCT) -> list:
        """Why this bus is not fit to start. Empty means it is."""
        if self.error:
            return [f"bus could not be opened: {self.error}"]
        out = []
        if self.missing_ids:
            out.append(
                f"handshake found {sorted(self.handshake_found)} — missing "
                f"{self.missing_ids} (SO101Follower would refuse this arm)")
        for s in self.servos:
            if s.fail_pct > max_fail_pct:
                out.append(f"id {s.id} dropped {s.failures}/{s.reads} reads "
                           f"({s.fail_pct:.1f}%)")
        out.extend(self.tower_reasons)
        return out

    def ok(self, max_fail_pct: float = DEFAULT_MAX_FAIL_PCT) -> bool:
        return not self.reasons(max_fail_pct)

    def as_dict(self, max_fail_pct: float = DEFAULT_MAX_FAIL_PCT) -> dict:
        return {"bus": self.name, "port": self.port, "ok": self.ok(max_fail_pct),
                "error": self.error,
                "handshake_found": sorted(self.handshake_found),
                "missing_ids": self.missing_ids,
                "worst_fail_pct": round(self.worst_fail_pct, 2),
                "servos": [s.as_dict() for s in self.servos],
                "tower_checked": self.tower_checked,
                "tower_observed": self.tower_observed,
                "reasons": self.reasons(max_fail_pct)}


def handshake(bus, ids) -> list:
    """lerobot's `_assert_motors_exist`: one ping per id, NO retries.

    Deliberately not `num_retry>0` — see the module docstring.
    """
    found = []
    for motor_id in ids:
        try:
            if bus.ping(motor_id, num_retry=0) is not None:
                found.append(motor_id)
        except Exception:
            pass
    return found


def read_reliability(bus, ids, reads: int) -> list:
    """Read `PROBE_REGISTER` `reads` times per servo, counting dropped replies."""
    out = []
    for motor_id in ids:
        name, failures, latencies = motor_name(motor_id), 0, []
        for _ in range(reads):
            started = time.perf_counter()
            try:
                bus.read(PROBE_REGISTER, name, normalize=False)
                latencies.append((time.perf_counter() - started) * 1000.0)
            except Exception:
                failures += 1
        out.append(ServoResult(
            id=motor_id, reads=reads, failures=failures,
            median_ms=round(statistics.median(latencies), 2) if latencies else None))
    return out


def scan_bus(bus, name: str, port: str, ids, reads: int,
             tower_ref=None) -> BusResult:
    """Run the checks against an already-open `bus`. Never writes.

    `tower_ref` is applied only when this bus actually carries the tower
    servos, so passing one while scanning the right bus is a no-op rather than
    a spurious failure.
    """
    result = BusResult(
        name=name, port=port, expected_ids=tuple(ids),
        handshake_found=tuple(handshake(bus, ids)),
        servos=read_reliability(bus, ids, reads))
    if tower_ref and tower_ref.pan_id in ids and tower_ref.tilt_id in ids:
        result.tower_checked = True
        result.tower_reasons, result.tower_observed = check_tower(bus, tower_ref)
    return result


def open_bus(port: str, ids):
    """Open a real Feetech bus, skipping the handshake we are here to measure.

    lerobot is imported lazily so this module — and its tests — need neither
    lerobot nor hardware.
    """
    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    motors = {motor_name(i): Motor(i, MODEL, MotorNormMode.DEGREES) for i in ids}
    bus = FeetechMotorsBus(port=port, motors=motors)
    bus.connect(handshake=False)
    return bus


def preflight(names, reads: int = DEFAULT_READS, *, opener=None,
              tower_ref=None) -> list:
    """Scan each named bus. `opener(port, ids)` is injectable for tests."""
    opener = opener or open_bus
    results = []
    for name in names:
        _, _, ids = BUS_SPECS[name]
        port = port_for(name)
        try:
            bus = opener(port, ids)
        except Exception as exc:
            results.append(BusResult(name=name, port=port, expected_ids=ids,
                                     error=f"{type(exc).__name__}: {exc}"))
            continue
        try:
            results.append(scan_bus(bus, name, port, ids, reads, tower_ref))
        finally:
            try:
                bus.disconnect()
            except Exception:
                pass
    return results


def render(results, max_fail_pct: float) -> str:
    """Human-readable report."""
    lines = []
    for r in results:
        lines.append(f"\n{r.name.upper()} bus  {r.port}")
        if r.error:
            lines.append(f"  UNAVAILABLE — {r.error}")
            lines.append(f"  ({PORT_BUSY_HINT})")
            continue
        missing = f"  MISSING {r.missing_ids}" if r.missing_ids else "  (all present)"
        lines.append(f"  handshake: found {sorted(r.handshake_found)}{missing}")
        for s in r.servos:
            flag = "   <-- DROPPING" if s.fail_pct > max_fail_pct else ""
            ms = f"{s.median_ms:.2f} ms" if s.median_ms is not None else "n/a"
            lines.append(f"    id {s.id:>2}: {s.fail_pct:5.1f}% fail   "
                         f"median {ms}{flag}")
        if r.tower_checked:
            seen = ", ".join(f"{k} {v}" for k, v in sorted(r.tower_observed.items()))
            state = "drifted" if r.tower_reasons else "at calibration pose"
            lines.append(f"    tower: {seen or 'unreadable'} — {state}")
        lines.append(f"  verdict: {'PASS' if r.ok(max_fail_pct) else 'FAIL'}")
    return "\n".join(lines)


def soak(run_round, rounds: int, interval: float, *,
         sleep=time.sleep, out=print) -> tuple:
    """Repeat `run_round()` -> "ok" | "dropping" | "unavailable".

    This is the periodic form #151 asks for, and the shape that catches an
    INTERMITTENT fault: a gate run once tells you about one moment, and the
    right bus's fault was absent for three days before it mattered.

    Drops and unavailability are counted apart, because only the first is a
    verdict about the hardware. Returns (rounds_run, dropping, unavailable).
    """
    run = dropping = unavailable = 0
    while rounds <= 0 or run < rounds:
        run += 1
        status = run_round()
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        if status == "dropping":
            dropping += 1
            out(f"  [{stamp}] round {run}: DROPPING RESPONSES "
                f"({dropping} of {run})")
        elif status == "unavailable":
            unavailable += 1
            out(f"  [{stamp}] round {run}: bus unavailable — {PORT_BUSY_HINT} "
                f"({unavailable} of {run})")
        if rounds <= 0 or run < rounds:
            sleep(interval)
    return run, dropping, unavailable


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Read-only servo-bus health gate. Never writes, never "
                    "enables torque. Exit 0 = safe to start.")
    ap.add_argument("--bus", choices=["left", "right", "both"], default="both")
    ap.add_argument("--reads", type=int, default=DEFAULT_READS,
                    help=f"reads per servo (default {DEFAULT_READS})")
    ap.add_argument("--max-fail-pct", type=float, default=DEFAULT_MAX_FAIL_PCT,
                    help="tolerated dropped-read percentage per servo "
                         "(default 0.0 — see this file's docstring)")
    ap.add_argument("--tower-calib", metavar="CAMERA_MODEL_JSON",
                    help="also check the pan/tilt tower is still at the pose "
                         "its `tower` block records — the head camera rides it "
                         "and it ships limp, so a knock silently invalidates "
                         "the CameraModel")
    ap.add_argument("--repeat", type=int, default=1, metavar="N",
                    help="run N rounds (0 = forever) — catches an intermittent "
                         "fault a single run would miss")
    ap.add_argument("--interval", type=float, default=30.0, metavar="S",
                    help="seconds between rounds when --repeat (default 30)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    a = ap.parse_args(argv)

    tower_ref = None
    if a.tower_calib:
        try:
            tower_ref = TowerReference.from_calibration(a.tower_calib)
        except Exception as exc:
            print(f"could not read {a.tower_calib}: {type(exc).__name__}: {exc}",
                  file=sys.stderr)
            return 2
        if tower_ref is None:
            print(f"{a.tower_calib} has no `tower` block — the tower pose was "
                  f"never recorded, so it cannot be checked. Re-run "
                  f"camera_calibrate.py to capture it.", file=sys.stderr)
            return 2

    names = ["left", "right"] if a.bus == "both" else [a.bus]
    state = {}

    def run_round() -> bool:
        results = preflight(names, a.reads, tower_ref=tower_ref)
        state["results"] = results
        if a.json:
            print(json.dumps({"ok": all(r.ok(a.max_fail_pct) for r in results),
                              "max_fail_pct": a.max_fail_pct,
                              "buses": [r.as_dict(a.max_fail_pct) for r in results]},
                             indent=2))
        elif a.repeat == 1:
            print(render(results, a.max_fail_pct))
        if any(r.error for r in results):
            return "unavailable"
        return "ok" if all(r.ok(a.max_fail_pct) for r in results) else "dropping"

    if a.repeat != 1:
        forever = "forever" if a.repeat <= 0 else f"{a.repeat} rounds"
        print(f"soaking {', '.join(names)} — {forever}, every {a.interval:g}s, "
              f"{a.reads} reads/servo. Read-only; nothing moves.")
        run, dropping, unavailable = soak(run_round, a.repeat, a.interval)
        print(f"\n{run} rounds: {run - dropping - unavailable} clean, "
              f"{dropping} dropping, {unavailable} unavailable.")
        if dropping:
            print(render(state["results"], a.max_fail_pct))
            print(f"\nREFUSING: the bus dropped responses in {dropping} of "
                  f"{run} rounds — it will also drop commanded positions, "
                  f"silently.", file=sys.stderr)
            return 1
        if unavailable == run:
            print(f"\nINCONCLUSIVE: the bus was never readable — "
                  f"{PORT_BUSY_HINT}.", file=sys.stderr)
            return 2
        if unavailable:
            print(f"note: {unavailable} round(s) could not open the bus. That "
                  f"is not a fault verdict — {PORT_BUSY_HINT}.")
        print("No dropped responses — safe to start.")
        return 0

    status = run_round()
    results = state["results"]
    if status == "unavailable":
        if not a.json:
            print(f"\nINCONCLUSIVE: a bus could not be opened — "
                  f"{PORT_BUSY_HINT}.", file=sys.stderr)
        return 2
    if status == "dropping":
        if not a.json:
            print("\nREFUSING to start — this bus will also drop commanded "
                  "positions, silently:", file=sys.stderr)
            for r in results:
                for reason in r.reasons(a.max_fail_pct):
                    print(f"  {r.name}: {reason}", file=sys.stderr)
        return 1
    if not a.json:
        print("\nAll buses healthy — safe to start.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
