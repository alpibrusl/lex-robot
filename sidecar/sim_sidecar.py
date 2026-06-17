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

import base64 as _b64
import json
import math
import os
import random
import threading
import time
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

# ── A2A identity ──────────────────────────────────────────────────────────────
# Fixed 32-byte seed for the sim keypair — deterministic so the pubkey_b64 is
# stable across restarts (useful for CachedChannel tests in Lex).
# In production, generate with os.urandom(32) and persist.
_A2A_SEED = b"lex-robot-sim-key-00000000000000"  # exactly 32 bytes

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat as _PF

    _A2A_PRIV = Ed25519PrivateKey.from_private_bytes(_A2A_SEED)
    _A2A_PUB_B64 = _b64.urlsafe_b64encode(
        _A2A_PRIV.public_key().public_bytes(Encoding.Raw, _PF.Raw)
    ).rstrip(b"=").decode()
    _A2A_OK = True
except ImportError:
    _A2A_PRIV = None
    _A2A_PUB_B64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    _A2A_OK = False

_A2A_PUBLIC_SKILLS = [
    {"name": "move_to",     "description": "Move end-effector to xyz"},
    {"name": "grasp",       "description": "Close gripper with force"},
    {"name": "read_joints", "description": "Read joint states"},
    {"name": "read_camera", "description": "Capture camera frame"},
]
_A2A_EXTENDED_SKILLS = _A2A_PUBLIC_SKILLS + [
    {"name": "run_policy",     "description": "Run a named LeRobot policy"},
    {"name": "record_episode", "description": "Record a LeRobot dataset episode"},
    {"name": "reset_episode",  "description": "Reset episode state"},
]


def _skills_json(skills: list) -> str:
    parts = [
        f'{{"name":"{s["name"]}","description":"{s["description"]}"}}'
        for s in skills
    ]
    return "[" + ",".join(parts) + "]"


def _card_json(tier: str, skills: list, supports_extended: bool) -> str:
    """Canonical card JSON matching a2a_card.lex card_to_json field order."""
    endpoint = f"http://{HOST}:{PORT}"
    sup = "true" if supports_extended else "false"
    return (
        f'{{"name":"sim-robot","endpoint":"{endpoint}",'
        f'"pubkey_b64":"{_A2A_PUB_B64}","tier":"{tier}",'
        f'"supports_extended":{sup},"skills":{_skills_json(skills)}}}'
    )


def _sign_card(card_json: str) -> str:
    sig = _A2A_PRIV.sign(card_json.encode())
    return _b64.urlsafe_b64encode(sig).rstrip(b"=").decode()


def _card_response(tier: str, skills: list, supports_extended: bool) -> str:
    """Wire format: <card_json>\n<sig_b64>  (as expected by a2a_handshake.lex)."""
    cj = _card_json(tier, skills, supports_extended)
    return cj + "\n" + _sign_card(cj)


def _sim_bootstrap_blob() -> str:
    """Build a base64url bootstrap blob for this sidecar (for CachedChannel tests)."""
    endpoint = f"http://{HOST}:{PORT}"
    nonce = f"sim-{random.randint(100000, 999999)}"
    expires_at = int(time.time() * 1000) + 365 * 24 * 60 * 60 * 1000  # +1 year
    blob_json = (
        f'{{"endpoint":"{endpoint}","ephemeral_token":"sim-token",'
        f'"peer_pubkey":"{_A2A_PUB_B64}","nonce":"{nonce}","expires_at":{expires_at}}}'
    )
    return _b64.urlsafe_b64encode(blob_json.encode()).rstrip(b"=").decode()


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
        return self._send(404, {"error": "not found"})

    def do_GET(self) -> None:
        if self.path == "/health":
            return self._send(200, {"ok": True})
        if self.path == "/a2a/public-card":
            if not _A2A_OK:
                return self._send(503, {"error": "pip install cryptography to enable A2A"})
            return self._send_text(200, _card_response("public", _A2A_PUBLIC_SKILLS, True))
        if self.path == "/a2a/extended-card":
            if not _A2A_OK:
                return self._send(503, {"error": "pip install cryptography to enable A2A"})
            if not self.headers.get("Authorization", "").startswith("Bearer "):
                return self._send(401, {"error": "missing bearer token"})
            return self._send_text(200, _card_response("extended", _A2A_EXTENDED_SKILLS, True))
        return self._send(404, {"error": "not found"})

    def log_message(self, *args) -> None:  # quieter logs
        print("[sidecar]", self.address_string(), self.command, self.path)


def main() -> None:
    if not _A2A_OK:
        print("[sidecar] WARNING: 'cryptography' not installed — /a2a/* endpoints disabled")
        print("[sidecar]          pip install cryptography  to enable A2A handshake sim")
    else:
        with _QR_LOCK:
            _QR_STATE["payload"] = _sim_bootstrap_blob()
        print(f"[sidecar] A2A pubkey_b64: {_A2A_PUB_B64}")
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot sim sidecar on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
