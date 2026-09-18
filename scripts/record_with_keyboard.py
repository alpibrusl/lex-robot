"""Record demonstrations with the joint keyboard.

A dedicated launcher is needed for two reasons:

1. lerobot resolves `--teleop.type=` against a registry that is filled at
   import time. Our teleoperator lives outside the package, so somebody has to
   import it before the parser reads the arguments.

2. `lerobot-record` builds IDENTITY pipelines by default. Our keyboard emits
   deltas, not positions, and DeltaToPosition is what converts them. That step
   can only be injected from code, by passing it to record().

Takes the same flags as `lerobot-record`; they are passed straight through.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from lerobot.processor import (  # noqa: E402
    RobotProcessorPipeline,
    robot_action_observation_to_transition,
    transition_to_robot_action,
)
from lerobot.scripts.lerobot_record import record  # noqa: E402

from joint_keyboard_teleop import KEYS, DeltaToPosition, JointKeyboardTeleop  # noqa: E402,F401

KEY_TEST_SECONDS = 20


def keyboard_responds(seconds: int = KEY_TEST_SECONDS) -> bool:
    """Check macOS lets us read the keyboard BEFORE recording anything.

    Not paranoia: without the Accessibility permission lerobot logs a warning
    and carries on producing zero actions. You would record whole episodes with
    the arm standing still and only find out at training time. And on macOS
    there is no other way to know: the permission is only confirmed when a real
    listener receives a key.
    """
    try:
        from pynput import keyboard
    except ImportError:
        print("pynput is missing:  pip install pynput", file=sys.stderr)
        return False

    received = []
    with keyboard.Listener(on_press=lambda k: (received.append(k), False)[1]) as listener:
        print(f"\nPress any key to check the permission ({seconds} s)...", flush=True)
        listener.join(timeout=seconds)

    if received:
        print("Keyboard OK.\n", flush=True)
        return True

    print(
        "\nNo key came through. The Accessibility permission is missing.\n"
        "  Settings > Privacy & Security > Accessibility\n"
        "  Add Terminal (Applications/Utilities) with +, enable it,\n"
        "  and QUIT AND REOPEN Terminal so it picks the grant up.\n"
        "\nWithout this lerobot does not complain: it would record empty episodes.\n"
        "And there is no shortcut. A listener that needs no permission does exist\n"
        "(it reads the terminal itself), but lerobot-record already uses it to move\n"
        "between episodes and owns stdin: the same terminal cannot be read twice.",
        file=sys.stderr,
    )
    return False


def key_help() -> None:
    print("  Top row ADDS, home row SUBTRACTS, from the base to the gripper:")
    for up, down in (("w", "s"), ("e", "d"), ("t", "g"), ("y", "h"), ("u", "j"), ("i", "k")):
        print(f"    {up} / {down}   {KEYS[up][0]}")
    print("  They combine when pressed together.  Shift = quarter speed (fine grasping).")
    print("  Reserved by lerobot-record, these do not move the arm:")
    print("    n / right arrow = episode accepted, next one")
    print("    r / left arrow  = re-record the episode")
    print("    q / esc         = quit\n")


def main() -> int:
    if "--skip-key-test" in sys.argv:
        sys.argv.remove("--skip-key-test")
    elif not keyboard_responds():
        return 1

    key_help()

    pipeline = RobotProcessorPipeline[tuple[dict, dict], dict](
        steps=[DeltaToPosition()],
        to_transition=robot_action_observation_to_transition,
        to_output=transition_to_robot_action,
    )
    record(teleop_action_processor=pipeline)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
