#!/usr/bin/env python3
"""Simulated LeRobot sidecar for lex-robot.

Implements the SIDECAR.md protocol with *fake* responses so the Lex side can be
developed and demoed without any robot, LeRobot install, or hardware. Swap each
handler body for a real LeRobot call to go live (see the `# REAL:` markers).

Dependency-free: uses only the Python standard library.

Run:
    python3 sidecar/sim_sidecar.py            # listens on 127.0.0.1:8900
    LEX_ROBOT_SIDECAR_PORT=9001 python3 ...   # override port
"""

import json
import math
import os
import random
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))

# ── Dangerous-tool state ─────────────────────────────────────────────────────
# Tracks whether the workpiece is present and physically clamped.
_TOOL_LOCK = threading.Lock()
_TOOL_STATE = {"clamped": False}

# ── Dynamic keep-out state ────────────────────────────────────────────────────
# Shared step counter for the dynamic-keepout demo. policy_action advances it;
# read_bystander reads it without advancing (both see the same step per loop).
_KO_LOCK = threading.Lock()
_KO_STATE = {"step": 0}

# ── QR bootstrap state ────────────────────────────────────────────────────────
# Simulates a QR display + camera pair: render_qr stores the payload and
# scan_qr returns it. A real implementation would drive an OLED/e-ink display
# and call a QR-decode library on the camera feed.
_QR_LOCK = threading.Lock()
_QR_STATE = {"payload": ""}

# ── A2A card state ────────────────────────────────────────────────────────────
# Pre-signed card blobs pushed by the Lex side on startup via
# POST /a2a/register-public-card and POST /a2a/register-extended-card.
# The sidecar stores and serves them — no crypto here.
_A2A_CARD_LOCK = threading.Lock()
_A2A_CARD_STATE = {"public": "", "extended": ""}


def _bystander_xy(step: int) -> tuple:
    """Bystander walks in from the right edge into the workspace centre.

    Phase 1 (steps 0-29): stays at (0.9, 0.5) — right side, outside policy path.
    Phase 2 (steps 30-59): walks linearly to (0.5, 0.5) — entering policy path.
    Phase 3 (steps 60+):   stays at (0.5, 0.5) — squarely in the policy path.
    """
    if step < 30:
        return (0.9, 0.5)
    elif step < 60:
        t = (step - 30) / 30.0
        return (round(0.9 - 0.4 * t, 4), 0.5)
    else:
        return (0.5, 0.5)


def _policy_xy(step: int) -> tuple:
    """Deterministic policy: sweeps x ∈ [0.1, 0.9] sinusoidally at y = 0.5.

    Period 20 steps; the sweep passes through x=0.9 (bystander's start) and
    x=0.5 (bystander's end), so the governed vs. ungoverned contrast is stark.
    """
    px = 0.5 + 0.4 * math.sin(2 * math.pi * (step % 20) / 20)
    return (round(px, 4), 0.5)


def handle_skill(name: str, args: dict) -> dict:
    """Route a skill call to a simulated outcome.

    The Lex grant has already vetted the call (workspace/force/skill allowlist)
    before it reaches here, so the sidecar only sees authorized requests.
    """
    if name == "workpiece_status":
        with _TOOL_LOCK:
            clamped = _TOOL_STATE["clamped"]
        return {"present": True, "clamped": clamped}
    if name == "clamp_workpiece":
        with _TOOL_LOCK:
            _TOOL_STATE["clamped"] = True
        return {"outcome": "reached", "detail": "workpiece clamped"}
    if name == "fire_tool":
        power = args.get("power", 0)
        x, y, z = args.get("x", 0), args.get("y", 0), args.get("z", 0)
        return {"outcome": "reached", "detail": f"tool fired at {power}W @ ({x},{y},{z})"}
    if name == "reset_episode":
        with _KO_LOCK:
            _KO_STATE["step"] = 0
        with _TOOL_LOCK:
            _TOOL_STATE["clamped"] = False
        return {"ok": "reset"}
    if name == "read_bystander":
        with _KO_LOCK:
            step = _KO_STATE["step"]
        bx, by = _bystander_xy(step)
        return {"x": bx, "y": by, "z": 0.0}
    if name == "policy_action":
        with _KO_LOCK:
            step = _KO_STATE["step"]
            _KO_STATE["step"] = step + 1  # advance for next loop iteration
        px, py = _policy_xy(step)
        return {"x": px, "y": py}
    if name == "apply_action":
        return {"reward": 0.0}
    if name == "render_qr":
        # REAL: encode payload as a QR code and display on the robot's screen
        payload = args.get("payload", "")
        with _QR_LOCK:
            _QR_STATE["payload"] = payload
        return {"ok": "displayed", "payload": payload}
    if name == "scan_qr":
        # REAL: capture camera frame, decode QR code, return payload string
        with _QR_LOCK:
            payload = _QR_STATE["payload"]
        return {"payload": payload}
    if name == "read_joints":
        # REAL: robot.read_joints()
        return {
            "names": ["shoulder", "elbow", "wrist", "gripper"],
            "positions": [round(random.uniform(-1, 1), 3) for _ in range(4)],
            "velocities": [0.0, 0.0, 0.0, 0.0],
        }
    if name == "read_camera":
        # REAL: encode the latest frame from the named camera as base64 JPEG
        return {"width": 640, "height": 480, "jpeg_b64": ""}
    if name == "move_to":
        # REAL: policy.move_to(Pose(**args)) with the high-rate loop
        return {"outcome": "reached", "detail": f"moved to ({args.get('x')},{args.get('y')},{args.get('z')})"}
    if name == "grasp":
        # REAL: gripper.close(force=args['force'])
        return {"outcome": "reached", "detail": f"grasped at {args.get('force')}N"}
    if name == "run_policy":
        # REAL: run the named LeRobot policy until goal/timeout (budget_ms)
        return {"outcome": "reached", "detail": f"policy {args.get('name')} reached goal"}
    if name == "record_episode":
        # REAL: record a LeRobotDataset episode for args['task']
        return {"episode_id": f"ep-{random.randint(1000, 9999)}", "frames": 240, "path": "/data/episodes/ep.parquet"}
    return {"error": f"unknown skill: {name}"}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, code: int, payload: str) -> None:
        body = payload.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path.startswith("/skill/"):
            name = self.path[len("/skill/"):]
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b"{}"
            try:
                args = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return self._send(400, {"error": "invalid json"})
            return self._send(200, handle_skill(name, args))
        if self.path == "/a2a/task":
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return self._send(400, {"error": "invalid json"})
            rpc_id = body.get("id", "")
            task = body.get("params", {}).get("task", {})
            skill = task.get("skill", "")
            args = task.get("args", {})
            result = handle_skill(skill, args)
            return self._send(200, {
                "jsonrpc": "2.0", "id": rpc_id,
                "result": {"kind": "artifact", "output": result},
            })
        if self.path in ("/a2a/register-public-card", "/a2a/register-extended-card"):
            length = int(self.headers.get("Content-Length", "0") or "0")
            blob = self.rfile.read(length).decode("utf-8") if length else ""
            key = "public" if "public" in self.path else "extended"
            with _A2A_CARD_LOCK:
                _A2A_CARD_STATE[key] = blob
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})

    def do_GET(self) -> None:
        if self.path == "/health":
            return self._send(200, {"ok": True})
        if self.path == "/a2a/public-card":
            with _A2A_CARD_LOCK:
                blob = _A2A_CARD_STATE["public"]
            if not blob:
                return self._send(503, {"error": "card not registered — call register_cards first"})
            return self._send_text(200, blob)
        if self.path == "/a2a/extended-card":
            if not self.headers.get("Authorization", "").startswith("Bearer "):
                return self._send(401, {"error": "missing bearer token"})
            with _A2A_CARD_LOCK:
                blob = _A2A_CARD_STATE["extended"]
            if not blob:
                return self._send(503, {"error": "extended card not registered — call register_cards first"})
            return self._send_text(200, blob)
        return self._send(404, {"error": "not found"})

    def log_message(self, *args) -> None:  # quieter logs
        print("[sidecar]", self.address_string(), self.command, self.path)


def main() -> None:
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot sim sidecar on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
