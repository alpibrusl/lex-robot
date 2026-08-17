#!/usr/bin/env python3
"""depot_sidecar — Tier-1 EV-depot simulation for lex-robot.

A (stationary) humanoid arm in a depot connects/disconnects an EV charging
connector to a truck's inlet. Connection is a *scripted snap* when the arm is
aligned within tolerance — no contact physics (Tier 1; see lex-robot#4).

It also exposes a small **OCPP-shaped charging API** (`/v1/chargers/:id/start|stop`)
that mirrors the real lex-charge service (ev-fleet/lex-charge), so the lex-robot
task's Verify gate can confirm a real charging *session* — and so this can later
point at the actual lex-charge/lex-csms by changing the charge URL. The session
can only start when the connector is *physically seated*: physical action gates
the protocol.

Dependency-free (Python stdlib). Run:
    python3 sidecar/depot_sidecar.py            # 127.0.0.1:8900
"""

import math
import os
import threading

from sidecar_lib import serve

ALIGN_TOL = float(os.environ.get("LEX_DEPOT_ALIGN_TOL", "0.08"))  # normalized distance
HARD_FORCE_N = float(os.environ.get("LEX_DEPOT_HARD_FORCE_N", "40"))  # firmware floor

_LOCK = threading.Lock()


class Depot:
    """One truck at a fixed charge inlet; one arm; a charging backend."""

    def __init__(self):
        self.inlet = {"x": 0.70, "y": 0.50, "z": 0.30, "rx": 0.0, "ry": 0.0, "rz": 0.0}
        self.home = {"x": 0.20, "y": 0.20, "z": 0.10}
        self.arm = dict(self.home)
        self.connected = False
        self.tx_counter = 1000
        self.active_tx = None  # transaction id while charging

    def reset(self):
        self.arm = dict(self.home)
        self.connected = False
        self.active_tx = None
        return {"inlet": self.inlet, "arm": self.arm}

    def dist_to_inlet(self):
        return math.sqrt(
            (self.arm["x"] - self.inlet["x"]) ** 2
            + (self.arm["y"] - self.inlet["y"]) ** 2
            + (self.arm["z"] - self.inlet["z"]) ** 2
        )

    def move_to(self, x, y, z):
        # Tier 1: teleport the arm to the commanded pose (no trajectory dynamics).
        self.arm = {"x": x, "y": y, "z": z}
        return {"outcome": "reached", "detail": f"arm at ({x:.2f},{y:.2f},{z:.2f}), dist_to_inlet={self.dist_to_inlet():.3f}"}

    def connect(self, force):
        if force > HARD_FORCE_N:  # firmware/e-stop floor, independent of the Lex grant
            return {"outcome": "stalled", "detail": f"force {force}N exceeds firmware limit {HARD_FORCE_N}N"}
        d = self.dist_to_inlet()
        if d > ALIGN_TOL:
            return {"outcome": "stalled", "detail": f"not aligned (dist={d:.3f} > tol={ALIGN_TOL})"}
        self.connected = True
        return {"outcome": "reached", "detail": f"connector seated at {force:.1f}N (dist={d:.3f})"}

    def disconnect(self):
        was = self.connected
        self.connected = False
        return {"outcome": "reached", "detail": f"connector released (was_connected={was}, active_tx={self.active_tx})"}

    # ── OCPP-shaped charging backend (mirrors the real ev-fleet/lex-charge) ──
    def start_session(self, cp_id, connector_id, id_tag):
        if not self.connected:
            return 409, {"sent": False, "reason": "connector not seated"}
        self.tx_counter += 1
        self.active_tx = self.tx_counter
        self.active_cp = cp_id
        return 200, {"sent": True, "cp_id": cp_id, "transaction_id": self.active_tx}

    def active_sessions(self):
        if self.active_tx is None:
            return []
        return [{"id": self.active_tx, "cp_id": getattr(self, "active_cp", "DEPOT-CP-01"), "connector_id": 1, "stop_ts": None}]

    def stop_session(self, cp_id, transaction_id):
        self.active_tx = None
        return 200, {"sent": True, "cp_id": cp_id}


DEPOT = Depot()


def handle_skill(name, args):
    if name == "reset_depot":
        return DEPOT.reset()
    if name == "read_inlet":
        return dict(DEPOT.inlet)
    if name == "move_to":
        return DEPOT.move_to(float(args.get("x", 0.5)), float(args.get("y", 0.5)), float(args.get("z", 0.2)))
    if name == "connect_charger":
        return DEPOT.connect(float(args.get("force", 10.0)))
    if name == "disconnect_charger":
        return DEPOT.disconnect()
    return {"error": f"unknown skill: {name}"}


def _health():
    return {"connected": DEPOT.connected, "active_tx": DEPOT.active_tx}


def _get_route(path):
    if path == "/v1/sessions/active":
        with _LOCK:
            return 200, DEPOT.active_sessions()
    return None


# OCPP-shaped charging API: /v1/chargers/<cp_id>/start|stop (consulted before
# /skill/; the serialize lock is held by the server around this dispatch).
def _post_route(path, args):
    parts = path.strip("/").split("/")
    if len(parts) == 4 and parts[0] == "v1" and parts[1] == "chargers":
        cp_id, action = parts[2], parts[3]
        if action == "start":
            return DEPOT.start_session(cp_id, int(args.get("connector_id", 1)), args.get("id_tag", "DEPOT-FLEET"))
        if action == "stop":
            return DEPOT.stop_session(cp_id, int(args.get("transaction_id", 0)))
    return None


def main():
    serve(handle_skill, tag="depot", banner="lex-robot depot sidecar",
          health=_health, get_route=_get_route, post_route=_post_route, lock=_LOCK)


if __name__ == "__main__":
    main()
