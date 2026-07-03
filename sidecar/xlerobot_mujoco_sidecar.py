#!/usr/bin/env python3
"""Tier-2 MuJoCo XLeRobot sidecar for lex-robot.

Real physics behind the SAME protocol as the Tier-1 stub
(xlerobot_sidecar.py), so examples/xlerobot_demo.lex runs against it
unchanged: a velocity-actuated cart drives through real contacts (0.4.0
differential kinematics by default, LEX_XLE_BASE=omni for the older base),
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


ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]


def arm_of(args):
    """Validate the arm name; None means reject (parity with the Tier-1 stub)."""
    arm = args.get("arm", "left")
    return arm if arm in ("left", "right") else None


def bad_arm(args):
    return {"outcome": "stalled", "detail": f"unknown arm '{args.get('arm')}' (use left|right)"}


def handle_skill(name, args):
    if name == "reset":
        return SIM.reset()
    if name == "read_base":
        return SIM.observe()["base"]
    if name == "read_joints":
        arm = arm_of(args)
        if arm is None:
            return bad_arm(args)
        # Same 6-joint response shape as the Tier-1 stub (SO-101 names): the
        # teleop sim has no joint model, so EE xyz fills the first three slots
        # and the gripper slot reflects the weld state.
        obs = SIM.observe()
        grip = 1.0 if obs["holding"][arm] else 0.0
        return {"names": [f"{arm}_{j}" for j in ARM_JOINTS],
                "positions": [*obs["ee"][arm], 0.0, 0.0, grip],
                "velocities": [0.0] * 6}
    if name == "move_base":
        speed = min(float(args.get("speed", 0.3)), HARD_SPEED_MPS)  # firmware floor
        return SIM.drive(float(args.get("x", 0.0)), float(args.get("y", 0.0)), speed)
    if name == "move_arm":
        arm = arm_of(args)
        if arm is None:
            return bad_arm(args)
        return SIM.reach(arm, float(args.get("x", 0.2)),
                         float(args.get("y", 0.0)), float(args.get("z", 0.2)))
    if name == "grasp_arm":
        arm = arm_of(args)
        if arm is None:
            return bad_arm(args)
        force = float(args.get("force", 10.0))
        if force > HARD_GRIP_N:  # firmware floor, independent of the grant clamp
            return {"outcome": "stalled",
                    "detail": f"grip {force:.0f}N exceeds firmware limit {HARD_GRIP_N:.0f}N"}
        return SIM.grasp(arm)
    if name == "release_arm":
        arm = arm_of(args)
        if arm is None:
            return bad_arm(args)
        return SIM.release(arm)
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
            # deliberately lock-free (like the depot sidecars): a long drive
            # holding _LOCK must not make health polls report the sim as dead
            return self._send(200, {"ok": True, "physics": "mujoco"})
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
