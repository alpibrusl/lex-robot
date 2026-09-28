"""Keyboard teleoperation in JOINT space: one key pair per servo.

Why not lerobot's Cartesian keyboard: `keyboard_ee` emits
delta_x/delta_y/delta_z/gripper, but `so101_follower` only accepts
`<motor>.pos` keys (it filters on `.endswith(".pos")`). With nobody
translating, the dict reaches the bus EMPTY and `sync_write` dies with
StopIteration. The translator exists (InverseKinematicsEEToJoints) but needs a
URDF that is not shipped with the package, and it gives 4 controls for 5
joints: the wrist is chosen by inverse kinematics, not by you.

Here every servo is yours. Systematic layout: top row adds, home row
subtracts, left to right goes from the base to the gripper.

    w/s  shoulder_pan     rotate the base
    e/d  shoulder_lift    raise/lower the shoulder
    t/g  elbow_flex       elbow
    y/h  wrist_flex       wrist up/down
    u/j  wrist_roll       rotate the wrist
    i/k  gripper          open/close

They combine when pressed together: e+t raises shoulder and elbow in the same
frame. Holding shift moves at a quarter speed, for fine grasping.

MIND THE FREE KEYS: lerobot-record starts ITS OWN keyboard listener to move
between episodes, and with pynput both listeners receive every keystroke.
These are taken and cannot be used to drive the arm:

    n / right arrow   accept the episode and move to the next one
    r / left arrow    re-record the episode
    q / esc           quit

That is why the map skips the r/f column and does not start at q: rotating the
base would have quit the program.
"""

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from lerobot.configs.types import FeatureType, PipelineFeatureType, PolicyFeature
from lerobot.processor import ProcessorStepRegistry, RobotActionProcessorStep, TransitionKey
from lerobot.teleoperators.config import TeleoperatorConfig
from lerobot.teleoperators.keyboard.configuration_keyboard import KeyboardTeleopConfig
from lerobot.teleoperators.keyboard.teleop_keyboard import KeyboardTeleop

# Normalized units per frame. At 30 fps, 0.7 is 21 units/second over a 200-unit
# range: a full sweep in ~9 s. The wrist runs looser because it moves little
# mass; the shoulder slower because it carries the whole arm.
STEPS = {
    "shoulder_pan": 0.7,
    "shoulder_lift": 0.6,
    "elbow_flex": 0.7,
    "wrist_flex": 0.9,
    "wrist_roll": 1.2,
    "gripper": 1.5,
}

# Reserved by lerobot-record: n, r, q, esc and the arrows. See the docstring.
RESERVED = frozenset({"n", "r", "q"})

KEYS = {
    "w": ("shoulder_pan", +1), "s": ("shoulder_pan", -1),
    "e": ("shoulder_lift", +1), "d": ("shoulder_lift", -1),
    "t": ("elbow_flex", +1), "g": ("elbow_flex", -1),
    "y": ("wrist_flex", +1), "h": ("wrist_flex", -1),
    "u": ("wrist_roll", +1), "j": ("wrist_roll", -1),
    "i": ("gripper", +1), "k": ("gripper", -1),
}

assert not (RESERVED & KEYS.keys()), "a movement key would collide with lerobot-record"

# Second layout, for driving both arms at once: left hand drives the left arm,
# right hand the right one, which is the mapping your hands already expect.
# Twelve keys per arm is a lot to play; if it does not suit you, change it --
# see load_keymap below, no code editing needed.
DUAL_KEYS = {
    "left": {
        "w": ("shoulder_pan", +1), "s": ("shoulder_pan", -1),
        "e": ("shoulder_lift", +1), "d": ("shoulder_lift", -1),
        "t": ("elbow_flex", +1), "g": ("elbow_flex", -1),
        "a": ("wrist_flex", +1), "z": ("wrist_flex", -1),
        "f": ("wrist_roll", +1), "v": ("wrist_roll", -1),
        "c": ("gripper", +1), "x": ("gripper", -1),
    },
    "right": {
        "y": ("shoulder_pan", +1), "h": ("shoulder_pan", -1),
        "u": ("shoulder_lift", +1), "j": ("shoulder_lift", -1),
        "i": ("elbow_flex", +1), "k": ("elbow_flex", -1),
        "o": ("wrist_flex", +1), "l": ("wrist_flex", -1),
        "p": ("wrist_roll", +1), "ñ": ("wrist_roll", -1),
        ".": ("gripper", +1), ",": ("gripper", -1),
    },
}

for _side, _map in DUAL_KEYS.items():
    assert not (RESERVED & _map.keys()), f"a {_side} key would collide with lerobot-record"
assert not (DUAL_KEYS["left"].keys() & DUAL_KEYS["right"].keys()), "both hands share a key"


def load_keymap(default: dict, name: str = "LEX_KEYMAP") -> dict:
    """Let the key layout be changed without editing code.

    Point $LEX_KEYMAP at a JSON file of {"key": ["motor", +1 or -1]} (or, for
    the two-arm layout, {"left": {...}, "right": {...}}). It is MERGED over the
    default, so the file only has to list what you want to change; redefining
    one key does not cost you the other eleven.

    Note it merges by KEY, not by joint: mapping a joint to a new key leaves
    the old key working too, unless you also point that old key somewhere else.
    """
    path = os.environ.get(name)
    if not path:
        return default
    try:
        raw = json.loads(Path(path).read_text())
    except Exception as e:
        print(f"Could not read the key map at {path} ({type(e).__name__}); using the default")
        return default

    def convert(d):
        return {k: (v[0], int(v[1])) for k, v in d.items()}

    try:
        if all(isinstance(v, dict) for v in raw.values()):
            # Merge per side, so a file can redefine one arm and leave the
            # other alone.
            merged = {side: dict(m) for side, m in default.items()}
            for side, m in raw.items():
                merged.setdefault(side, {}).update(convert(m))
            return merged
        return {**default, **convert(raw)}
    except Exception as e:
        print(f"The key map at {path} has the wrong shape ({type(e).__name__}); using the default")
        return default


def deltas_from_keys(pressed: set, keymap: dict, scale: float) -> dict[str, float]:
    """How far each joint wants to move, given the keys held down right now.

    Split out of the teleoperator so the same rule can drive two arms from one
    keyboard: the caller runs it once per arm with that arm's own key map,
    against the same set of pressed keys.
    """
    deltas = {m: 0.0 for m in STEPS}
    for key in pressed:
        if not isinstance(key, str):
            continue
        target = keymap.get(key.lower())
        if target is None:
            continue
        motor, sign = target
        # Add, do not assign: opposite keys pressed together cancel out, which
        # is what anyone would expect.
        deltas[motor] += sign * STEPS[motor] * scale
    return deltas


def is_fine(pressed: set) -> bool:
    """Shift held: quarter speed, for fine grasping."""
    return any(getattr(k, "name", "") in ("shift", "shift_r") for k in pressed)

# The follower normalizes everything to -100..100 except the gripper, 0..100.
LIMITS = {"gripper": (0.0, 100.0)}
DEFAULT_LIMIT = (-100.0, 100.0)

FINE = 0.25  # multiplier while shift is held


# The config class name MUST be the teleoperator class name plus "Config":
# lerobot's generic factory strips the suffix and imports what is left. Name
# them out of step and `--teleop.type=` fails at launch with "could not locate
# device class", after everything has already been set up.
@TeleoperatorConfig.register_subclass("joint_keyboard")
@dataclass
class JointKeyboardTeleopConfig(KeyboardTeleopConfig):
    scale: float = 1.0  # raise or lower the speed of every joint at once


class JointKeyboardTeleop(KeyboardTeleop):
    """Emits `<motor>.delta`: how far each joint wants to move this frame.

    Deliberately does NOT emit `.pos`: a keyboard has no idea where the arm is.
    Turning that intent into an absolute position is DeltaToPosition's job,
    since that step does see the real observation.
    """

    config_class = JointKeyboardTeleopConfig
    name = "joint_keyboard"

    def __init__(self, config: JointKeyboardTeleopConfig):
        super().__init__(config)
        self.config = config

    @property
    def action_features(self) -> dict[str, type]:
        return {f"{m}.delta": float for m in STEPS}

    @property
    def feedback_features(self) -> dict[str, type]:
        return {}

    def get_action(self) -> dict[str, float]:
        self._drain_pressed_keys()
        pressed = {k for k, v in self.current_pressed.items() if v}
        scale = self.config.scale * (FINE if is_fine(pressed) else 1.0)
        deltas = deltas_from_keys(pressed, load_keymap(KEYS), scale)
        return {f"{m}.delta": v for m, v in deltas.items()}

    def send_feedback(self, feedback: dict[str, float]) -> None:
        pass


@ProcessorStepRegistry.register("delta_to_position")
@dataclass
class DeltaToPosition(RobotActionProcessorStep):
    """Integrates the keyboard deltas onto the arm's real position.

    Two decisions that matter:

    1. It keeps a target of its own instead of sending `current + delta`. With
       that, releasing the keys would make delta 0 and the target would be the
       current position: gravity sinks the shoulder a little, the target
       follows it down, and the arm walks itself to the table step by step.

    2. That target may never drift further than `margin` from where the arm
       actually is. If the gripper hits the table and you keep pressing,
       without this cap the target runs away, the error grows and the servo
       goes into overload. With the cap, bottoming out is harmless: it pushes
       gently and stays there.
    """

    margin: float = 8.0
    target: dict[str, float] | None = field(default=None, init=False, repr=False)

    def action(self, action):
        obs = self.transition.get(TransitionKey.OBSERVATION) or {}
        current = {k.removesuffix(".pos"): float(v) for k, v in obs.items() if k.endswith(".pos")}

        if not current:
            if self.target:
                return {f"{m}.pos": p for m, p in self.target.items()}
            raise RuntimeError(
                "No arm position in the observation; without it the keyboard "
                "cannot be turned into commands. Check the robot is connected "
                "before recording."
            )

        if self.target is None:
            self.target = dict(current)  # start wherever it is, no jump

        out = {}
        for motor, position in current.items():
            target = self.target.get(motor, position) + float(action.get(f"{motor}.delta", 0.0))
            low, high = LIMITS.get(motor, DEFAULT_LIMIT)
            target = min(max(target, low), high)
            target = min(max(target, position - self.margin), position + self.margin)
            self.target[motor] = target
            out[f"{motor}.pos"] = target
        return out

    def transform_features(self, features):
        # The keyboard contributes intent (.delta); what ends up in the dataset
        # are positions (.pos), which is what the policy will have to predict.
        for motor in STEPS:
            features[PipelineFeatureType.ACTION].pop(f"{motor}.delta", None)
            features[PipelineFeatureType.ACTION][f"{motor}.pos"] = PolicyFeature(
                type=FeatureType.ACTION, shape=(1,)
            )
        return features

    def reset(self):
        # Between episodes you reposition the arm by hand. If the target stayed
        # latched from the previous episode, the first frame of the next one
        # would drag it back toward the old pose.
        self.target = None
