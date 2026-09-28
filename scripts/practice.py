"""Practice with the keyboard without recording anything. Leave it running.

Two ways of driving two arms:

  ./practice.sh           one at a time, switching with 1 and 2. The inactive
                          arm keeps its torque, so it stays where you left it,
                          and coming back to it picks up from wherever it
                          really is (DeltaToPosition's 8-unit cap re-anchors on
                          its own).

  ./practice.sh --both    both at once, left hand on the left arm and right
                          hand on the right one. Twelve keys per arm is a lot
                          to play; if the layout does not suit you, point
                          $LEX_KEYMAP at a JSON file instead of editing code.

Deliberate differences from record_demos.sh:

- No cameras. They add nothing to practice and the loop runs looser.
- Torque is NOT released on exit (disable_torque_on_disconnect=False). The
  default is to release it, and then the arm collapses onto the table the
  moment you press Ctrl-C. That has bitten us several times in this project.
- It watches the shoulder temperature. Left powered with the arm raised, the
  servo carrying all the weight heats up even if you never move it.

MIND THE LEFT ARM'S BUS: it also carries the TOWER on ids 7 and 8 (measured:
pan 1508 / tilt 3386, the angle the demonstrations were recorded at). Only ids
1-6 are declared here, so the tower is never touched; do not add ids casually.

Run it FROM YOUR TERMINAL: the Accessibility permission belongs to Terminal.
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
from lerobot.robots.so_follower.config_so_follower import SOFollowerRobotConfig  # noqa: E402
from lerobot.robots.utils import make_robot_from_config  # noqa: E402
from lerobot.teleoperators.utils import make_teleoperator_from_config  # noqa: E402

from joint_keyboard_teleop import (  # noqa: E402
    DUAL_KEYS,
    FINE,
    KEYS,
    DeltaToPosition,
    JointKeyboardTeleopConfig,
    deltas_from_keys,
    is_fine,
    load_keymap,
)

# MIND THE PROFILE NAMES: they are CROSSED with respect to the physical side,
# on purpose. `xle_right` is the LEFT arm's profile. They are just lookup keys;
# what matters is each port getting the profile matching its own servos'
# EEPROM, verified 6/6 on both sides. Do not "fix" it: it would diverge from
# the calibration/ copies on the pi-env-camera-map branch.
#
# The side is identified by each bus's auxiliary servos, never by the label:
# tower (ids 7,8) = left, wheels (ids 9,10) = right.
ARMS = [
    ("left", "/dev/cu.usbmodem5B610332201", "xle_right"),
    ("right", "/dev/cu.usbmodem5B3D0437151", "xle_left"),
]
ARM_KEYS = {"1": 0, "2": 1}  # these do not collide with the movement keys

FPS = 30
WATCHED = "shoulder_lift"  # the one carrying all the weight
WARN_C = 45
STOP_C = 50
EVERY_S = 2.0  # do not flood the bus with temperature reads


class Arm:
    """A connected arm, with its own pipeline and thermometer."""

    def __init__(self, name: str, robot):
        self.name = name
        self.robot = robot
        self.pipeline = RobotProcessorPipeline[tuple[dict, dict], dict](
            steps=[DeltaToPosition()],
            to_transition=robot_action_observation_to_transition,
            to_output=transition_to_robot_action,
        )
        self.temperature = 0
        self.peak = 0
        self._last = 0.0

    def move(self, action: dict) -> dict:
        obs = self.robot.get_observation()
        self.robot.send_action(self.pipeline((action, obs)))
        return obs

    def measure(self, now: float) -> None:
        if now - self._last <= EVERY_S:
            return
        self._last = now
        # Median of three: a single bus read can come back corrupted, and
        # stopping or carrying on depends on this number.
        reads = []
        for _ in range(3):
            try:
                reads.append(
                    int(self.robot.bus.read("Present_Temperature", WATCHED, normalize=False))
                )
            except Exception:
                pass
        if reads:
            self.temperature = sorted(reads)[len(reads) // 2]
            self.peak = max(self.peak, self.temperature)


def connect(requested: list[str]) -> list[Arm]:
    arms = []
    for name, port, profile in ARMS:
        if requested and name not in requested:
            continue
        robot = make_robot_from_config(
            SOFollowerRobotConfig(
                port=port,
                id=profile,
                max_relative_target=12.0,
                disable_torque_on_disconnect=False,  # so it does not collapse on exit
                cameras={},
            )
        )
        try:
            # calibrate=False: without it, an uncalibrated arm silently starts
            # interactive calibration and asks you to sweep the whole range
            # when all you wanted was to practice.
            robot.connect(calibrate=False)
        except Exception as e:
            print(f"  {name}: could not connect ({type(e).__name__}: {str(e)[:60]})")
            continue
        if not robot.is_calibrated:
            print(
                f"  {name}: NOT CALIBRATED. The servos do not hold their range, so\n"
                f"        positions mean nothing yet. Calibrate it once:\n"
                f"          lerobot-calibrate --robot.type=so101_follower \\\n"
                f"            --robot.port={port} --robot.id={profile}"
            )
            try:
                robot.disconnect()
            except Exception:
                pass
            continue
        print(f"  {name}: ready")
        arms.append(Arm(name, robot))
    return arms


def key_help(arms: list[Arm], both: bool = False, dual_map: dict | None = None) -> None:
    if both:
        names = {"shoulder_pan": "base", "shoulder_lift": "shoulder", "elbow_flex": "elbow",
                 "wrist_flex": "wrist", "wrist_roll": "roll", "gripper": "gripper"}
        print()
        for a in arms:
            layout = (dual_map or DUAL_KEYS).get(a.name, {})
            pairs = {}
            for key, (motor, sign) in layout.items():
                pairs.setdefault(motor, {})[sign] = key
            shown = "   ".join(
                f"{pairs[m].get(1,'?')}/{pairs[m].get(-1,'?')} {names.get(m, m)}"
                for m in names if m in pairs
            )
            print(f"  {a.name:5s} arm:  {shown}")
        print("\n  Both arms move at once. Shift = quarter speed.")
        print("  Esc or Ctrl-C to quit; the arms stay HELD, they do not fall.\n")
        return

    print("\n  w/s  rotate the base     y/h  wrist up/down")
    print("  e/d  shoulder            u/j  rotate the wrist")
    print("  t/g  elbow               i/k  open/close the gripper")
    if len(arms) > 1:
        switch = "   ".join(f"{k} = {arms[i].name}" for k, i in ARM_KEYS.items() if i < len(arms))
        print(f"\n  Switch arm:  {switch}")
        print("  The inactive arm keeps its torque: it stays where you left it.")
    print("\n  They combine when pressed together. Shift = quarter speed.")
    print("  Esc or Ctrl-C to quit; the arms stay HELD, they do not fall.\n")


def main() -> int:
    import HIServices

    if not bool(HIServices.AXIsProcessTrusted()):
        print(
            "This process does not have the Accessibility permission.\n"
            "Launch it from Terminal: the grant belongs to Terminal, not to Claude.",
            file=sys.stderr,
        )
        return 1

    both = "--both" in sys.argv
    requested = [a.lower() for a in sys.argv[1:] if not a.startswith("-")]
    unknown = [r for r in requested if r not in {n for n, _, _ in ARMS}]
    if unknown:
        print(f"Unknown arm: {', '.join(unknown)}. Use: left, right", file=sys.stderr)
        return 1

    print("Connecting:")
    arms = connect(requested)
    if not arms:
        print("\nNo usable arm.", file=sys.stderr)
        return 1

    dual_map = load_keymap(DUAL_KEYS) if both else {}
    if both and len(arms) < 2:
        print("\n--both needs two arms and only one connected; driving that one.", file=sys.stderr)
        both = False

    teleop = make_teleoperator_from_config(JointKeyboardTeleopConfig())
    teleop.connect()
    key_help(arms, both, dual_map)

    active, reason = 0, "Esc"
    period = 1.0 / FPS
    try:
        while teleop.is_connected:
            cycle = time.perf_counter()

            # Read the arm switch before moving, so the key is not lost in the
            # same frame it was pressed.
            for key, index in ARM_KEYS.items():
                if teleop.current_pressed.get(key) and index < len(arms):
                    active = index

            if both:
                # One keyboard, two arms: the same pressed keys are run through
                # each arm's own map, so the hands do not interfere.
                teleop._drain_pressed_keys()
                pressed = {k for k, v in teleop.current_pressed.items() if v}
                scale = FINE if is_fine(pressed) else 1.0
                obs = None
                for a in arms:
                    deltas = deltas_from_keys(pressed, dual_map.get(a.name, {}), scale)
                    moved = a.move({f"{m}.delta": v for m, v in deltas.items()})
                    if obs is None:
                        obs = moved
                arm = arms[0]
            else:
                arm = arms[active]
                obs = arm.move(teleop.get_action())
            for a in arms:
                a.measure(cycle)

            hot = [a for a in arms if a.temperature >= STOP_C]
            if hot:
                reason = f"{hot[0].name} {WATCHED} at {hot[0].temperature} C"
                break

            mark = "  HOT" if arm.temperature >= WARN_C else ""
            poses = "  ".join(
                f"{k.removesuffix('.pos')[:5]}:{v:6.1f}" for k, v in sorted(obs.items())
            )
            label = arm.name[:5] if len(arms) > 1 else ""
            print(f"\r  {label:5s} {arm.temperature:2d}C{mark}  {poses}   ", end="", flush=True)

            wait = period - (time.perf_counter() - cycle)
            if wait > 0:
                time.sleep(wait)
    except KeyboardInterrupt:
        reason = "Ctrl-C"
    finally:
        print()
        teleop.disconnect()
        for a in arms:
            try:
                a.robot.disconnect()  # WITH torque on, per the config above
            except Exception:
                pass

    peaks = "  ".join(f"{a.name} {a.peak} C" for a in arms)
    print(f"\nDone ({reason}). Peak temperature: {peaks}.")
    print("The arms are still HELD by the servos: they do not fall on exit.")
    print("To leave them loose when you finish:")
    print("    python scripts/release_arms.py")
    if any(a.temperature >= STOP_C for a in arms):
        print(
            f"\nStopped on heat. Let it cool below {WARN_C} C before carrying on.\n"
            "If you are going to leave it powered for a while, lower it onto the\n"
            "table: what heats up is the shoulder holding the arm in the air."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
