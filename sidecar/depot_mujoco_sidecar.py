#!/usr/bin/env python3
"""Tier-2 MuJoCo depot sidecar for lex-robot.

A real MuJoCo physics scene (truck + charge inlet + a mocap-teleoperated
connector) behind the SAME depot protocol as the Tier-1 stand-in, so
examples/depot_demo.lex runs against it unchanged. Connection is detected by
site alignment (tip within tolerance of the inlet) — a rigid weld is the next
refinement; a full Unitree G1 humanoid (MuJoCo Menagerie) is Tier-2's stretch
goal (lex-robot#4).

Also serves the OCPP-shaped charging stand-in (/v1/chargers/:id/start|stop,
/v1/sessions/active) so the demo's Verify works offline; point charge_url at the
real lex-charge to use the real stack.

Deps: pip install mujoco. Run:  python3 sidecar/depot_mujoco_sidecar.py
"""

import json
import math
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mujoco
import numpy as np

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
ALIGN_TOL = float(os.environ.get("LEX_DEPOT_ALIGN_TOL", "0.06"))
HARD_FORCE_N = float(os.environ.get("LEX_DEPOT_HARD_FORCE_N", "40"))

# Coords kept in [0,1] so the lex-robot grant's workspace check passes.
XML = """
<mujoco>
  <option gravity="0 0 0" timestep="0.01"/>
  <worldbody>
    <geom type="plane" size="2 2 0.1" rgba="0.2 0.22 0.2 1"/>
    <body name="truck" pos="0.78 0.5 0.3">
      <geom type="box" size="0.08 0.12 0.12" rgba="0.3 0.4 0.6 1"/>
      <site name="inlet" pos="-0.08 0 0" size="0.02" rgba="1 0.8 0 1"/>
    </body>
    <body name="plug" pos="0.2 0.2 0.1" mocap="true">
      <geom type="capsule" size="0.02 0.05" rgba="0.3 0.9 0.6 1"/>
      <site name="tip" pos="0 0 0" size="0.015" rgba="0 1 0 1"/>
    </body>
  </worldbody>
</mujoco>
"""

_LOCK = threading.Lock()


class Depot:
    def __init__(self):
        self.m = mujoco.MjModel.from_xml_string(XML)
        self.d = mujoco.MjData(self.m)
        self.mocap = self.m.body("plug").mocapid[0]
        self.s_tip = self.m.site("tip").id
        self.s_inlet = self.m.site("inlet").id
        self.home = np.array([0.2, 0.2, 0.1])
        self.connected = False
        self.tx = None
        self.active_cp = None
        self.reset()

    def reset(self):
        mujoco.mj_resetData(self.m, self.d)
        self.d.mocap_pos[self.mocap] = self.home
        mujoco.mj_forward(self.m, self.d)
        self.connected = False
        self.tx = None
        return {"inlet": self._inlet(), "arm": self._tip()}

    def _tip(self):
        p = self.d.site_xpos[self.s_tip]
        return {"x": float(p[0]), "y": float(p[1]), "z": float(p[2])}

    def _inlet(self):
        p = self.d.site_xpos[self.s_inlet]
        return {"x": float(p[0]), "y": float(p[1]), "z": float(p[2]), "rx": 0.0, "ry": 0.0, "rz": 0.0}

    def dist(self):
        return float(np.linalg.norm(self.d.site_xpos[self.s_tip] - self.d.site_xpos[self.s_inlet]))

    def move_to(self, x, y, z):
        # Teleop the connector toward the target; real physics steps interpolate.
        target = np.array([x, y, z])
        for _ in range(40):
            cur = self.d.mocap_pos[self.mocap]
            self.d.mocap_pos[self.mocap] = cur + 0.1 * (target - cur)
            mujoco.mj_step(self.m, self.d)
        return {"outcome": "reached", "detail": f"tip at ({self._tip()['x']:.2f},{self._tip()['y']:.2f},{self._tip()['z']:.2f}), dist={self.dist():.3f}"}

    def connect(self, force):
        if force > HARD_FORCE_N:
            return {"outcome": "stalled", "detail": f"force {force}N exceeds firmware limit"}
        d = self.dist()
        if d > ALIGN_TOL:
            return {"outcome": "stalled", "detail": f"not aligned (dist={d:.3f} > tol={ALIGN_TOL})"}
        self.connected = True
        return {"outcome": "reached", "detail": f"connector seated in MuJoCo at {force:.1f}N (dist={d:.3f})"}

    def disconnect(self):
        was = self.connected
        self.connected = False
        return {"outcome": "reached", "detail": f"released (was_connected={was})"}

    # OCPP-shaped charging stand-in (mirrors real lex-charge)
    def start_session(self, cp_id, connector_id, id_tag):
        if not self.connected:
            return 409, {"sent": False, "reason": "connector not seated"}
        self.tx = (self.tx or 2000) + 1
        self.active_cp = cp_id
        return 200, {"sent": True, "cp_id": cp_id, "transaction_id": self.tx}

    def active_sessions(self):
        if self.tx is None:
            return []
        return [{"id": self.tx, "cp_id": self.active_cp, "connector_id": 1, "stop_ts": None}]

    def stop_session(self, cp_id, transaction_id):
        self.tx = None
        return 200, {"sent": True, "cp_id": cp_id}


DEPOT = Depot()


def handle_skill(name, args):
    if name == "reset_depot":
        return DEPOT.reset()
    if name == "read_inlet":
        return DEPOT._inlet()
    if name == "move_to":
        return DEPOT.move_to(float(args.get("x", 0.5)), float(args.get("y", 0.5)), float(args.get("z", 0.2)))
    if name == "connect_charger":
        return DEPOT.connect(float(args.get("force", 10.0)))
    if name == "disconnect_charger":
        return DEPOT.disconnect()
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
        with _LOCK:
            if self.path.startswith("/skill/"):
                return self._send(200, handle_skill(self.path[len("/skill/"):], args))
            parts = self.path.strip("/").split("/")
            if len(parts) == 4 and parts[0] == "v1" and parts[1] == "chargers":
                cp_id, action = parts[2], parts[3]
                if action == "start":
                    code, body = DEPOT.start_session(cp_id, int(args.get("connector_id", 1)), args.get("id_tag", "DEPOT-FLEET"))
                    return self._send(code, body)
                if action == "stop":
                    code, body = DEPOT.stop_session(cp_id, int(args.get("transaction_id", 0)))
                    return self._send(code, body)
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "connected": DEPOT.connected})
        if self.path == "/v1/sessions/active":
            with _LOCK:
                return self._send(200, DEPOT.active_sessions())
        return self._send(404, {"error": "not found"})

    def log_message(self, *a):
        print("[depot-mujoco]", self.command, self.path)


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot MuJoCo depot sidecar on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
