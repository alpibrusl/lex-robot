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
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The gym env + policy are single-instance and NOT thread-safe. ThreadingHTTPServer
# handles requests concurrently, so serialize all skill calls — otherwise two
# rollouts step the same env at once and corrupt each other.
_SKILL_LOCK = threading.Lock()

HOST = os.environ.get("LEX_ROBOT_SIDECAR_HOST", "127.0.0.1")
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
ENV_ID = os.environ.get("LEX_ROBOT_GYM_ENV", "gym_pusht/PushT-v0")
DATASET_REPO = os.environ.get("LEX_ROBOT_DATASET", "lerobot/pusht")  # stats for normalization
SOLVE_REWARD = float(os.environ.get("LEX_ROBOT_SOLVE_REWARD", "0.90"))  # diffusion_pusht ~0.9 mean coverage
# PushT renders/acts in a 0..512 pixel plane. lex-robot poses are arbitrary
# units; we treat the incoming x,y as normalised [0,1] and scale to the plane.
PLANE = 512.0

from trail import Trail
EPISODE = Trail()
_TS = {"n": 0}


def _next_ts() -> int:
    _TS["n"] += 1
    return _TS["n"]


def record_skill_trail(name: str, args: dict, result: dict) -> None:
    """Append a cap.invoked + cap.completed pair for one skill call."""
    EPISODE.emit("cap.invoked",
                 json.dumps({"capability": name, "args": args}, sort_keys=True),
                 ts_ms=_next_ts())
    outcome = result.get("outcome", "reached")
    EPISODE.emit("cap.completed",
                 json.dumps({"capability": name, "result": outcome}, sort_keys=True),
                 ts_ms=_next_ts())


class Sim:
    """Owns one gym-pusht env. Created lazily so imports only fire on first use."""

    def __init__(self) -> None:
        import gymnasium as gym
        import gym_pusht  # noqa: F401 — registers the env id

        self.np = __import__("numpy")
        self.env = gym.make(ENV_ID, obs_type="pixels_agent_pos", render_mode="rgb_array")
        self.obs, _ = self.env.reset()
        self.policy = None
        self.policy_name = None
        self.dev = None
        self.pre = None
        self.post = None

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

    def _raw(self, o):
        # Unbatched raw obs; the preprocessor pipeline normalizes, batches, and
        # moves to device.
        import torch

        return {
            "observation.image": torch.from_numpy(o["pixels"]).permute(2, 0, 1).float().div(255),
            "observation.state": torch.from_numpy(self.np.asarray(o["agent_pos"], dtype=self.np.float32)),
        }

    def load_policy(self, name: str) -> None:
        from lerobot.policies.diffusion.modeling_diffusion import DiffusionPolicy
        from lerobot.policies.factory import make_pre_post_processors
        from lerobot.datasets.lerobot_dataset import LeRobotDatasetMetadata

        if self.policy_name != name:
            self.policy = DiffusionPolicy.from_pretrained(name)
            self.policy.eval()
            self.dev = self.policy.config.device
            # lerobot 0.5.x moved normalization into processor pipelines. The
            # old diffusion_pusht checkpoint has no processor JSONs, so build
            # them from the dataset stats — WITHOUT this the policy runs
            # unnormalized and scores ~0.
            meta = LeRobotDatasetMetadata(DATASET_REPO)
            self.pre, self.post = make_pre_post_processors(self.policy.config, dataset_stats=meta.stats)
            self.policy_name = name

    def rollout(self, name: str, max_steps: int):
        """Reset the env + policy and run the learned policy closed-loop."""
        import torch

        self.load_policy(name)
        self.obs, _ = self.env.reset()
        self.policy.reset()
        reward = 0.0
        max_reward = 0.0
        term = trunc = False
        steps = 0
        for steps in range(1, max_steps + 1):
            batch = self.pre(self._raw(self.obs))
            with torch.no_grad():
                action = self.post(self.policy.select_action(batch))
            self.obs, reward, term, trunc, _ = self.env.step(action.squeeze(0).cpu().numpy())
            max_reward = max(max_reward, reward)
            if term or trunc:
                break
        return steps, float(reward), float(max_reward), bool(term), bool(trunc)

    # ── Step-wise control (so the Lex grant can vet each command) ────────────
    def reset_episode(self, name: str):
        self.load_policy(name)
        self.obs, _ = self.env.reset()
        self.policy.reset()
        ap = self.obs["agent_pos"]
        return float(ap[0]) / PLANE, float(ap[1]) / PLANE

    def next_action(self):
        # What the policy *wants* — normalized to [0,1]. Does NOT step the env.
        import torch

        with torch.no_grad():
            a = self.post(self.policy.select_action(self.pre(self._raw(self.obs))))
        arr = a.squeeze(0).cpu().numpy()
        return float(arr[0]) / PLANE, float(arr[1]) / PLANE

    def apply(self, x_norm: float, y_norm: float):
        # Execute a (possibly grant-adjusted) command.
        action = self.np.array([x_norm * PLANE, y_norm * PLANE], dtype=self.np.float32)
        self.obs, reward, term, trunc, _ = self.env.step(action)
        ap = self.obs["agent_pos"]
        return float(reward), bool(term), bool(trunc), float(ap[0]) / PLANE, float(ap[1]) / PLANE


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
    if name == "reset_episode":
        x, y = sim().reset_episode(args.get("name", "lerobot/diffusion_pusht"))
        return {"agent_x": x, "agent_y": y}
    if name == "policy_action":
        x, y = sim().next_action()
        return {"x": x, "y": y}
    if name == "apply_action":
        r, term, trunc, ax, ay = sim().apply(float(args.get("x", 0.5)), float(args.get("y", 0.5)))
        return {"reward": r, "terminated": term, "truncated": trunc, "agent_x": ax, "agent_y": ay}
    return {"error": f"unknown skill: {name}"}


def run_policy(args: dict) -> dict:
    """Roll out a pretrained LeRobot policy in the env until success/timeout.

    Verified with lerobot 0.5.1 + lerobot/diffusion_pusht on Apple MPS. ~0.2s
    per step on CPU/MPS, so budget_ms maps to a step cap (≈10ms/step budget,
    capped at the PushT episode length of 300).
    """
    name = args.get("name", "lerobot/diffusion_pusht")
    budget_ms = int(args.get("budget_ms", 10000))
    max_steps = max(1, min(300, budget_ms // 100))
    try:
        steps, reward, max_reward, term, trunc = sim().rollout(name, max_steps)
    except Exception as e:
        return {"outcome": "stalled", "detail": f"run_policy error ({name}): {e}"}
    # PushT may not emit `terminated`; treat peak coverage ≥ threshold as solved.
    solved = term or max_reward >= SOLVE_REWARD
    outcome = "reached" if solved else "timeout"
    return {
        "outcome": outcome,
        "detail": f"steps={steps}, max_reward={max_reward:.3f}, final={reward:.3f}, policy={name}",
    }


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
            with _SKILL_LOCK:
                result = handle_skill(name, args)
                record_skill_trail(name, args, result)
                trail_path = os.environ.get("LEX_ROBOT_TRAIL", "/tmp/robot-trail.json")
                try:
                    with open(trail_path, "w") as f:
                        f.write(EPISODE.to_json())
                except OSError:
                    pass
            self._send(200, result)
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
