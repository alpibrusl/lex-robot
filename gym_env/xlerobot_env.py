"""Gymnasium environment for the XLeRobot — fetch-the-cup as an RL/BC task.

Wraps the same MuJoCo scene as the Tier-2 sidecar (xlerobot_sim.py), so a
policy trained here sees the physics the governed demo runs against, and its
action space maps 1:1 onto the governed skill surface:

  - base action = a velocity command (like move_base's target-chasing drive;
    note the env commands raw cart velocities, so the base is effectively
    holonomic here — the 0.4.0 differential turn-then-drive constraint applies
    on the sidecar path, XLeSim.drive)
  - EE action   = an ARM-FRAME displacement of the left end-effector (the
    frame move_arm's grant box is written in), and the EE rides the cart —
    it cannot be parked in space while the base drives away
  - grasp       = an EXPLICIT action (the governed path's grasp_arm — the
    force-capped, grant-checked skill), not an implicit auto-weld

Observation (Box, 11): base xy · left EE xyz · right EE xyz · cup xyz
Action (Box, 6): base velocity vx, vy · left-EE arm-frame displacement
                 dx, dy, dz · grasp trigger (> 0.5 attempts a grasp)
Reward: negative distance left-EE→cup, +10 bonus when the cup is lifted
        (grasped and raised above the counter).

Run from the repo root (a sys.path shim makes the flat sibling import work,
same trick as gym_env/server.py):

    import gymnasium, gym_env.xlerobot_env  # noqa
    env = gymnasium.make("LexXLeRobotFetch-v0")
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import mujoco
import numpy as np
import gymnasium as gym
from gymnasium import spaces
from gymnasium.envs.registration import register

from xlerobot_sim import XLeSim, GRASP_TOL, HOME_OFF

MAX_STEPS = 600
DT_STEPS = 4          # physics steps per env step
BASE_VMAX = 0.5       # m/s   (mirrors the demo's base grant ceiling)
EE_DMAX = 0.02        # m     per env step


class XLeRobotFetchEnv(gym.Env):
    """Drive to the counter, reach the cup, grasp, lift — under real contacts."""

    metadata = {"render_modes": []}

    def __init__(self):
        self.sim = XLeSim()
        self.steps = 0
        self.ee_off = HOME_OFF.copy()  # left-EE offset in the ARM frame
        big = np.finfo(np.float32).max
        self.observation_space = spaces.Box(-big, big, shape=(11,), dtype=np.float32)
        self.action_space = spaces.Box(
            low=np.array([-BASE_VMAX, -BASE_VMAX, -EE_DMAX, -EE_DMAX, -EE_DMAX, 0.0], dtype=np.float32),
            high=np.array([BASE_VMAX, BASE_VMAX, EE_DMAX, EE_DMAX, EE_DMAX, 1.0], dtype=np.float32),
            dtype=np.float32,
        )

    def _obs(self, o):
        return np.array(
            [o["base"]["x"], o["base"]["y"], *o["ee"]["left"], *o["ee"]["right"], *o["cup"]],
            dtype=np.float32,
        )

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        o = self.sim.reset()
        self.steps = 0
        self.ee_off = HOME_OFF.copy()
        return self._obs(o), {}

    def step(self, action):
        a = np.clip(action, self.action_space.low, self.action_space.high)
        self.sim.d.ctrl[0], self.sim.d.ctrl[1] = float(a[0]), float(a[1])
        self.ee_off = self.ee_off + np.array([a[2], a[3], a[4]], dtype=np.float64)
        # the left EE tracks its arm-frame offset; the right stays parked —
        # both ride the cart (same rule as the sidecar path's _ride_arms)
        self.sim.arm_off["left"] = self.ee_off
        for _ in range(DT_STEPS):
            self.sim._ride_arms()
            mujoco.mj_step(self.sim.m, self.sim.d)
        self.steps += 1

        if a[5] > 0.5 and not self.sim.d.eq_active[self.sim.weld["left"]]:
            self.sim.grasp("left")  # explicit, like the governed grasp_arm

        o = self.sim.observe()
        ee = np.array(o["ee"]["left"])
        cup = np.array(o["cup"])
        dist = float(np.linalg.norm(ee - cup))
        lifted = o["holding"]["left"] and cup[2] > 0.9
        reward = -dist + (10.0 if lifted else 0.0)
        terminated = bool(lifted)
        truncated = self.steps >= MAX_STEPS
        return self._obs(o), reward, terminated, truncated, {"holding": o["holding"]["left"]}


register(id="LexXLeRobotFetch-v0", entry_point="xlerobot_env:XLeRobotFetchEnv")
