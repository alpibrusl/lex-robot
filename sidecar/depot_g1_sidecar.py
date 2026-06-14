#!/usr/bin/env python3
"""Tier-3 MuJoCo depot sidecar: a real Unitree G1 humanoid arm.

Same depot protocol as Tier-1/Tier-2, so examples/depot_demo.lex runs against it
unchanged. The difference from Tier-2 (depot_mujoco_sidecar.py) is fidelity:

  * Tier-2 teleoperated a *floating* connector capsule.
  * Tier-3 loads the real **Unitree G1** humanoid (MuJoCo Menagerie) and drives
    its right arm to do the connect. The connector is rigidly mounted on the G1
    hand; the arm is moved by a mocap weld (Cartesian teleop, no IK), with the
    pelvis pinned to the world (a stationary depot humanoid) and gravity off so
    no whole-body balancing is needed.
  * **Contact-rich insertion**: the connector geom and the truck face are
    collidable, so the plug physically touches the inlet during approach.
  * **Rigid weld on seat**: once the tip is aligned within tolerance, a stiff
    weld equality (plug -> truck) is locked in place — a real mechanical join,
    not just an alignment flag. disconnect() releases it.

The G1 lives in its natural frame (right hand at negative y), so the sidecar
maps the lex-robot grant's [0,1] workspace onto the real reachable box: read_inlet
reports normalized [0,1] coords and move_to maps them back to world. The grant
(ws [0,1], force ceiling) and depot_demo.lex are therefore unchanged.

Model: needs the Unitree G1 from MuJoCo Menagerie (not vendored — STL meshes are
heavy). Point LEX_G1_DIR at a checkout of mujoco_menagerie/unitree_g1, e.g.:

    git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/google-deepmind/mujoco_menagerie.git /tmp/menagerie
    git -C /tmp/menagerie sparse-checkout set unitree_g1
    export LEX_G1_DIR=/tmp/menagerie/unitree_g1

Deps: pip install mujoco numpy. Run:  python3 sidecar/depot_g1_sidecar.py

Also serves the OCPP-shaped charging stand-in (/v1/chargers/:id/start|stop,
/v1/sessions/active) so Verify works offline; point LEX_CHARGE_URL at the real
lex-charge to use the real stack.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

try:
    import mujoco
except ImportError:
    sys.exit("depot_g1_sidecar needs MuJoCo: pip install mujoco numpy")

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
ALIGN_TOL = float(os.environ.get("LEX_DEPOT_ALIGN_TOL", "0.06"))
HARD_FORCE_N = float(os.environ.get("LEX_DEPOT_HARD_FORCE_N", "40"))
G1_DIR = os.environ.get("LEX_G1_DIR", "/tmp/menagerie/unitree_g1")

# World-space reachable box for the G1 right arm. The lex grant's [0,1] workspace
# is mapped linearly onto this box, so the Lex side stays in [0,1] coords.
WS_LO = np.array([-0.10, -0.40, 0.60])
WS_HI = np.array([0.60, 0.10, 1.10])

HAND = "right_wrist_yaw_link"  # G1 right end-effector link the connector mounts on

_LOCK = threading.Lock()


def _g1_xml():
    p = os.path.join(G1_DIR, "g1_with_hands.xml")
    if not os.path.exists(p):
        sys.exit(
            f"Unitree G1 model not found at {p}.\n"
            f"Set LEX_G1_DIR to a mujoco_menagerie/unitree_g1 checkout "
            f"(see the module docstring for the sparse-checkout command)."
        )
    return p


def _build_spec():
    spec = mujoco.MjSpec.from_file(_g1_xml())
    spec.option.gravity = [0, 0, 0]      # stationary depot arm — no balancing
    spec.option.timestep = 0.004
    wb = spec.worldbody

    # Cartesian teleop target (mocap) — the weld below drags the hand to follow it.
    tgt = wb.add_body(name="ctrl_target", mocap=True, pos=[0.2, -0.15, 0.9])
    tgt.add_geom(type=mujoco.mjtGeom.mjGEOM_SPHERE, size=[0.018, 0, 0],
                 rgba=[0, 1, 1, 0.0], contype=0, conaffinity=0)  # invisible teleop marker

    # Floor — the G1's feet rest at ~z=0 in the home pose, so this grounds it.
    wb.add_geom(name="floor", type=mujoco.mjtGeom.mjGEOM_PLANE, size=[3, 3, 0.1],
                rgba=[0.26, 0.28, 0.30, 1], contype=0, conaffinity=0)

    # Truck silhouette (visual only) — a box truck parked side-on: cargo body +
    # lower cab + chassis rail + road wheels, so the charge port sits on the
    # cargo side at arm height and the whole thing reads as a vehicle.
    chassis = wb.add_body(name="chassis", pos=[0.52, -0.05, 0.0])
    chassis.add_geom(type=mujoco.mjtGeom.mjGEOM_BOX, pos=[0.0, 0.0, 0.60], size=[0.17, 0.34, 0.35],
                     rgba=[0.30, 0.40, 0.58, 1], contype=0, conaffinity=0)        # cargo box
    chassis.add_geom(type=mujoco.mjtGeom.mjGEOM_BOX, pos=[-0.01, 0.46, 0.40], size=[0.15, 0.12, 0.26],
                     rgba=[0.22, 0.30, 0.46, 1], contype=0, conaffinity=0)        # cab
    chassis.add_geom(type=mujoco.mjtGeom.mjGEOM_BOX, pos=[-0.10, 0.45, 0.50], size=[0.06, 0.10, 0.10],
                     rgba=[0.45, 0.6, 0.75, 1], contype=0, conaffinity=0)         # windshield
    chassis.add_geom(type=mujoco.mjtGeom.mjGEOM_BOX, pos=[0.0, 0.02, 0.26], size=[0.15, 0.46, 0.04],
                     rgba=[0.12, 0.12, 0.14, 1], contype=0, conaffinity=0)        # chassis rail
    for wy in (-0.24, 0.14, 0.46):
        chassis.add_geom(type=mujoco.mjtGeom.mjGEOM_CYLINDER, pos=[-0.19, wy, 0.12],
                         size=[0.12, 0.05, 0], euler=[0, 1.5708, 0],
                         rgba=[0.07, 0.07, 0.07, 1], contype=0, conaffinity=0)     # road wheels
        chassis.add_geom(type=mujoco.mjtGeom.mjGEOM_CYLINDER, pos=[-0.19, wy, 0.12],
                         size=[0.05, 0.052, 0], euler=[0, 1.5708, 0],
                         rgba=[0.45, 0.45, 0.47, 1], contype=0, conaffinity=0)     # hubs

    # Charge port assembly on the truck side facing the robot. The faceplate +
    # recessed dark bore read as a socket the connector inserts into; the inlet
    # site + small collidable pad are the validated seat geometry (unchanged), so
    # contact-rich insertion + the seat weld still work. "led" recolors on charge.
    truck = wb.add_body(name="truck", pos=[0.42, -0.15, 0.90])
    truck.add_geom(name="faceplate", type=mujoco.mjtGeom.mjGEOM_BOX, pos=[-0.075, 0, 0],
                   size=[0.012, 0.06, 0.06], rgba=[0.12, 0.12, 0.14, 1], contype=0, conaffinity=0)
    truck.add_geom(name="bore", type=mujoco.mjtGeom.mjGEOM_CYLINDER, pos=[-0.02, 0, 0],
                   size=[0.026, 0.055, 0], euler=[0, 1.5708, 0], rgba=[0.02, 0.02, 0.02, 1],
                   contype=0, conaffinity=0)
    truck.add_geom(name="led", type=mujoco.mjtGeom.mjGEOM_SPHERE, pos=[-0.085, 0, 0.058],
                   size=[0.02, 0, 0], rgba=[0.85, 0.12, 0.12, 1], contype=0, conaffinity=0)
    truck.add_geom(name="pad", type=mujoco.mjtGeom.mjGEOM_BOX, pos=[-0.06, 0, 0],
                   size=[0.008, 0.03, 0.03], rgba=[0.1, 0.1, 0.12, 1], contype=1, conaffinity=1)
    truck.add_site(name="inlet", pos=[-0.085, 0, 0], size=[0.02, 0, 0], rgba=[1, 0.8, 0, 1])

    # Connector rigidly mounted on the G1 hand (a real part of the arm).
    hand = spec.body(HAND)
    plug = hand.add_body(name="plug", pos=[0.06, -0.02, 0.0])
    plug.add_geom(name="plug_g", type=mujoco.mjtGeom.mjGEOM_CAPSULE, size=[0.016, 0.035, 0],
                  rgba=[0.3, 0.9, 0.6, 1], contype=1, conaffinity=1)
    plug.add_site(name="tip", pos=[0.055, 0, 0], size=[0.012, 0, 0], rgba=[0, 1, 0, 1])

    # Equalities: teleop (mocap->hand), base pin (pelvis->world), seat (plug->truck, off).
    spec.add_equality(type=mujoco.mjtEq.mjEQ_WELD, name="teleop",
                      objtype=mujoco.mjtObj.mjOBJ_BODY, name1=HAND, name2="ctrl_target")
    spec.add_equality(type=mujoco.mjtEq.mjEQ_WELD, name="basepin",
                      objtype=mujoco.mjtObj.mjOBJ_BODY, name1="pelvis")
    spec.add_equality(type=mujoco.mjtEq.mjEQ_WELD, name="seat",
                      objtype=mujoco.mjtObj.mjOBJ_BODY, name1="plug", name2="truck", active=False)
    return spec


def _lock_weld_in_place(m, d, eqid):
    """Set a weld's relpose to the current relative pose so it locks where things
    are now (no snap), then it holds rigidly."""
    b1, b2 = m.eq_obj1id[eqid], m.eq_obj2id[eqid]
    q1inv = np.zeros(4)
    mujoco.mju_negQuat(q1inv, d.xquat[b1])
    rp = np.zeros(3)
    mujoco.mju_rotVecQuat(rp, d.xpos[b2] - d.xpos[b1], q1inv)
    rq = np.zeros(4)
    mujoco.mju_mulQuat(rq, q1inv, d.xquat[b2])
    m.eq_data[eqid][0:3] = 0.0
    m.eq_data[eqid][3:6] = rp
    m.eq_data[eqid][6:10] = rq
    m.eq_data[eqid][10] = 1.0


class DepotG1:
    def __init__(self):
        self.m = _build_spec().compile()
        self.d = mujoco.MjData(self.m)
        # Free ONLY the right-arm actuators so the teleop weld can move that arm;
        # keep legs/torso/left-arm stiff (held at the home pose in reset) so the
        # humanoid stays standing. Damp the freed dofs for smooth tracking.
        arm = ("right_shoulder", "right_elbow", "right_wrist")
        self.arm_acts = [i for i in range(self.m.nu)
                         if self.m.actuator(i).name.startswith(arm)]
        for i in self.arm_acts:
            self.m.actuator_gainprm[i, :] = 0
            self.m.actuator_biasprm[i, :] = 0
            jid = self.m.actuator_trnid[i, 0]
            self.m.dof_damping[self.m.jnt_dofadr[jid]] = 5.0
        self.mocap = self.m.body("ctrl_target").mocapid[0]
        self.s_tip = self.m.site("tip").id
        self.s_inlet = self.m.site("inlet").id
        self.eq_seat = self.m.equality("seat").id
        self.connected = False
        self.tx = None
        self.active_cp = None
        self.reset()

    # ---- coordinate frame: grant [0,1] <-> world reachable box ----
    def n2w(self, n):
        return WS_LO + np.clip(np.asarray(n, float), 0, 1) * (WS_HI - WS_LO)

    def w2n(self, w):
        return (np.asarray(w, float) - WS_LO) / (WS_HI - WS_LO)

    def reset(self):
        mujoco.mj_resetData(self.m, self.d)
        if self.m.nkey > 0:
            mujoco.mj_resetDataKeyframe(self.m, self.d, 0)  # home arm pose
        self.d.eq_active[self.eq_seat] = 0
        self.m.geom("plug_g").contype = 1
        self.m.geom("plug_g").conaffinity = 1
        # Hold every position actuator at its home-pose joint angle so the stiff
        # (non-arm) joints keep the humanoid standing instead of driving to zero.
        for i in range(self.m.nu):
            jid = self.m.actuator_trnid[i, 0]
            self.d.ctrl[i] = self.d.qpos[self.m.jnt_qposadr[jid]]
        mujoco.mj_forward(self.m, self.d)
        self.d.mocap_pos[self.mocap] = self.d.body(HAND).xpos.copy()
        self.connected = False
        self.tx = None
        return {"inlet": self._inlet(), "arm": self._tip()}

    def _tip(self):
        p = self.d.site_xpos[self.s_tip]
        n = self.w2n(p)
        return {"x": float(n[0]), "y": float(n[1]), "z": float(n[2])}

    def _inlet(self):
        p = self.d.site_xpos[self.s_inlet]
        n = self.w2n(p)
        return {"x": float(n[0]), "y": float(n[1]), "z": float(n[2]),
                "rx": 0.0, "ry": 0.0, "rz": 0.0}

    def dist(self):
        return float(np.linalg.norm(self.d.site_xpos[self.s_tip] - self.d.site_xpos[self.s_inlet]))

    def move_to(self, nx, ny, nz):
        # Servo the mocap target on tip-to-goal error; the teleop weld drags the
        # G1 hand (and the mounted connector) to follow. Real mj_step physics.
        goal = self.n2w([nx, ny, nz])
        for k in range(900):
            err = goal - self.d.site_xpos[self.s_tip]
            # Clamp the mocap target to the reachable box so it can't integrate
            # away and drive the arm into its joint limits if motion is blocked.
            self.d.mocap_pos[self.mocap] = np.clip(
                self.d.mocap_pos[self.mocap] + 0.35 * err, WS_LO - 0.05, WS_HI + 0.05)
            mujoco.mj_step(self.m, self.d)
            if float(np.linalg.norm(err)) < 0.05 and k > 60:
                break
        t = self._tip()
        return {"outcome": "reached",
                "detail": f"G1 hand at ({t['x']:.2f},{t['y']:.2f},{t['z']:.2f}), tip-inlet dist={self.dist():.3f}"}

    def connect(self, force):
        if force > HARD_FORCE_N:
            return {"outcome": "stalled", "detail": f"force {force}N exceeds firmware limit"}
        d = self.dist()
        if d > ALIGN_TOL:
            return {"outcome": "stalled", "detail": f"not aligned (dist={d:.3f} > tol={ALIGN_TOL})"}
        # Rigid weld on seat: lock the plug->truck weld at the current pose, then
        # drop the now-redundant plug/truck contact so weld and contact don't fight.
        _lock_weld_in_place(self.m, self.d, self.eq_seat)
        self.d.eq_active[self.eq_seat] = 1
        self.m.geom("plug_g").contype = 0
        self.m.geom("plug_g").conaffinity = 0
        for _ in range(120):
            mujoco.mj_step(self.m, self.d)
        self.connected = True
        return {"outcome": "reached",
                "detail": f"connector welded into inlet on G1 hand at {force:.1f}N (dist={d:.3f})"}

    def disconnect(self):
        was = self.connected
        self.d.eq_active[self.eq_seat] = 0
        self.m.geom("plug_g").contype = 1
        self.m.geom("plug_g").conaffinity = 1
        for _ in range(60):
            mujoco.mj_step(self.m, self.d)
        self.connected = False
        return {"outcome": "reached", "detail": f"weld released (was_connected={was})"}

    # ---- OCPP-shaped charging stand-in (mirrors real lex-charge) ----
    def start_session(self, cp_id, connector_id, id_tag):
        if not self.connected:
            return 409, {"sent": False, "reason": "connector not seated"}
        self.tx = (self.tx or 3000) + 1
        self.active_cp = cp_id
        return 200, {"sent": True, "cp_id": cp_id, "transaction_id": self.tx}

    def active_sessions(self):
        if self.tx is None:
            return []
        return [{"id": self.tx, "cp_id": self.active_cp, "connector_id": 1, "stop_ts": None}]

    def stop_session(self, cp_id, transaction_id):
        self.tx = None
        return 200, {"sent": True, "cp_id": cp_id}


DEPOT = DepotG1()


def handle_skill(name, args):
    if name == "reset_depot":
        return DEPOT.reset()
    if name == "read_inlet":
        return DEPOT._inlet()
    if name == "move_to":
        return DEPOT.move_to(float(args.get("x", 0.5)), float(args.get("y", 0.5)), float(args.get("z", 0.5)))
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
        print("[depot-g1]", self.command, self.path)


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot Unitree G1 depot sidecar on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
