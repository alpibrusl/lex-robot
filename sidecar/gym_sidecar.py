#!/usr/bin/env python3
"""gym-pusht backed sidecar for lex-robot.

A real-physics testing backend: wraps LeRobot's `gym-pusht` environment behind
the same SIDECAR.md protocol the stub uses, so the Lex side is unchanged — only
the backend swaps (stub → gym → real hardware).

PushT is a 2D pushing task: a point "agent" pushes a T-shaped block onto a goal.
It has no gripper and no 6-DOF arm, so the mapping is intentionally lossy
(documented per skill below). It's the lightest real-sim option (pymunk/pygame,
no MuJoCo) and ships a pretrained Diffusion Policy.

Install (Python 3.10+):
    pip install gymnasium gym-pusht pillow numpy
    pip install lerobot        # only for run_policy (pretrained policy rollout)

Run:
    python3 sidecar/gym_sidecar.py                 # 127.0.0.1:8900
    LEX_ROBOT_SIDECAR_PORT=9001 python3 ...        # override port

Verified locally on macOS / Python 3.14 with gym-pusht 0.1.6 (read_joints,
read_camera, move_to, record_episode work end-to-end). IMPORTANT: pin
`pymunk<7` — gym-pusht 0.1.6 uses the pymunk 6.x collision-handler API and
pymunk 7 breaks the env. `run_policy`'s rollout loop is the one remaining TODO
(LeRobot version-specific — see run_policy below).
"""

import base64
import io as _io
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
ENV_ID = os.environ.get("LEX_ROBOT_GYM_ENV", "gym_pusht/PushT-v0")
# PushT renders/acts in a 0..512 pixel plane. lex-robot poses are arbitrary
# units; we treat the incoming x,y as normalised [0,1] and scale to the plane.
PLANE = 512.0


class Sim:
    """Owns one gym-pusht env. Created lazily so imports only fire on first use."""

    def __init__(self) -> None:
        import gymnasium as gym
        import gym_pusht  # noqa: F401 — registers the env id

        self.np = __import__("numpy")
        self.env = gym.make(ENV_ID, obs_type="pixels_agent_pos", render_mode="rgb_array")
        self.obs, _ = self.env.reset()

    def agent_pos(self):
        ap = self.obs["agent_pos"] if isinstance(self.obs, dict) else None
        return [float(v) for v in ap] if ap is not None else []

    def frame_jpeg_b64(self) -> str:
        try:
            from PIL import Image
        except Exception:
            return ""
        arr = self.env.render()
        img = Image.fromarray(arr)
        buf = _io.BytesIO()
        img.save(buf, format="JPEG", quality=70)
        return base64.b64encode(buf.getvalue()).decode()

    def step_toward(self, x_norm: float, y_norm: float, steps: int = 8):
        """Drive the point agent toward a normalised (x,y) target."""
        action = self.np.array([x_norm * PLANE, y_norm * PLANE], dtype=self.np.float32)
        terminated = truncated = False
        reward = 0.0
        for _ in range(steps):
            self.obs, reward, terminated, truncated, _ = self.env.step(action)
            if terminated or truncated:
                break
        return float(reward), bool(terminated), bool(truncated)


SIM = None


def sim() -> "Sim":
    global SIM
    if SIM is None:
        SIM = Sim()
    return SIM


def handle_skill(name: str, args: dict) -> dict:
    if name == "read_joints":
        # PushT has no joints; surface the 2D agent position instead.
        return {"names": ["agent_x", "agent_y"], "positions": sim().agent_pos(), "velocities": [0.0, 0.0]}
    if name == "read_camera":
        return {"width": 512, "height": 512, "jpeg_b64": sim().frame_jpeg_b64()}
    if name == "move_to":
        # 6-DOF pose → 2D target (x,y only; z/rotation ignored in PushT).
        # Success for a *move* primitive = the agent advanced toward the target
        # (the env didn't end the episode). Task completion is a bonus, surfaced
        # via the coverage reward in detail.
        reward, terminated, truncated = sim().step_toward(float(args.get("x", 0.5)), float(args.get("y", 0.5)))
        outcome = "timeout" if truncated else "reached"
        return {"outcome": outcome, "detail": f"coverage_reward={reward:.3f}, task_solved={terminated}"}
    if name == "grasp":
        return {"outcome": "stalled", "detail": "gym-pusht has no gripper"}
    if name == "run_policy":
        return run_policy(args)
    if name == "record_episode":
        return record_episode(args)
    return {"error": f"unknown skill: {name}"}


def run_policy(args: dict) -> dict:
    """Roll out a pretrained LeRobot policy in the env until success/timeout.

    The LeRobot policy import path and obs formatting vary by version, so this is
    best-effort and fails loudly with guidance rather than guessing silently.
    """
    name = args.get("name", "lerobot/diffusion_pusht")
    budget_ms = int(args.get("budget_ms", 30000))
    try:
        import torch
        from lerobot.common.policies.factory import make_policy  # path may differ by version
        del torch, make_policy
    except Exception as e:
        return {
            "outcome": "stalled",
            "detail": f"run_policy needs lerobot installed and the policy import wired for your "
            f"version (tried lerobot.common.policies.factory): {e}",
        }
    # Wiring the exact obs→policy→action loop is version-specific; left as the
    # one TODO that must be matched to the installed LeRobot. Until then:
    return {"outcome": "stalled", "detail": f"policy {name} loaded; rollout loop not wired (budget_ms={budget_ms})"}


def record_episode(args: dict) -> dict:
    """Lightweight episode capture: step the env and save frames to .npz.

    Full LeRobotDataset export is a follow-up; this proves the capture path.
    """
    task = args.get("task", "pusht")
    n = int(args.get("steps", 120))
    s = sim()
    frames = []
    for _ in range(n):
        s.obs, _, term, trunc, _ = s.env.step(s.env.action_space.sample())
        frames.append(s.env.render())
        if term or trunc:
            break
    path = f"/tmp/lex-robot-episode-{task}.npz"
    try:
        s.np.savez_compressed(path, frames=s.np.array(frames))
    except Exception as e:
        return {"error": f"save failed: {e}"}
    return {"episode_id": f"ep-{task}", "frames": len(frames), "path": path}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if not self.path.startswith("/skill/"):
            return self._send(404, {"error": "not found"})
        name = self.path[len("/skill/"):]
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            args = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"error": "invalid json"})
        try:
            self._send(200, handle_skill(name, args))
        except Exception as e:  # surface sim errors to the Lex side as a stall
            self._send(200, {"outcome": "stalled", "detail": f"sim error: {e}"})

    def do_GET(self) -> None:
        if self.path == "/health":
            return self._send(200, {"ok": True, "env": ENV_ID})
        return self._send(404, {"error": "not found"})

    def log_message(self, *args) -> None:
        print("[gym-sidecar]", self.command, self.path)


def main() -> None:
    # Pre-warm the env so the first skill call isn't blocked by the slow
    # pygame/SDL import + env construction (which can exceed the client's
    # request timeout).
    print(f"building {ENV_ID} …")
    sim()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot gym sidecar ({ENV_ID}) on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
