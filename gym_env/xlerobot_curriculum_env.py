"""Curriculum wrapper around the governed env: the workspace walls start
wide and anneal down to the real grant box over training.

Why (docs/RL_TRAINING.md, attempts 1-6): training against the fixed grant
box from the start — or finetuning into it, even from a genuinely
competent baseline (attempt 6) — collapses task performance without
buying compliance. The clip-and-penalize signal can suppress the
out-of-box reach but cannot *redirect* the strategy, because by the time
the walls exist the policy has already committed to a base-approach from
which the cup is (apparently) not reachable in-box. The curriculum
inverts the order: learn the task first with the walls effectively
absent, then move the walls in slowly enough that the policy adapts
where it parks the base while it still remembers how to lift.

Schedule (per env instance, measured in that instance's own steps so a
DummyVecEnv of N copies each anneal in lockstep with their share of the
total budget):

  phase 1  [0, warmup_frac)          walls at WIDE_ARM — effectively the
                                     ungoverned env; pure task learning
  phase 2  [warmup_frac, final_frac) walls interpolate linearly from
                                     WIDE_ARM to the real ARM_BOUNDS
  phase 3  [final_frac, 1.0]         walls at the exact grant box — the
                                     same numbers the replay gate checks

The base floor area stays at the real BASE_BOUNDS throughout: it is
roomy (4m x 3m), the winning strategies already respect it, and keeping
it fixed makes the base the *stable* thing the arm curriculum can lean
on — the policy is free (and increasingly pressured) to solve arm
violations by re-parking.

All the clip/penalty/reward-recompute machinery is inherited from
GovernedXLeRobotFetchEnv — this class only moves the walls.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import gymnasium as gym

from xlerobot_governed_env import ARM_BOUNDS, GovernedXLeRobotFetchEnv

# Wide enough that attempt 5's winning (ungoverned) trajectory fits with
# room to spare: its ee_off peaked around x 1.8 / y -1.07 / z 0.5.
WIDE_ARM = {"x": (-2.0, 2.5), "y": (-2.5, 2.5), "z": (-1.0, 1.5)}


class CurriculumXLeRobotFetchEnv(GovernedXLeRobotFetchEnv):
    """GovernedXLeRobotFetchEnv whose arm box anneals WIDE_ARM -> ARM_BOUNDS."""

    def __init__(self, env, horizon_steps: int, warmup_frac: float = 0.35,
                 final_frac: float = 0.85, axis_weights: dict | None = None,
                 arm_mode: str = "clip"):
        super().__init__(env, axis_weights=axis_weights, arm_mode=arm_mode)
        self.horizon_steps = max(1, int(horizon_steps))
        self.warmup_frac = warmup_frac
        self.final_frac = final_frac
        self.n_steps = 0
        self._apply_schedule()

    def progress(self) -> float:
        """0.0 = walls fully wide, 1.0 = walls at the real grant box."""
        a = self.warmup_frac * self.horizon_steps
        b = self.final_frac * self.horizon_steps
        if b <= a:
            return 1.0
        return min(1.0, max(0.0, (self.n_steps - a) / (b - a)))

    def _apply_schedule(self):
        p = self.progress()
        self.arm_bounds = {
            axis: (wl + (tl - wl) * p, wh + (th - wh) * p)
            for axis, ((wl, wh), (tl, th)) in
            ((a, (WIDE_ARM[a], ARM_BOUNDS[a])) for a in ("x", "y", "z"))
        }

    def step(self, action):
        self.n_steps += 1
        self._apply_schedule()
        return super().step(action)


def make_curriculum_env(horizon_steps: int, warmup_frac: float = 0.35,
                        final_frac: float = 0.85, axis_weights: dict | None = None,
                        arm_mode: str = "clip"):
    import xlerobot_env  # noqa: F401 — registers LexXLeRobotFetch-v0
    base = gym.make("LexXLeRobotFetch-v0")
    return CurriculumXLeRobotFetchEnv(
        base, horizon_steps=horizon_steps, warmup_frac=warmup_frac,
        final_frac=final_frac, axis_weights=axis_weights, arm_mode=arm_mode)
