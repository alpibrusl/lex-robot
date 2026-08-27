#!/usr/bin/env python
"""Re-home an SO101 follower arm, verifying the encoder wrap stays clear.

lerobot-calibrate homes each joint so its *current* pose reads 2048, which puts
the encoder discontinuity exactly half a turn away. That is only safe if the
homing pose sits in the middle of the joint's real travel. On arm 5B61 it did
not: shoulder_lift ended up working ~176 deg from its homing pose, so lifting
the arm a few degrees crossed the wrap and the reported angle jumped 360 deg.
Forward kinematics then returned a plausible-looking, completely wrong pose.

Split into two commands so the tick margins can be checked between them:

    home   hold the arm in the MIDDLE of the motion it will actually perform,
           then run this.  Writes the homing offsets and reports the margin.
    sweep  move every joint through its full travel while this records the
           range.  Refuses to write the calibration if any joint wrapped.
"""

import argparse
import json
import time
from pathlib import Path

from lerobot.motors import Motor, MotorCalibration, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

ARMS = {
    "right": ("usb-1a86_USB_Single_Serial_5B61033220-if00", "xle_right"),
    "left": ("usb-1a86_USB_Single_Serial_5B3D045476-if00", "xle_left"),
}
JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex",
          "wrist_flex", "wrist_roll", "gripper"]
RESOLUTION = 4096
WRAP_JUMP = 1500      # a delta this large between samples can only be a wrap
MIN_MARGIN = 400      # ticks of clearance we insist on at both ends

# Joints that turn further than a full revolution cross the encoder wrap no
# matter where they are homed, so their travel cannot be measured the same way.
# They get a software limit centred on the homing pose instead: that keeps the
# degree zero at the neutral pose we just set, and keeps the wrap out of reach.
CONTINUOUS = {"wrist_roll": 1600}


def calib_path(arm_id):
    return (Path.home() / ".cache/huggingface/lerobot/calibration/robots"
            / "so_follower" / f"{arm_id}.json")


def open_bus(arm):
    port, arm_id = ARMS[arm]
    bus = FeetechMotorsBus(
        port=f"/dev/serial/by-id/{port}",
        motors={j: Motor(i + 1, "sts3215", MotorNormMode.DEGREES)
                for i, j in enumerate(JOINTS)},
    )
    bus.connect(handshake=False)
    return bus, arm_id


def read_ticks(bus):
    return {j: int(bus.read("Present_Position", j, normalize=False)) for j in JOINTS}


def cmd_home(args):
    bus, arm_id = open_bus(args.arm)
    try:
        before = read_ticks(bus)
        for j in JOINTS:
            bus.write("Torque_Enable", j, 0)
        offsets = bus.set_half_turn_homings()
        after = read_ticks(bus)
        print(f"{'articulacion':<15}{'antes':>7}{'ahora':>7}{'homing':>8}")
        bad = []
        for j in JOINTS:
            print(f"{j:<15}{before[j]:7d}{after[j]:7d}{offsets[j]:8d}")
            if abs(after[j] - RESOLUTION // 2) > 4:
                bad.append(j)
        if bad:
            print(f"\nFALLO: no quedaron centrados: {', '.join(bad)}")
            return 1
        print(f"\nCentrados los 6 en {RESOLUTION // 2}. "
              f"El salto del encoder queda a media vuelta (180 deg) de esta postura.")
        print("Ahora: python calibration/rehome.py sweep --arm "
              f"{args.arm} --seconds {args.next_seconds}")
    finally:
        bus.disconnect(disable_torque=False)
    return 0


def cmd_sweep(args):
    if args.continuous is not None:
        globals()["CONTINUOUS"] = {j: 1600 for j in args.continuous}
    bus, arm_id = open_bus(args.arm)
    try:
        prev = read_ticks(bus)
        # Don't start the clock until the arm actually moves: otherwise the
        # window can elapse while the operator is still reading the prompt.
        start = dict(prev)
        print(f"esperando movimiento (hasta {args.wait} s)...", flush=True)
        tw = time.time()
        while time.time() - tw < args.wait:
            prev = read_ticks(bus)
            if any(abs(prev[j] - start[j]) > 30 for j in JOINTS):
                break
            time.sleep(0.05)
        else:
            print("FALLO: no se movio nada, no se escribe la calibracion")
            return 1
        print(f"movimiento detectado, grabando {args.seconds} s", flush=True)

        lo = dict(prev)
        hi = dict(prev)
        wraps = {j: [] for j in JOINTS}
        t0 = time.time()
        while time.time() - t0 < args.seconds:
            cur = read_ticks(bus)
            for j in JOINTS:
                if abs(cur[j] - prev[j]) > WRAP_JUMP:
                    wraps[j].append((time.time() - t0, prev[j], cur[j]))
                lo[j] = min(lo[j], cur[j])
                hi[j] = max(hi[j], cur[j])
            prev = cur
            time.sleep(0.05)

        for j, clamp in CONTINUOUS.items():
            if j in JOINTS:
                lo[j] = RESOLUTION // 2 - clamp
                hi[j] = RESOLUTION // 2 + clamp
                wraps[j] = []

        print(f"{'articulacion':<15}{'rango':>14}{'grados':>9}"
              f"{'margen':>9}   estado")
        problems = []
        for j in JOINTS:
            margin = min(lo[j], RESOLUTION - 1 - hi[j])
            span = (hi[j] - lo[j]) * 360 / (RESOLUTION - 1)
            if j in CONTINUOUS:
                state = "continuo: limite por software"
            elif wraps[j]:
                state = f"*** {len(wraps[j])} SALTOS ***"
                problems.append(j)
            elif margin < MIN_MARGIN:
                state = f"*** margen < {MIN_MARGIN} ***"
                problems.append(j)
            elif hi[j] - lo[j] < 50:
                state = "sin mover"
                problems.append(j)
            else:
                state = "ok"
            print(f"{j:<15}{f'[{lo[j]},{hi[j]}]':>14}{span:9.1f}{margin:9d}   {state}")
            for t, a, b in wraps[j][:3]:
                print(f"      salto en t={t:.1f}s: {a} -> {b}")

        dump = Path("calibration") / f"sweep_{arm_id}.json"
        dump.write_text(json.dumps(
            {j: {"range_min": lo[j], "range_max": hi[j],
                 "wraps": len(wraps[j])} for j in JOINTS}, indent=2))
        print(f"\nbarrido guardado en {dump}")

        if problems:
            print(f"\nNO se escribe la calibracion. Revisar: {', '.join(problems)}")
            print("  'sin mover'  -> esa articulacion no se recorrio, repite el barrido")
            print("  'SALTOS'     -> el homing sigue mal, vuelve a 'home' con otra postura")
            return 1

        path = calib_path(arm_id)
        old = json.loads(path.read_text())
        cal = {j: MotorCalibration(
                    id=old[j]["id"],
                    drive_mode=old[j]["drive_mode"],
                    homing_offset=int(bus.read("Homing_Offset", j, normalize=False)),
                    range_min=lo[j], range_max=hi[j])
               for j in JOINTS}
        bus.write_calibration(cal)
        path.write_text(json.dumps(
            {j: vars(c) for j, c in cal.items()}, indent=2))
        print(f"\nCalibracion escrita en {path}")
        for j in JOINTS:
            print(f"  {j:<15} cero en tick {(lo[j] + hi[j]) / 2:.0f}")
    finally:
        # NOT a bare disconnect(): lerobot's default writes Torque_Enable=0
        # to every motor, which would drop a held arm.
        bus.disconnect(disable_torque=False)
    return 0


def cmd_write(args):
    """Write a calibration from ranges measured across one or more sweeps.

    A sweep only records what the operator actually moved, so a pass that stops
    short of a joint's real stops shifts that joint's zero (the midpoint of the
    recorded range) by however much was left out. Merging the extremes reached
    across several passes is valid as long as no re-homing happened in between,
    because the tick frame is unchanged.
    """
    ranges = json.loads(Path(args.ranges).read_text())
    bus, arm_id = open_bus(args.arm)
    try:
        path = calib_path(arm_id)
        old = json.loads(path.read_text())
        bad = [j for j in JOINTS
               if min(ranges[j]["range_min"],
                      RESOLUTION - 1 - ranges[j]["range_max"]) < MIN_MARGIN]
        if bad:
            print(f"FALLO: margen < {MIN_MARGIN} en {', '.join(bad)}")
            return 1
        cal = {j: MotorCalibration(
                    id=old[j]["id"],
                    drive_mode=old[j]["drive_mode"],
                    homing_offset=int(bus.read("Homing_Offset", j, normalize=False)),
                    range_min=ranges[j]["range_min"],
                    range_max=ranges[j]["range_max"])
               for j in JOINTS}
        bus.write_calibration(cal)
        path.write_text(json.dumps({j: vars(c) for j, c in cal.items()}, indent=2))
        print(f"Calibracion escrita en {path}")
        for j in JOINTS:
            c = cal[j]
            print(f"  {j:<15} [{c.range_min},{c.range_max}]  "
                  f"{(c.range_max - c.range_min) * 360 / (RESOLUTION - 1):6.1f} deg  "
                  f"cero en tick {(c.range_min + c.range_max) / 2:.0f}")
    finally:
        bus.disconnect(disable_torque=False)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("home", help="centre every joint on the current pose")
    h.add_argument("--arm", choices=ARMS, required=True)
    h.add_argument("--next-seconds", type=int, default=90)
    h.set_defaults(fn=cmd_home)
    s = sub.add_parser("sweep", help="record each joint's travel")
    s.add_argument("--arm", choices=ARMS, required=True)
    s.add_argument("--seconds", type=int, default=90)
    s.add_argument("--wait", type=int, default=300,
                   help="seconds to idle before the first movement")
    s.add_argument("--continuous", nargs="*", default=None,
                   help="joints to clamp instead of measure (default: wrist_roll)")
    s.set_defaults(fn=cmd_sweep)
    w = sub.add_parser("write", help="write a calibration from merged sweep ranges")
    w.add_argument("--arm", choices=ARMS, required=True)
    w.add_argument("--ranges", required=True)
    w.set_defaults(fn=cmd_write)
    args = p.parse_args()
    raise SystemExit(args.fn(args))


if __name__ == "__main__":
    main()
