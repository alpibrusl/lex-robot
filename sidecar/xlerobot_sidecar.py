#!/usr/bin/env python3
"""XLeRobot 0.4.0 sidecar (dual SO-101 arms + wheeled base) for lex-robot.

Target hardware: the XLeRobot **0.4.0** (WowRobo kit / Vector-Wangel/
XLeRobot) — two 5-DOF SO-101 arms (STS3215 servos, ~40 cm reach, ~0.6–1 kg
payload per arm; 0.4.0's optional soft finray TPU fingers make the firmware
grip floor doubly appropriate) on 0.4.0's dual-wheel differential base, with
a head RGB camera (webcam / RealSense / hand-cam variants). Everything
LeRobot-native, so the hardware leg goes through LeRobot exactly like the
depot seam (depot_hw_sidecar.py). move_base is a goal-point command, so the
skill surface and grants are identical for the older 3-omni holonomic base.

This is the **transfer point** for that robot: the standard lex-robot sidecar
protocol (SIDECAR.md), plus three XLeRobot skills:

    move_arm  {"arm":"left|right", x,y,z,rx,ry,rz}   → outcome
    grasp_arm {"arm":"left|right", "force": N}        → outcome
    move_base {"x","y","speed"}                       → outcome
    read_base {}                                      → {"x","y","heading"}

Out of the box it runs as a **stub** (stdlib only, no hardware, no pip): the
base integrates kinematically toward the target, the arms report plausible
joint states, and grasp obeys an independent firmware grip floor. Set
LEX_ROBOT_HW=1 with the LeRobot ports configured to drive the real robot —
fill in the `# REAL:` blocks.

Two layers of safety, by design (DESIGN.md §8):
  1. The Lex **grants** (one for the arms' reach box, one for the base's
     permitted floor area) already vetted the target and clamped grip force /
     base speed BEFORE the command reached this process.
  2. This sidecar independently enforces **firmware floors** — grip force
     (LEX_XLE_HARD_GRIP_N) and base speed (LEX_XLE_HARD_SPEED_MPS) — and a
     real deployment sits behind a hardware e-stop. A software grant is the
     logical boundary, never physical safety.

Run:
    python3 sidecar/xlerobot_sidecar.py                 # stub (no hardware)
    LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py  # drive the real robot
"""

import json
import math
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
# Firmware floors — independent of (and behind) the Lex grant clamps.
# STS3215 servos are 30 kg·cm class; 25 N at the fingertips is already generous.
HARD_GRIP_N = float(os.environ.get("LEX_XLE_HARD_GRIP_N", "25"))
HARD_SPEED_MPS = float(os.environ.get("LEX_XLE_HARD_SPEED_MPS", "1.0"))
USE_HW = os.environ.get("LEX_ROBOT_HW", "0") == "1"

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]


class XLeRobot:
    """Thin wrapper around the real LeRobot XLeRobot, or a kinematic stub."""

    def __init__(self):
        self.robot = None
        self.base = {"x": 0.0, "y": 0.0, "heading": 0.0}
        self.arms = {
            "left": {"positions": [0.0] * 6, "holding": False},
            "right": {"positions": [0.0] * 6, "holding": False},
        }
        if USE_HW:
            # REAL: bring up the LeRobot robot for the XLeRobot, e.g. (lerobot ≥0.5,
            # names per your calibration):
            #   from lerobot.robots.xlerobot import XLerobotConfig, XLerobot
            #   cfg = XLerobotConfig(left_arm_port=os.environ["LEX_XLE_LEFT_PORT"],
            #                        right_arm_port=os.environ["LEX_XLE_RIGHT_PORT"],
            #                        base_port=os.environ["LEX_XLE_BASE_PORT"])
            #   self.robot = XLerobot(cfg); self.robot.connect()
            # (If your lerobot version has no xlerobot config yet, compose two
            #  SO101Follower configs + the LeKiwi-style base the same way.)
            raise SystemExit(
                "LEX_ROBOT_HW=1 but no LeRobot robot is wired up yet — fill in the "
                "`# REAL:` blocks in xlerobot_sidecar.py with your ports/config."
            )

    def reset(self):
        # REAL: home both arms to a safe tucked pose, zero the base odometry.
        self.base = {"x": 0.0, "y": 0.0, "heading": 0.0}
        for a in self.arms.values():
            a["positions"] = [0.0] * 6
            a["holding"] = False
        return {"base": dict(self.base), "arms": {k: list(v["positions"]) for k, v in self.arms.items()}}

    # ---- sensing -------------------------------------------------------------
    def read_joints(self, arm):
        # REAL: obs = self.robot.get_observation(); pull <arm>_*.pos out of it.
        a = self.arms.get(arm, self.arms["left"])
        return {
            "names": [f"{arm}_{j}" for j in ARM_JOINTS],
            "positions": list(a["positions"]),
            "velocities": [0.0] * 6,
        }

    def read_base(self):
        # REAL: return odometry from the base (wheel encoders / SLAM pose).
        return dict(self.base)

    def read_camera(self, name):
        # REAL: grab a frame from the head / wrist camera and JPEG-encode it.
        return {"width": 640, "height": 480, "jpeg_b64": ""}

    # ---- actuation -----------------------------------------------------------
    def move_arm(self, arm, x, y, z):
        # REAL: closed-loop reach on that arm (IK or a LeRobot policy) at the
        # control rate until the EE is at (x,y,z) or a timeout/force trips:
        #   self.robot.send_action({f"{arm}_...": ...})
        # The arm grant already guaranteed (x,y,z) is inside the granted reach box.
        a = self.arms.get(arm)
        if a is None:
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        a["positions"] = [round(v, 3) for v in [x, y, z, 0.0, 0.0, a["positions"][5]]]
        return {"outcome": "reached", "detail": f"{arm} arm EE at ({x:.2f},{y:.2f},{z:.2f})"}

    def grasp_arm(self, arm, force):
        # Independent firmware floor — defense in depth behind the Lex grant clamp.
        if force > HARD_GRIP_N:
            return {"outcome": "stalled", "detail": f"grip {force:.0f}N exceeds firmware limit {HARD_GRIP_N:.0f}N"}
        a = self.arms.get(arm)
        if a is None:
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        # REAL: close the gripper with current-based force control; succeed only
        # on a grip signature (current plateau), not open-loop position.
        a["holding"] = True
        a["positions"][5] = 1.0
        return {"outcome": "reached", "detail": f"{arm} gripper closed at {force:.1f}N (firmware-capped)"}

    def release_arm(self, arm):
        a = self.arms.get(arm)
        if a is None:
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        # REAL: open the gripper.
        was = a["holding"]
        a["holding"] = False
        a["positions"][5] = 0.0
        return {"outcome": "reached", "detail": f"{arm} released (was_holding={was})"}

    def move_base(self, x, y, speed):
        # Independent firmware speed floor behind the Lex grant's velocity clamp.
        v = min(speed, HARD_SPEED_MPS)
        # REAL: drive to (x,y) — 0.4.0's dual-wheel differential base: turn
        # toward the target, then (v, omega) → left/right wheel speeds; stop on
        # arrival or obstacle. (The older omni base takes vx/vy directly.)
        #   self.robot.send_action({"base_v": ..., "base_omega": ...})
        # The base grant already guaranteed (x,y) is inside the permitted floor area.
        dx, dy = x - self.base["x"], y - self.base["y"]
        dist = math.hypot(dx, dy)
        self.base["x"], self.base["y"] = round(x, 3), round(y, 3)
        self.base["heading"] = round(math.atan2(dy, dx), 3) if dist > 1e-9 else self.base["heading"]
        return {
            "outcome": "reached",
            "detail": f"base at ({x:.2f},{y:.2f}) after {dist:.2f}m at {v:.2f}m/s (firmware-capped)",
        }


ROBOT = XLeRobot()


def handle_skill(name, args):
    if name == "reset":
        return ROBOT.reset()
    if name == "read_joints":
        return ROBOT.read_joints(args.get("arm", "left"))
    if name == "read_base":
        return ROBOT.read_base()
    if name == "read_camera":
        return ROBOT.read_camera(args.get("name", "head"))
    if name == "move_arm":
        return ROBOT.move_arm(args.get("arm", "left"), float(args.get("x", 0.2)),
                              float(args.get("y", 0.0)), float(args.get("z", 0.2)))
    if name == "grasp_arm":
        return ROBOT.grasp_arm(args.get("arm", "left"), float(args.get("force", 10.0)))
    if name == "release_arm":
        return ROBOT.release_arm(args.get("arm", "left"))
    if name == "move_base":
        return ROBOT.move_base(float(args.get("x", 0.0)), float(args.get("y", 0.0)),
                               float(args.get("speed", 0.3)))
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
            return self._send(200, handle_skill(self.path[len("/skill/"):], args))
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "hardware": USE_HW, "base": ROBOT.base})
        return self._send(404, {"error": "not found"})

    def log_message(self, *a):
        print("[xlerobot]", self.command, self.path)


def main():
    mode = "REAL HARDWARE" if USE_HW else "stub (no hardware)"
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot XLeRobot sidecar [{mode}] on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
