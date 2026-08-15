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

    def __init__(self, env, axis_weights: dict | None = None, arm_mode: str = "clip",
                 grant_pull: float = 0.0):
        super().__init__(env)
        # axis_weights keys look like "move_to.x" / "move_base.y" (the same
        # shape xlerobot_usage_log.py prints) — default to 1.0 (unweighted,
        # equivalent to "no usage data yet, treat every axis equally").
        self.axis_weights = axis_weights or {}
        # Instance copies so a subclass can move the walls over training
        # (see xlerobot_curriculum_env.py) without touching the module
        # constants the grant gate's numbers come from.
        self.arm_bounds = dict(ARM_BOUNDS)
        self.base_bounds = dict(BASE_BOUNDS)
        # arm_mode selects what a violating arm step *does* (the penalty is
        # identical in both):
        #   "clip" — the offset is clamped to the boundary: you get most of
        #            what you asked for. Cheap to learn to lean on.
        #   "deny" — the WHOLE arm delta for this step is rejected and the
        #            arm stays where it was, matching what the real gate's
        #            "denied: target unreached" actually does to the robot.
        #            One escape hatch: if the arm is *already* outside the
        #            box (only possible when a curriculum anneal moved the
        #            walls past it), a delta that strictly reduces the total
        #            overshoot is accepted — a strict deny would freeze the
        #            arm out-of-bounds forever, since per-step deltas are
        #            capped far below the distance back to the box.
        if arm_mode not in ("clip", "deny"):
            raise ValueError(f"arm_mode must be 'clip' or 'deny', got {arm_mode!r}")
        self.arm_mode = arm_mode
        # grant_pull: an always-on soft cost, per step, proportional to how
        # far the arm offset sits outside the FINAL grant box (ARM_BOUNDS,
        # not the possibly-wider curriculum walls). Zero anywhere inside the
        # box — legal reaches are never taxed — but a stretched reach pays
        # rent every step it is held, even while curriculum walls are wide.
        # This targets the strategy the walls can't dislodge (attempts 5/7/9
        # all converge to the same ~0.75m x-lean): it makes the long reach
        # more expensive than driving the base, inside a dense-gradient
        # landscape, instead of fencing it out after the fact. Keep it well
        # below PENALTY_SCALE: this shapes preference, it is not a wall.
        self.grant_pull = float(grant_pull)

    def _w(self, skill, axis):
        return self.axis_weights.get(f"{skill}.{axis}", 1.0)

    def _arm_overshoot(self, off):
        """Total unweighted metres outside the current arm box, summed over axes."""
        total = 0.0
        for i, axis in enumerate(("x", "y", "z")):
            lo, hi = self.arm_bounds[axis]
            total += max(0.0, lo - off[i]) + max(0.0, off[i] - hi)
        return total

    def step(self, action):
        raw = self.env.unwrapped
        prev_off = np.array(raw.ee_off, dtype=np.float64)  # pre-step, for deny mode
        obs, reward, terminated, truncated, info = self.env.step(action)
        penalty = 0.0
        corrected = False

        # Arm: the attempted offset is raw.ee_off (the base env already
        # applied this step's delta). Penalize overshoot identically in both
        # modes; what differs is where the arm ends up.
        clipped = list(raw.ee_off)
        for i, axis in enumerate(("x", "y", "z")):
            lo, hi = self.arm_bounds[axis]
            clipped[i], p = _clip_and_penalty(raw.ee_off[i], lo, hi, self._w("move_to", axis))
            if p > 0.0:
                corrected = True
            penalty += p
        if corrected and self.arm_mode == "deny":
            # Reject the whole delta — unless the arm was already outside
            # (annealed walls) and this delta strictly moves it back toward
            # the box, which we accept un-clipped (see __init__).
            if self._arm_overshoot(prev_off) > 0.0 and \
                    self._arm_overshoot(raw.ee_off) < self._arm_overshoot(prev_off):
                pass  # inward from out-of-bounds: keep the attempted offset
            else:
                raw.ee_off = prev_off
        else:
            raw.ee_off = np.array(clipped, dtype=np.float64)

        if self.grant_pull > 0.0:
            # measured against the FINAL grant box (module ARM_BOUNDS), not
            # self.arm_bounds — see __init__.
            pull = 0.0
            for i, axis in enumerate(("x", "y", "z")):
                lo, hi = ARM_BOUNDS[axis]
                pull += max(0.0, lo - raw.ee_off[i]) + max(0.0, raw.ee_off[i] - hi)
            penalty += self.grant_pull * pull

        # Base: clip the cart's world position into the floor area (and
        # zero the offending velocity component so the sim doesn't fight
        # the clip every subsequent step).
        bx, by = float(obs[0]), float(obs[1])
        for axis, (lo, hi), joint_name in (("x", self.base_bounds["x"], "cart_x"), ("y", self.base_bounds["y"], "cart_y")):
            v = bx if axis == "x" else by
            clamped_v, p = _clip_and_penalty(v, lo, hi, self._w("move_base", axis))
            penalty += p
            if p > 0.0:
                corrected = True
                # qpos and qvel index different spaces (the cup's freejoint
                # takes 7 qpos slots but only 6 DOFs), so the position uses
                # the joint's qpos address and the velocity its DOF address.
                joint = raw.sim.m.joint(joint_name)
                base_origin = 0.5 if axis == "x" else 1.5  # XLeSim.base_xy()'s hardcoded origin
                raw.sim.d.qpos[joint.qposadr[0]] = clamped_v - base_origin
                raw.sim.d.qvel[joint.dofadr[0]] = 0.0

        if corrected:
            # Re-derive site/body positions (site_xpos etc.) for the corrected
            # qpos/mocap WITHOUT integrating dynamics, so the observation the
            # policy sees is consistent with the clip, not the pre-clip pose.
            raw.sim._ride_arms()
            mujoco.mj_forward(raw.sim.m, raw.sim.d)
            # The base env's `reward`/`terminated` were computed from the
            # PRE-clip position (self.env.step() already returned before we
            # got a chance to correct anything) — recompute both from the
            # corrected pose using the exact same formula xlerobot_env.py
            # uses, so the policy is actually rewarded for the compliant
            # position, not penalized on top of a reward that still credits
            # the violation. Without this, the penalty is fighting a reward
            # signal that never stopped preferring the out-of-bounds reach.
            o = raw.sim.observe()
            ee = np.array(o["ee"]["left"])
            cup = np.array(o["cup"])
            dist = float(np.linalg.norm(ee - cup))
            lifted = o["holding"]["left"] and cup[2] > 0.9
            reward = -dist + (10.0 if lifted else 0.0)
            terminated = bool(lifted)
        obs = raw._obs(raw.sim.observe())
        return obs, float(reward) - penalty, terminated, truncated, info


def make_governed_env(axis_weights: dict | None = None, arm_mode: str = "clip",
                      grant_pull: float = 0.0):
    import xlerobot_env  # noqa: F401 — registers LexXLeRobotFetch-v0
    base = gym.make("LexXLeRobotFetch-v0")
    return GovernedXLeRobotFetchEnv(base, axis_weights=axis_weights, arm_mode=arm_mode,
                                    grant_pull=grant_pull)


register(id="LexXLeRobotFetchGoverned-v0", entry_point="xlerobot_governed_env:make_governed_env")
