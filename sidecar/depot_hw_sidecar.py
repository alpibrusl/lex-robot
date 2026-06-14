#!/usr/bin/env python3
"""Hardware depot sidecar (LeRobot seam) for lex-robot.

This is the **transfer point**: the same depot protocol as the sim sidecars
(sim_sidecar / depot_mujoco / depot_g1), but the handler bodies are shaped for a
*real* arm driven by LeRobot. The Lex side — grant.lex (force/workspace clamps),
skills.lex, the Perceive→Plan→Execute→Verify task graph, charge.lex (real OCPP) —
runs **unchanged**; you only swap which sidecar is listening on :8900.

Out of the box this runs as a **stub** (no hardware, no LeRobot needed): set
LEX_ROBOT_HW=0 (default) and it returns plausible outcomes so you can exercise
the whole governance path offline. Set LEX_ROBOT_HW=1 with a LeRobot robot
configured to drive the real arm — fill in the `# REAL:` blocks below.

Two layers of safety, by design (DESIGN.md §8):
  1. The Lex **grant** already clamped force to the policy ceiling (e.g. 99N→15N)
     and vetted the workspace BEFORE the command reached this process.
  2. This sidecar independently enforces a **firmware force floor**
     (LEX_DEPOT_HARD_FORCE_N) and should sit behind a hardware e-stop. A software
     grant is the logical boundary, never physical safety.

Run:
    python3 sidecar/depot_hw_sidecar.py                 # stub (no hardware)
    LEX_ROBOT_HW=1 python3 sidecar/depot_hw_sidecar.py  # drive the real arm
"""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
HARD_FORCE_N = float(os.environ.get("LEX_DEPOT_HARD_FORCE_N", "40"))
USE_HW = os.environ.get("LEX_ROBOT_HW", "0") == "1"

# The inlet pose the arm should reach. On real hardware this comes from
# perception (a wrist camera + a learned/registered inlet detector); the stub
# uses a fixed pose so the demo's Perceive step has something to read.
INLET = {"x": 0.7, "y": 0.5, "z": 0.3, "rx": 0.0, "ry": 0.0, "rz": 0.0}


class Arm:
    """Thin wrapper around a real LeRobot robot, or a no-op stub."""

    def __init__(self):
        self.robot = None
        self.connected_plug = False
        if USE_HW:
            # REAL: bring up the LeRobot robot that owns the depot arm, e.g.
            #   from lerobot.common.robot_devices.robots.factory import make_robot
            #   self.robot = make_robot(os.environ["LEX_ROBOT_CFG"])
            #   self.robot.connect()
            raise SystemExit(
                "LEX_ROBOT_HW=1 but no LeRobot robot is wired up yet — fill in the "
                "`# REAL:` blocks in depot_hw_sidecar.py with your robot config."
            )

    def reset(self):
        # REAL: self.robot.home()  (move to a safe ready pose)
        self.connected_plug = False
        return {"inlet": INLET, "arm": {"x": 0.2, "y": 0.2, "z": 0.4}}

    def read_inlet(self):
        # REAL: detect the charge inlet pose from the wrist camera and return it.
        return INLET

    def move_to(self, x, y, z):
        # REAL: run the closed-loop reach (IK or a LeRobot policy) at the control
        # rate until the end-effector is at the target or a timeout/force trips:
        #   self.robot.send_action(plan_reach(Pose(x, y, z)))
        #   obs = self.robot.read_observation()
        # The grant already guaranteed (x,y,z) is inside the granted workspace.
        return {"outcome": "reached", "detail": f"arm reached ({x:.2f},{y:.2f},{z:.2f})"}

    def connect(self, force):
        # Independent firmware floor — defense in depth behind the Lex grant clamp.
        if force > HARD_FORCE_N:
            return {"outcome": "stalled", "detail": f"force {force}N exceeds firmware limit {HARD_FORCE_N}N"}
        # REAL: insertion with force/torque feedback; succeed only when the
        # connector is actually seated (a force signature / seated switch), e.g.
        #   seated = self.robot.insert_until_seated(max_force=force)
        #   if not seated: return {"outcome": "stalled", "detail": "not seated"}
        self.connected_plug = True
        return {"outcome": "reached", "detail": f"connector seated at {force:.1f}N (firmware-capped)"}

    def disconnect(self):
        # REAL: retract the connector along the insertion axis, then home.
        was = self.connected_plug
        self.connected_plug = False
        return {"outcome": "reached", "detail": f"connector retracted (was_connected={was})"}


ARM = Arm()

# OCPP-shaped charging stand-in so the demo's Verify works offline. In a real
# depot, point LEX_CHARGE_URL at the actual lex-charge/CSMS instead — charge.lex
# already talks to it directly (Bearer JWT), no change here.
_TX = {"id": None, "cp": None}


def start_session(cp_id, connector_id, id_tag):
    if not ARM.connected_plug:
        return 409, {"sent": False, "reason": "connector not seated"}
    _TX["id"] = (_TX["id"] or 4000) + 1
    _TX["cp"] = cp_id
    return 200, {"sent": True, "cp_id": cp_id, "transaction_id": _TX["id"]}


def active_sessions():
    if _TX["id"] is None:
        return []
    return [{"id": _TX["id"], "cp_id": _TX["cp"], "connector_id": 1, "stop_ts": None}]


def stop_session(cp_id, transaction_id):
    _TX["id"] = None
    return 200, {"sent": True, "cp_id": cp_id}


def handle_skill(name, args):
    if name == "reset_depot":
        return ARM.reset()
    if name == "read_inlet":
        return ARM.read_inlet()
    if name == "move_to":
        return ARM.move_to(float(args.get("x", 0.5)), float(args.get("y", 0.5)), float(args.get("z", 0.3)))
    if name == "connect_charger":
        return ARM.connect(float(args.get("force", 10.0)))
    if name == "disconnect_charger":
        return ARM.disconnect()
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
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "v1" and parts[1] == "chargers":
            cp_id, action = parts[2], parts[3]
            if action == "start":
                code, body = start_session(cp_id, int(args.get("connector_id", 1)), args.get("id_tag", "DEPOT-FLEET"))
                return self._send(code, body)
            if action == "stop":
                code, body = stop_session(cp_id, int(args.get("transaction_id", 0)))
                return self._send(code, body)
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "hardware": USE_HW, "connected": ARM.connected_plug})
        if self.path == "/v1/sessions/active":
            return self._send(200, active_sessions())
        return self._send(404, {"error": "not found"})

    def log_message(self, *a):
        print("[depot-hw]", self.command, self.path)


def main():
    mode = "REAL HARDWARE" if USE_HW else "stub (no hardware)"
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot hardware depot sidecar [{mode}] on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
