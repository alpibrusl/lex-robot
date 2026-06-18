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
import os
import random
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from trail import Trail

HOST = os.environ.get("LEX_ROBOT_SIDECAR_HOST", "127.0.0.1")
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))

# Content-addressed lex-trail episode log (mirrors gym_sidecar). Lets the
# simulated end-to-end gate reconcile this chain against the lex-os audit log.
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


def handle_skill(name: str, args: dict) -> dict:
    """Route a skill call to a simulated outcome.

    The Lex grant has already vetted the call (workspace/force/skill allowlist)
    before it reaches here, so the sidecar only sees authorized requests.
    """
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
        result = handle_skill(name, args)
        record_skill_trail(name, args, result)
        trail_path = os.environ.get("LEX_ROBOT_TRAIL", "/tmp/robot-trail.json")
        try:
            with open(trail_path, "w") as f:
                f.write(EPISODE.to_json())
        except OSError:
            pass
        self._send(200, result)

    def do_GET(self) -> None:
        if self.path == "/health":
            return self._send(200, {"ok": True})
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
