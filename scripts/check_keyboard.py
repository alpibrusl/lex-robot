"""Diagnostic: see what the keyboard produces, without touching the robot.

Splits the chain in two. If the keys show up here, the problem is in the arm
(torque, limits, port). If they do not, it is in the keyboard, and there is no
point looking at the robot.

Run it FROM YOUR TERMINAL, not through Claude: the Accessibility permission
belongs to Terminal, not to Claude's process.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from lerobot.processor import (  # noqa: E402
    RobotProcessorPipeline,
    robot_action_observation_to_transition,
    transition_to_robot_action,
)
from lerobot.teleoperators.utils import make_teleoperator_from_config  # noqa: E402

from joint_keyboard_teleop import DeltaToPosition, JointKeyboardTeleopConfig  # noqa: E402

SECONDS = 20
# Fake position, only to see what comes out the other end of the pipeline.
FAKE = {
    "shoulder_pan.pos": 0.0, "shoulder_lift.pos": 0.0, "elbow_flex.pos": 0.0,
    "wrist_flex.pos": 0.0, "wrist_roll.pos": 0.0, "gripper.pos": 50.0,
}


def main() -> int:
    import HIServices

    trusted = bool(HIServices.AXIsProcessTrusted())
    print(f"Accessibility permission in THIS process: {trusted}")
    if not trusted:
        print(
            "\nThis process does not have the permission. If you launched it from\n"
            "Claude, launch it from Terminal instead: the grant belongs to Terminal.",
            file=sys.stderr,
        )
        return 1

    teleop = make_teleoperator_from_config(JointKeyboardTeleopConfig())
    print(f"teleoperator: {type(teleop).__name__}")
    teleop.connect()
    print(f"listener alive: {teleop.is_connected}")

    pipeline = RobotProcessorPipeline[tuple[dict, dict], dict](
        steps=[DeltaToPosition()],
        to_transition=robot_action_observation_to_transition,
        to_output=transition_to_robot_action,
    )

    print(f"\nPress keys for {SECONDS} s (w/s e/d t/g y/h u/j i/k).")
    print("It only prints when something moves.\n")

    end = time.perf_counter() + SECONDS
    seen, frames = set(), 0
    while time.perf_counter() < end:
        action = teleop.get_action()
        out = pipeline((action, FAKE))
        frames += 1
        active = {k.removesuffix(".delta"): v for k, v in action.items() if abs(v) > 1e-9}
        if active:
            seen.update(active)
            detail = "  ".join(f"{m}{v:+.2f}" for m, v in sorted(active.items()))
            target = "  ".join(
                f"{m.removesuffix('.pos')}={v:.2f}"
                for m, v in sorted(out.items())
                if abs(v - FAKE[m]) > 1e-9
            )
            print(f"  keyboard: {detail}   ->   arm: {target or '(no change)'}")
        time.sleep(1 / 30)

    teleop.disconnect()
    print(f"\n{frames} frames read.")
    if seen:
        print(f"IT WORKS. Joints that responded: {', '.join(sorted(seen))}")
        print("If the robot was not moving, the fault is in the arm, not the keyboard.")
        return 0
    print(
        "NO KEY ARRIVED.\n"
        "  - Launched from Terminal, not from Claude?\n"
        "  - Were you pressing w/s/e/d/t/g/y/h/u/j/i/k (not the arrows)?\n"
        "  - Did some odd window have focus (screen capture, VNC)?",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
