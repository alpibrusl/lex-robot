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
import lerobot.scripts.lerobot_record as _lerobot_record  # noqa: E402
from lerobot.scripts.lerobot_record import record  # noqa: E402
from lerobot.utils.keyboard_input import (  # noqa: E402
    apply_recording_control,
    create_key_listener,
)

from joint_keyboard_teleop import (  # noqa: E402,F401
    DeltaToPosition, JointKeyboardTeleop, base_keymap, describe_keymap, load_keymap,
)

KEY_TEST_SECONDS = 20


def arrows_only_listener():
    """lerobot-record's episode controls, WITHOUT its letter shortcuts.

    lerobot binds n/r/q as well as the arrows and Esc, and with pynput both
    its listener and ours receive every key -- so q, which drives the
    shoulder, would also quit the recording. Same events dict and same
    backend selection as lerobot's own init_keyboard_listener; only the
    letters are dropped.
    """
    events = {"exit_early": False, "rerecord_episode": False, "stop_recording": False}

    def on_key(name: str) -> None:
        key = name.lower()
        if key in ("right", "left", "esc"):
            apply_recording_control(key, events)

    listener = create_key_listener(
        on_key, controls_help="Right = next episode, Left = re-record, Esc = stop")
    return listener, events


# record() looks this name up in its own module at call time.
_lerobot_record.init_keyboard_listener = arrows_only_listener


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
    print("  Keys in use (+ / -), from the base to the gripper:")
    for line in describe_keymap(load_keymap(base_keymap())):
        print(f"    {line}")
    print("  They combine when pressed together.  Shift = quarter speed (fine grasping).")
    print("  Episode controls (letters are free for the arm):")
    print("    right arrow = episode accepted, next one")
    print("    left arrow  = re-record the episode")
    print("    esc         = stop recording\n")


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
