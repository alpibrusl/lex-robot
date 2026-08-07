"""A grant-aware wrapper around `LexXLeRobotFetch-v0`, for retraining a
policy toward the same envelope the real grant gate enforces — using
*actual usage data* (a recorded rollout's denial pattern, see
`xlerobot_usage_log.py`) to weight where it matters most.

The base env (`xlerobot_env.py`) has no notion of the grant at all: nothing
stops the trained policy's cumulative EE offset from drifting arbitrarily
far outside the workspace box it will actually be checked against at
replay time — which is exactly what happened with the first trained policy
(see README: it solves the task in raw physics, then every `move_arm` call
is denied). This wrapper closes that gap for *retraining*, without
touching the grant itself or the governed skill surface: it checks the
same bounds `examples/xlerobot_policy_rollout.lex`'s `arm_grant()`/
`base_grant()` check, and when a step would violate them:

  1. CLIPS the actually-applied offset/position to the boundary — so the
     physics the policy experiences during training already can't exceed
     the envelope it will be held to at deploy time (matching what
     "denied, target unreached" looks like from the policy's perspective:
     it doesn't get where it tried to go).
  2. Applies a PENALTY proportional to how far out of bounds the raw
     action wanted to go, weighted per-axis by --usage-log's axis_weights
     (an axis real usage violated more gets a stronger training signal) —
     so the gradient actively discourages the behavior, not just silently
     clips it (a silent clip alone gives the policy no reason to stop
     trying).

Grasp force compliance is out of scope here: the base env's grasp is a
binary trigger with no modulated force, so there is no force axis to
shape against.
"""
from __future__ import annotations

import mujoco
import numpy as np
import gymnasium as gym
from gymnasium.envs.registration import register

ARM_BOUNDS = {"x": (0.05, 0.45), "y": (-0.35, 0.35), "z": (0.0, 0.5)}
BASE_BOUNDS = {"x": (0.0, 4.0), "y": (0.0, 3.0)}
PENALTY_SCALE = 5.0  # metres of overshoot -> reward penalty, before axis weighting


def _clip_and_penalty(value, lo, hi, weight):
    if value < lo:
        return lo, (lo - value) * PENALTY_SCALE * weight
    if value > hi:
        return hi, (value - hi) * PENALTY_SCALE * weight
    return value, 0.0


class GovernedXLeRobotFetchEnv(gym.Wrapper):
    """Wraps `LexXLeRobotFetch-v0`; enforces the arm workspace box and base
    floor area every step, penalizing (and clipping) violations."""

    def __init__(self, env, axis_weights: dict | None = None):
        super().__init__(env)
        # axis_weights keys look like "move_to.x" / "move_base.y" (the same
        # shape xlerobot_usage_log.py prints) — default to 1.0 (unweighted,
        # equivalent to "no usage data yet, treat every axis equally").
        self.axis_weights = axis_weights or {}

    def _w(self, skill, axis):
        return self.axis_weights.get(f"{skill}.{axis}", 1.0)

    def step(self, action):
        obs, reward, terminated, truncated, info = self.env.step(action)
        raw = self.env.unwrapped
        penalty = 0.0
        corrected = False

        # Arm: clip raw.ee_off (arm-frame offset) into the workspace box.
        clipped = list(raw.ee_off)
        for i, axis in enumerate(("x", "y", "z")):
            lo, hi = ARM_BOUNDS[axis]
            clipped[i], p = _clip_and_penalty(raw.ee_off[i], lo, hi, self._w("move_to", axis))
            if p > 0.0:
                corrected = True
            penalty += p
        raw.ee_off = np.array(clipped, dtype=np.float64)

        # Base: clip the cart's world position into the floor area (and
        # zero the offending velocity component so the sim doesn't fight
        # the clip every subsequent step).
        bx, by = float(obs[0]), float(obs[1])
        for axis, (lo, hi), qpos_attr in (("x", BASE_BOUNDS["x"], "jx"), ("y", BASE_BOUNDS["y"], "jy")):
            v = bx if axis == "x" else by
            clamped_v, p = _clip_and_penalty(v, lo, hi, self._w("move_base", axis))
            penalty += p
            if p > 0.0:
                corrected = True
                qpos_adr = getattr(raw.sim, qpos_attr)
                base_origin = 0.5 if axis == "x" else 1.5  # XLeSim.base_xy()'s hardcoded origin
                raw.sim.d.qpos[qpos_adr] = clamped_v - base_origin
                raw.sim.d.qvel[qpos_adr] = 0.0

        if corrected:
            # Re-derive site/body positions (site_xpos etc.) for the corrected
            # qpos/mocap WITHOUT integrating dynamics, so the observation the
            # policy sees is consistent with the clip, not the pre-clip pose.
            raw.sim._ride_arms()
            mujoco.mj_forward(raw.sim.m, raw.sim.d)
        obs = raw._obs(raw.sim.observe())
        return obs, float(reward) - penalty, terminated, truncated, info


def make_governed_env(axis_weights: dict | None = None):
    import xlerobot_env  # noqa: F401 — registers LexXLeRobotFetch-v0
    base = gym.make("LexXLeRobotFetch-v0")
    return GovernedXLeRobotFetchEnv(base, axis_weights=axis_weights)


register(id="LexXLeRobotFetchGoverned-v0", entry_point="xlerobot_governed_env:make_governed_env")
