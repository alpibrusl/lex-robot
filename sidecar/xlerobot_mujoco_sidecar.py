#!/usr/bin/env python3
"""Tier-2 MuJoCo XLeRobot sidecar for lex-robot.

Real physics behind the SAME protocol as the Tier-1 stub
(xlerobot_sidecar.py), so examples/xlerobot_demo.lex runs against it
unchanged: a velocity-actuated holonomic cart drives through real contacts,
the arm end-effectors are Cartesian-teleoperated (mocap), and a grasp within
tolerance welds the object into the hand — the depot-G1 tricks, applied to
the XLeRobot's dual-arm-on-a-cart shape. The scene lives in
gym_env/xlerobot_sim.py, shared with the Gymnasium env.

Firmware floors (grip force, base speed) are enforced here independently of
the Lex grant clamps — defense in depth, DESIGN.md §8.

Deps: pip install mujoco numpy. Run:  python3 sidecar/xlerobot_mujoco_sidecar.py
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "gym_env"))
from xlerobot_sim import XLeSim  # noqa: E402

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
HARD_GRIP_N = float(os.environ.get("LEX_XLE_HARD_GRIP_N", "25"))
HARD_SPEED_MPS = float(os.environ.get("LEX_XLE_HARD_SPEED_MPS", "1.0"))

_LOCK = threading.Lock()
SIM = XLeSim()


def handle_skill(name, args):
    if name == "reset":
        return SIM.reset()
    if name == "read_base":
        return SIM.observe()["base"]
    if name == "read_joints":
        arm = args.get("arm", "left")
        obs = SIM.observe()
        return {"names": [f"{arm}_ee_{ax}" for ax in "xyz"],
                "positions": obs["ee"][arm], "velocities": [0.0, 0.0, 0.0]}
    if name == "move_base":
        speed = min(float(args.get("speed", 0.3)), HARD_SPEED_MPS)  # firmware floor
        return SIM.drive(float(args.get("x", 0.0)), float(args.get("y", 0.0)), speed)
    if name == "move_arm":
        return SIM.reach(args.get("arm", "left"), float(args.get("x", 0.2)),
                         float(args.get("y", 0.0)), float(args.get("z", 0.2)))
    if name == "grasp_arm":
        force = float(args.get("force", 10.0))
        if force > HARD_GRIP_N:  # firmware floor, independent of the grant clamp
            return {"outcome": "stalled",
                    "detail": f"grip {force:.0f}N exceeds firmware limit {HARD_GRIP_N:.0f}N"}
        return SIM.grasp(args.get("arm", "left"))
    if name == "release_arm":
        return SIM.release(args.get("arm", "left"))
    if name == "observe":
        return SIM.observe()
    return {"error": f"unknown skill: {name}"}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return None

    def do_POST(self):
        args = self._body()
        if args is None:
            return self._send(400, {"error": "invalid json"})
        if self.path.startswith("/skill/"):
            with _LOCK:
                return self._send(200, handle_skill(self.path[len("/skill/"):], args))
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            with _LOCK:
                return self._send(200, {"ok": True, "physics": "mujoco", "base": SIM.observe()["base"]})
        return self._send(404, {"error": "not found"})

    def log_message(self, *a):
        print("[xlerobot-mujoco]", self.command, self.path)


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot XLeRobot MuJoCo sidecar on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
