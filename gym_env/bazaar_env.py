"""Gymnasium environment for the bazaar demo — robot navigates to stalls."""

from __future__ import annotations

import math
import os
from pathlib import Path
from typing import Any

import mujoco
import numpy as np
import gymnasium as gym
from gymnasium import spaces

SCENE = Path(__file__).parent / "bazaar_scene.xml"

STALLS: dict[str, np.ndarray] = {
    "pottery": np.array([-3.0, 3.0]),
    "textile": np.array([3.0, 3.0]),
    "spices":  np.array([0.0, -3.0]),
}

ARRIVAL_RADIUS = 1.5   # metres — "at the stall" threshold
MAX_SPEED      = 3.0   # m/s
SCAN_RADIUS    = 8.0   # m — objects returned by scan_area
MAX_STEPS      = 1000  # per episode (1000 × 0.02 s = 20 s sim time)


class BazaarEnv(gym.Env):
    """
    Observation: [robot_x, robot_y, robot_vx, robot_vy,
                  dx_pottery, dy_pottery, dx_textile, dy_textile, dx_spices, dy_spices]
    Action:      [vx, vy]  in [-1, 1], scaled by MAX_SPEED
    """

    metadata = {"render_modes": ["human", "rgb_array"], "render_fps": 50}

    def __init__(self, render_mode: str | None = None):
        super().__init__()
        self.model = mujoco.MjModel.from_xml_path(str(SCENE))
        self.data  = mujoco.MjData(self.model)
        self.render_mode = render_mode
        self._renderer: mujoco.Renderer | None = None
        self._step_count = 0

        n_stalls = len(STALLS)
        obs_dim = 4 + 2 * n_stalls
        self.observation_space = spaces.Box(-np.inf, np.inf, shape=(obs_dim,), dtype=np.float32)
        self.action_space      = spaces.Box(-1.0, 1.0, shape=(2,), dtype=np.float32)

    # ── Gymnasium API ─────────────────────────────────────────────────────────

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        mujoco.mj_resetData(self.model, self.data)
        self._step_count = 0
        return self._obs(), {}

    def step(self, action: np.ndarray):
        vx, vy = np.clip(action, -1.0, 1.0) * MAX_SPEED
        self.data.ctrl[0] = vx
        self.data.ctrl[1] = vy
        mujoco.mj_step(self.model, self.data)
        self._step_count += 1

        obs     = self._obs()
        reward  = 0.0
        done    = self._step_count >= MAX_STEPS
        return obs, reward, done, False, {}

    def render(self):
        if self._renderer is None:
            self._renderer = mujoco.Renderer(self.model, height=480, width=640)
        self._renderer.update_scene(self.data, camera="free")
        return self._renderer.render()

    def close(self):
        if self._renderer:
            self._renderer.close()
            self._renderer = None

    # ── Skill API (called by the HTTP server) ─────────────────────────────────

    def skill_move_to(self, stall: str) -> dict:
        """Drive robot to stall using a simple P-controller. Returns when arrived or timeout."""
        if stall not in STALLS:
            return {"outcome": "error", "detail": f"unknown stall '{stall}'"}

        target = STALLS[stall]
        for _ in range(MAX_STEPS):
            pos = self._robot_xy()
            diff = target - pos
            dist = float(np.linalg.norm(diff))
            if dist < ARRIVAL_RADIUS:
                return {
                    "outcome": "reached",
                    "stall": stall,
                    "distance_m": round(dist, 2),
                    "pos": {"x": round(float(pos[0]), 2), "y": round(float(pos[1]), 2)},
                }
            speed = min(MAX_SPEED, dist * 2.0)
            direction = diff / max(dist, 1e-6)
            self.data.ctrl[0] = direction[0] * speed
            self.data.ctrl[1] = direction[1] * speed
            mujoco.mj_step(self.model, self.data)
            self._step_count += 1

        pos = self._robot_xy()
        return {
            "outcome": "timeout",
            "stall": stall,
            "remaining_m": round(float(np.linalg.norm(target - pos)), 2),
        }

    def skill_scan_area(self) -> dict:
        """Return stalls and distances within SCAN_RADIUS."""
        pos = self._robot_xy()
        nearby = []
        for name, spos in STALLS.items():
            dist = float(np.linalg.norm(spos - pos))
            if dist <= SCAN_RADIUS:
                nearby.append({
                    "name": name,
                    "distance_m": round(dist, 2),
                    "bearing_deg": round(math.degrees(math.atan2(
                        float(spos[1] - pos[1]), float(spos[0] - pos[0])
                    )), 1),
                })
        nearby.sort(key=lambda s: s["distance_m"])
        return {
            "robot_pos": {"x": round(float(pos[0]), 2), "y": round(float(pos[1]), 2)},
            "stalls_visible": nearby,
        }

    def skill_robot_state(self) -> dict:
        pos = self._robot_xy()
        vel = self._robot_vel()
        return {
            "pos": {"x": round(float(pos[0]), 2), "y": round(float(pos[1]), 2)},
            "vel": {"vx": round(float(vel[0]), 2), "vy": round(float(vel[1]), 2)},
            "speed_ms": round(float(np.linalg.norm(vel)), 2),
            "step": self._step_count,
        }

    # ── Internals ─────────────────────────────────────────────────────────────

    def _robot_xy(self) -> np.ndarray:
        robot_id = mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_BODY, "robot")
        return self.data.xpos[robot_id, :2].copy()

    def _robot_vel(self) -> np.ndarray:
        robot_id = mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_BODY, "robot")
        # qvel indices for the freejoint: [vx, vy, vz, wx, wy, wz]
        jnt_id   = mujoco.mj_name2id(self.model, mujoco.mjtObj.mjOBJ_JOINT, "robot_joint")
        qadr     = self.model.jnt_qposadr[jnt_id]
        vadr     = self.model.jnt_dofadr[jnt_id]
        return self.data.qvel[vadr:vadr+2].copy()

    def _obs(self) -> np.ndarray:
        pos = self._robot_xy()
        vel = self._robot_vel()
        stall_deltas = np.concatenate([STALLS[k] - pos for k in sorted(STALLS)])
        return np.concatenate([pos, vel, stall_deltas]).astype(np.float32)
