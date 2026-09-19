"""Check the robot BEFORE recording. Cheap now, very expensive later.

Camera consistency is the most fragile part of all this: if the tower's angle
changes between recording and running, what the policy learned to see no longer
matches what it sees, and it does not work. And it gives no warning -- it will
happily record fifty perfect, useless episodes.

So before every session:

  - the tower is at the reference angle (pan 1508 / tilt 3386)
  - the three cameras open, give different images, and show something
  - the arms answer, are calibrated and are not already hot
  - there is room on disk

Usage:  python scripts/preflight.py [--arm left|right]
"""

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "sidecar"))

# Measured and fixed: this is the angle the demonstrations were recorded at.
TOWER_REF = {"pan": 1508, "tilt": 3386}
TOWER_TOLERANCE = 12      # ticks; about one degree
TOWER_BUS = "/dev/cu.usbmodem5B610332201"  # the tower is ids 7 and 8 of this bus
TOWER_IDS = {"pan": 7, "tilt": 8}

# Profile names are CROSSED with respect to the physical side, on purpose:
# `xle_right` is the LEFT arm's profile. The side is identified by each bus's
# auxiliaries: tower (7,8) = left, wheels (9,10) = right.
ARMS = {
    "left": ("/dev/cu.usbmodem5B610332201", "xle_right", 1),
    "right": ("/dev/cu.usbmodem5B3D0437151", "xle_left", 2),
}
CAMERAS = {"head": 0, "left wrist": 1, "right wrist": 2}

MAX_TEMP_C = 42      # above this, starting already means starting in debt
MIN_DISK_GB = 5.0    # ~25 MB per 25 s episode with two cameras


def _bus(port, ids):
    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    m = {n: Motor(i, "sts3215", MotorNormMode.RANGE_M100_100) for n, i in ids.items()}
    b = FeetechMotorsBus(port=port, motors=m)
    b.connect(handshake=False)
    return b


def check_tower() -> bool:
    # Retries: this bus throws SerialException every now and then.
    for attempt in range(3):
        try:
            bus = _bus(TOWER_BUS, TOWER_IDS)
            try:
                read = {n: int(bus.read("Present_Position", n, normalize=False)) for n in TOWER_IDS}
            finally:
                bus.disconnect(disable_torque=False)  # the tower is NEVER released
            offsets = {n: read[n] - TOWER_REF[n] for n in TOWER_REF}
            out = {n: d for n, d in offsets.items() if abs(d) > TOWER_TOLERANCE}
            detail = "  ".join(f"{n}={read[n]} ({offsets[n]:+d})" for n in TOWER_REF)
            if out:
                print(f"  TOWER MOVED: {detail}")
                print(f"    Reference: pan {TOWER_REF['pan']} tilt {TOWER_REF['tilt']}. Put it back")
                print("    before recording, or today's takes will not match the old ones:")
                print(f"      python sidecar/tower.py --port {TOWER_BUS} \\")
                print(f"        --pan {TOWER_REF['pan']} --tilt {TOWER_REF['tilt']}")
                return False
            print(f"  tower in place: {detail}")
            return True
        except Exception as e:
            if attempt == 2:
                print(f"  TOWER: could not read it ({type(e).__name__})")
                return False
    return False


def check_cameras() -> bool:
    import cv2
    import numpy as np

    import vision

    shots, good, silent = {}, True, 0
    for name, index in CAMERAS.items():
        cap = cv2.VideoCapture(index)
        try:
            for _ in range(8):  # warm up: the first frames come out dark
                cap.read()
            ok, f = cap.read()
        finally:
            cap.release()
        if not ok or f is None:
            print(f"  {name} (index {index}): NO IMAGE")
            good = False
            silent += 1
            continue
        brightness, contrast, usable = vision.calidad(f)
        shots[name] = f
        state = "ok" if usable else "TOO DARK OR FLAT"
        print(f"  {name} (index {index}): brightness {brightness:5.1f}  contrast {contrast:5.1f}  {state}")
        good &= usable

    # All three silent at once is almost never hardware: it is the camera
    # permission, which on macOS belongs to the RESPONSIBLE process. Terminal
    # has it granted; Claude's process does not. A bare "no image" would send
    # you looking for a cable that is perfectly fine.
    if silent == len(CAMERAS):
        print("\n  All THREE silent at once: almost certainly the camera permission,")
        print("  not the hardware. Run this from YOUR Terminal, not from Claude.")
        print("  If it fails from Terminal too, check Settings > Privacy > Camera.")
        return False

    # Make sure they are not the same camera twice: a replug can reorder
    # indices, and you would record two identical views believing they are two.
    names = list(shots)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            a, b = shots[names[i]], shots[names[j]]
            if a.shape == b.shape and float(np.abs(a.astype(float) - b.astype(float)).mean()) < 3.0:
                print(f"  {names[i]} and {names[j]} GIVE THE SAME IMAGE: indices reordered")
                good = False
    return good


def check_arm(name: str) -> bool:
    from lerobot.robots.so_follower.config_so_follower import SOFollowerRobotConfig
    from lerobot.robots.utils import make_robot_from_config

    port, profile, camera = ARMS[name]
    robot = make_robot_from_config(
        SOFollowerRobotConfig(port=port, id=profile, disable_torque_on_disconnect=False, cameras={})
    )
    try:
        robot.connect(calibrate=False)
    except Exception as e:
        print(f"  {name} arm: NO ANSWER ({type(e).__name__})")
        return False
    try:
        if not robot.is_calibrated:
            print(f"  {name} arm: NOT CALIBRATED (profile {profile})")
            return False
        temps = []
        for joint in ("shoulder_lift", "elbow_flex"):
            try:
                temps.append(int(robot.bus.read("Present_Temperature", joint, normalize=False)))
            except Exception:
                pass
        t = max(temps) if temps else 0
        if t > MAX_TEMP_C:
            print(f"  {name} arm: ALREADY HOT ({t} C). Let it cool or the session will be short")
            return False
        print(f"  {name} arm: ready (profile {profile}, wrist on camera {camera}, {t} C)")
        return True
    finally:
        try:
            robot.disconnect()
        except Exception:
            pass


def main() -> int:
    arm = "left"
    if "--arm" in sys.argv:
        arm = sys.argv[sys.argv.index("--arm") + 1]
    if arm not in ARMS:
        print(f"Unknown arm: {arm}. Use left or right", file=sys.stderr)
        return 1

    print("Tower:")
    ok = check_tower()
    print("\nCameras:")
    ok &= check_cameras()
    print("\nArm:")
    ok &= check_arm(arm)

    free = shutil.disk_usage(Path.home()).free / 1e9
    print(f"\nDisk: {free:.1f} GB free", end="")
    if free < MIN_DISK_GB:
        print(f"  LESS THAN {MIN_DISK_GB} GB: a session does not fit")
        ok = False
    else:
        print("  (~25 MB per episode)")

    if ok:
        print("\nAll good. Go record.")
        return 0
    print(
        "\nSomething needs fixing before recording. Recording like this produces\n"
        "episodes that look fine and are useless.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
