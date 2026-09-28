"""Release the arms' torque, leaving the robot at rest.

It deliberately does NOT touch the tower: the tower holds the camera at the
angle the demonstrations were recorded at (pan 1508 / tilt 3386). If it is
released and drops, that angle is lost and the demonstrations stop being
usable. The tower is ids 7 and 8 on the LEFT arm's bus; only ids 1-6 are
declared here, which is why it is left alone.

Before releasing it reports pose and temperature, because releasing a raised
arm means dropping it.
"""

import sys
import time

from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

# The side is identified by each bus's auxiliaries, not by the label:
# tower (ids 7,8) = left, wheels (ids 9,10) = right.
ARMS = {
    "left": "/dev/cu.usbmodem5B610332201",
    "right": "/dev/cu.usbmodem5B3D0437151",
}
JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
ATTEMPTS = 3


def release(name: str, port: str) -> bool:
    """Retries: this bus throws SerialException every now and then.

    Seen three times in one session on the left arm's port, the one sharing a
    line with the tower: "device reports readiness to read but returned no
    data". Retrying works. Leaving an arm powered because of a transient read
    failure is not acceptable in the very script meant to make it safe.
    """
    for attempt in range(1, ATTEMPTS + 1):
        if _release_once(name, port, attempt):
            return True
        if attempt < ATTEMPTS:
            time.sleep(1.0)
    print(f"  {name}: COULD NOT RELEASE in {ATTEMPTS} attempts -- check it by hand")
    return False


def _release_once(name: str, port: str, attempt: int) -> bool:
    motors = {n: Motor(i + 1, "sts3215", MotorNormMode.RANGE_M100_100) for i, n in enumerate(JOINTS)}
    bus = FeetechMotorsBus(port=port, motors=motors)
    try:
        bus.connect()
    except Exception as e:
        print(f"  {name}: no answer ({type(e).__name__}), attempt {attempt}")
        return False

    try:
        for joint in JOINTS:
            try:
                pos = int(bus.read("Present_Position", joint, normalize=False))
                temp = int(bus.read("Present_Temperature", joint, normalize=False))
                print(f"    {joint:14s} pos={pos:5d}  {temp:2d} C")
            except Exception:
                print(f"    {joint:14s} (no read)")
        # Release explicitly and READ BACK. Trusting disconnect's flag is not
        # enough: in one test it said "released" and all six joints were still
        # powered. A script whose only job is to release cannot declare victory
        # without looking.
        bus.disable_torque()
        left = [j for j in JOINTS if int(bus.read("Torque_Enable", j, normalize=False))]
        bus.disconnect(disable_torque=True)
        if left:
            print(f"  {name}: STILL POWERED: {', '.join(left)} -- do not trust it, check")
            return False
        print(f"  {name}: torque released and VERIFIED (0 of {len(JOINTS)} joints powered)")
        return True
    except Exception as e:
        print(f"  {name}: failed to release on attempt {attempt} ({type(e).__name__})")
        try:
            bus.disconnect(disable_torque=True)
        except Exception:
            pass
        return False


def main() -> int:
    released = 0
    for name, port in ARMS.items():
        print(f"\n{name.capitalize()} arm ({port}):")
        released += release(name, port)
    print(f"\n{released} of {len(ARMS)} arms released. The TOWER was not touched:")
    print("it holds the camera at the angle you recorded with.")
    return 0 if released else 1


if __name__ == "__main__":
    raise SystemExit(main())
