"""Gymnasium environment for the XLeRobot — fetch-the-cup as an RL/BC task.

Wraps the same MuJoCo scene as the Tier-2 sidecar (xlerobot_sim.py), so a
policy trained here sees exactly the physics the governed demo runs against.
The intended use is the safe-RL/eval loop the README describes: train or
script a policy here, roll it out through the Lex grant gate (every command
vetted), and submit the episode trail to the lex-games robot_task referee.

Observation (Box, 11): base xy · left EE xyz · right EE xyz · cup xyz
Action (Box, 5): base velocity vx, vy · left-EE displacement dx, dy, dz
Reward: negative distance left-EE→cup, +10 bonus when the cup is lifted
        (grasped and carried above the counter edge away from its start).

    import gymnasium, gym_env.xlerobot_env  # noqa
    env = gymnasium.make("LexXLeRobotFetch-v0")
"""

from __future__ import annotations

import numpy as np
import gymnasium as gym
from gymnasium import spaces
from gymnasium.envs.registration import register

from xlerobot_sim import XLeSim, GRASP_TOL

MAX_STEPS = 600
DT_STEPS = 4          # physics steps per env step
BASE_VMAX = 0.5       # m/s   (mirrors the demo's base grant ceiling)
EE_DMAX = 0.02        # m     per env step


class XLeRobotFetchEnv(gym.Env):
    """Drive to the counter, reach the cup, lift it — under real contacts."""

    metadata = {"render_modes": []}

    def __init__(self):
        self.sim = XLeSim()
        self.steps = 0
        big = np.finfo(np.float32).max
        self.observation_space = spaces.Box(-big, big, shape=(11,), dtype=np.float32)
        self.action_space = spaces.Box(
            low=np.array([-BASE_VMAX, -BASE_VMAX, -EE_DMAX, -EE_DMAX, -EE_DMAX], dtype=np.float32),
            high=np.array([BASE_VMAX, BASE_VMAX, EE_DMAX, EE_DMAX, EE_DMAX], dtype=np.float32),
            dtype=np.float32,
        )

    def _obs(self):
        o = self.sim.observe()
        return np.array(
            [o["base"]["x"], o["base"]["y"], *o["ee"]["left"], *o["ee"]["right"], *o["cup"]],
            dtype=np.float32,
        )

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        self.sim.reset()
        self.steps = 0
        return self._obs(), {}

    def step(self, action):
        import mujoco

        a = np.clip(action, self.action_space.low, self.action_space.high)
        self.sim.d.ctrl[0], self.sim.d.ctrl[1] = float(a[0]), float(a[1])
        mocap = self.sim.mocap["left"]
        self.sim.d.mocap_pos[mocap] = self.sim.d.mocap_pos[mocap] + np.array(
            [a[2], a[3], a[4]], dtype=np.float64
        )
        for _ in range(DT_STEPS):
            mujoco.mj_step(self.sim.m, self.sim.d)
        self.steps += 1

        o = self.sim.observe()
        ee = np.array(o["ee"]["left"])
        cup = np.array(o["cup"])
        dist = float(np.linalg.norm(ee - cup))

        # auto-grasp when in tolerance (the sidecar path makes this explicit)
        if dist < GRASP_TOL and not o["holding"]["left"]:
            self.sim.grasp("left")
            o = self.sim.observe()

        lifted = o["holding"]["left"] and cup[2] > 0.9
        reward = -dist + (10.0 if lifted else 0.0)
        terminated = bool(lifted)
        truncated = self.steps >= MAX_STEPS
        return self._obs(), reward, terminated, truncated, {"holding": o["holding"]["left"]}


register(id="LexXLeRobotFetch-v0", entry_point="xlerobot_env:XLeRobotFetchEnv")
