"""A scripted `Teleoperator` — demonstration data with nobody at the keyboard.

`lerobot-record` needs *an action source*, not necessarily a human one. The
`Teleoperator` ABC's only per-step method is `get_action()`, so a scripted
expert plugs into the official recorder and the dataset lands in exactly the
schema `lerobot-train` expects — no hand-rolled `LeRobotDataset`, which is
the risk lex-robot#146 called out.

Actions are joint-space, keyed `<joint>.pos`, matching
`SO101Follower.action_features`. The BODY joints' unit depends on the robot's
`use_degrees` config, which lerobot defaults to **True**: degrees by default,
RANGE_M100_100 (-100..100) only if you pass `--robot.use_degrees=false`. Set
`use_degrees` on this teleop to match, so the safety clamp bounds the right
scale. `gripper` is always RANGE_0_100 (0..100).

One trajectory cycle == one episode. `connect()` prints the cycle duration;
pass it to `lerobot-record` as `--dataset.episode_time_s`.

Safety: every emitted action is clamped to a per-joint envelope from the
config (`joint_limits`). That is this file's analogue of the sidecar's
workspace box — SIDECAR.md's grant is NOT enforced on the lerobot-record
path (#146), so the clamp has to live here, in the action source itself.
It is a logical bound, not a physical one: keep the e-stop in reach.
"""

from __future__ import annotations

import json
import logging
import math
import random
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from lerobot.teleoperators.config import TeleoperatorConfig
from lerobot.teleoperators.teleoperator import Teleoperator

logger = logging.getLogger(__name__)

JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
BODY = JOINTS[:-1]


@TeleoperatorConfig.register_subclass("scripted_arm")
@dataclass
class ScriptedArmTeleopConfig(TeleoperatorConfig):
    """Config for the scripted pick-and-place expert.

    Attributes:
        waypoints_path: JSON trajectory (see sidecar/waypoints_pick_place.json).
        jitter: per-cycle uniform jitter, in normalized units, applied to
            waypoints flagged "jitter": true. This is what buys dataset
            variety without a human moving the object between takes.
        seed: RNG seed, so a recording run is reproducible.
        joint_limits: hard per-joint clamp {joint: [min, max]}. Applied last,
            after interpolation and jitter.
        use_degrees: must match the robot's own `use_degrees` (lerobot
            defaults it to True). Only sets the outermost body-joint bound —
            +/-180 for degrees, +/-100 for RANGE_M100_100 — so a units
            mismatch cannot silently widen the envelope.
    """

    waypoints_path: str = "sidecar/waypoints_pick_place.json"
    jitter: float = 0.0
    seed: int = 0
    joint_limits: dict[str, list[float]] = field(default_factory=dict)
    use_degrees: bool = True


class ScriptedArmTeleop(Teleoperator):
    """Replays a joint-space trajectory as if it were a human teleoperator."""

    config_class = ScriptedArmTeleopConfig
    name = "scripted_arm"

    def __init__(self, config: ScriptedArmTeleopConfig):
        super().__init__(config)
        self.config = config
        self._connected = False
        self._t0: float | None = None
        self._cycle = -1
        self._poses: list[dict[str, float]] = []

        spec = json.loads(Path(config.waypoints_path).read_text())
        self._steps: list[dict[str, Any]] = spec["cycle"]
        if not self._steps:
            raise ValueError(f"{config.waypoints_path}: 'cycle' is empty")
        for s in self._steps:
            missing = [j for j in JOINTS if j not in s["pose"]]
            if missing:
                raise ValueError(f"waypoint {s.get('name')!r} is missing joints: {missing}")
        # Absolute schedule: each step ramps for move_s then dwells for hold_s.
        self._schedule: list[tuple[float, float, dict[str, float]]] = []
        t = 0.0
        for s in self._steps:
            move_s, hold_s = float(s.get("move_s", 1.0)), float(s.get("hold_s", 0.0))
            self._schedule.append((t, t + move_s, s["pose"]))
            t += move_s + hold_s
        self.cycle_s = t

    # ---- Teleoperator interface -------------------------------------------------

    @property
    def action_features(self) -> dict:
        return {f"{j}.pos": float for j in JOINTS}

    @property
    def feedback_features(self) -> dict:
        return {}

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def is_calibrated(self) -> bool:
        return True  # a script has no hardware to calibrate

    def connect(self, calibrate: bool = True) -> None:
        self._connected = True
        self._t0 = None
        self._cycle = -1
        logger.info(
            "scripted_arm: %d waypoints, cycle = %.2fs. "
            "Pass --dataset.episode_time_s=%.0f so one episode == one cycle.",
            len(self._steps), self.cycle_s, math.ceil(self.cycle_s),
        )

    def calibrate(self) -> None:
        pass

    def configure(self) -> None:
        pass

    def send_feedback(self, feedback: dict[str, Any]) -> None:
        pass

    def disconnect(self) -> None:
        self._connected = False

    # ---- the action source ------------------------------------------------------

    def get_action(self) -> dict[str, float]:
        now = time.perf_counter()
        if self._t0 is None:
            self._t0 = now
        elapsed = now - self._t0

        cycle = int(elapsed // self.cycle_s)
        if cycle != self._cycle:          # new episode -> rebuild its waypoints
            self._cycle = cycle
            self._poses = self._poses_for_cycle(cycle)
        phase = elapsed % self.cycle_s

        pose = self._interpolate(phase)
        return {f"{j}.pos": self._clamp(j, v) for j, v in pose.items()}

    def _poses_for_cycle(self, cycle: int) -> list[dict[str, float]]:
        """Waypoint targets for one episode. Subclasses override this to
        source poses from somewhere other than the static file — see
        vision_reset_teleop.VisionResetTeleop, which solves them from a
        detection."""
        return self._jittered_poses(cycle)

    def _jittered_poses(self, cycle: int) -> list[dict[str, float]]:
        """Per-cycle waypoint targets, with flagged waypoints displaced.

        The offset is baked into the WAYPOINT, not added to the interpolated
        output, so the trajectory stays continuous: motion into and out of a
        jittered waypoint is interpolated the same as any other. Gating the
        offset by segment instead would step the command by up to `jitter`
        units in a single frame at the segment boundary.
        """
        rng = random.Random(self.config.seed + cycle)
        poses = []
        for step in self._steps:
            pose = dict(step["pose"])
            if step.get("jitter") and self.config.jitter:
                for j in BODY:
                    pose[j] = pose[j] + rng.uniform(-self.config.jitter, self.config.jitter)
            poses.append(pose)
        return poses

    def _interpolate(self, phase: float) -> dict[str, float]:
        poses = self._poses
        prev = poses[-1]                      # a cycle starts from where it ended
        for i, (t_start, t_end, _) in enumerate(self._schedule):
            if phase < t_start:
                break
            if phase <= t_end:
                span = max(t_end - t_start, 1e-6)
                a = self._ease((phase - t_start) / span)
                target = poses[i]
                return {j: prev[j] + (target[j] - prev[j]) * a for j in JOINTS}
            prev = poses[i]
        return dict(prev)

    @staticmethod
    def _ease(a: float) -> float:
        """Smoothstep — zero velocity at both ends, so no step-change jerk."""
        a = min(max(a, 0.0), 1.0)
        return a * a * (3.0 - 2.0 * a)

    def _clamp(self, joint: str, value: float) -> float:
        lo_hi = self.config.joint_limits.get(joint)
        if lo_hi:
            value = min(max(value, float(lo_hi[0])), float(lo_hi[1]))
        if joint == "gripper":
            hard = (0.0, 100.0)
        else:
            hard = (-180.0, 180.0) if self.config.use_degrees else (-100.0, 100.0)
        return min(max(value, hard[0]), hard[1])
