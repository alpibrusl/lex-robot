#!/usr/bin/env python3
"""leLab's HTTP surface, served over the lex skill API.

`huggingface/leLab` is LeRobot's web UI: calibrate, teleoperate, record, train,
infer, upload, all in one browser app. Its backend drives LeRobot's `Robot`
classes directly. Run it beside lex-robot on the same arms and you have two
independent authority paths to the same servos, one of which the grant does not
cover — which is precisely the thing lex-os exists to prevent.

This adapter is the other arrangement: leLab's frontend, pointed at a port that
speaks leLab's routes but executes **nothing itself**. Every request that would
touch the robot becomes a `POST /skill/*` on `xlerobot_sidecar.py`, so it
inherits, unchanged:

  * the grant gate      — an out-of-box target comes back `denied`, grip force
                          is clamped to `grippers.*.max_grip_force_n`
  * the firmware floors — `LEX_XLE_HARD_GRIP_N`, `LEX_XLE_HARD_SPEED_MPS`
  * the per-bus locks   — no interleaved serial traffic
  * the governance ledger — every call shows up at `GET /governance`

The interesting half is what is **refused**. leLab's surface is much wider than
the skill API, and the honest response to a route the skill API cannot express
is a 501 naming the reason, not a plausible-looking implementation that quietly
reaches around the grant. Two kinds of refusal, both in `REFUSED` below:

  1. *Not expressible* — leader→follower teleoperation is a continuous command
     stream between two arms; the sidecar exposes no leader, and per-command
     grant checks are not what that loop does. Calibration likewise: there is
     no calibration skill, and adding an ungoverned serial path here to fake
     one is exactly the mistake.
  2. *Not this layer* — training, Hub upload, HF auth, dependency installs.
     lex-robot sits above LeRobot and does not reimplement it. Run leLab
     proper for those; they never touch the arm, so nothing is lost.

Usage:

    python3 sidecar/xlerobot_sidecar.py &          # the governed robot
    python3 sidecar/lelab_adapter.py               # leLab's routes, on :8000
    # then point leLab's frontend at http://127.0.0.1:8000

    curl -s localhost:8000/lex/routes | python3 -m json.tool   # what is/isn't served

Environment:
    LEX_LELAB_PORT          port to serve on (default 8000, leLab's own)
    LEX_LELAB_ORIGIN        CORS origin allowed (default http://localhost:8080,
                            leLab's Vite dev server). Deliberately NOT `*`:
                            this port can move an arm, and a wildcard would let
                            any page the operator happens to open drive it.
    LEX_ROBOT_SIDECAR_PORT  the xlerobot sidecar to translate onto (default 8900)
    LEX_LELAB_CAMERA_HZ     MJPEG frame rate for /camera-feed (default 10)
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_LELAB_PORT", "8000"))
ORIGIN = os.environ.get("LEX_LELAB_ORIGIN", "http://localhost:8080")
SIDECAR = f"http://127.0.0.1:{os.environ.get('LEX_ROBOT_SIDECAR_PORT', '8900')}"
CAMERA_HZ = float(os.environ.get("LEX_LELAB_CAMERA_HZ", "10"))

# SO-101 motor names as lex-robot reads them, in the order read_joints returns,
# against the URDF names leLab's frontend renders. Same six joints, two
# vocabularies; the adapter translates rather than making the UI learn ours.
JOINT_NAMES = {
    "shoulder_pan": "Rotation",
    "shoulder_lift": "Pitch",
    "elbow_flex": "Elbow",
    "wrist_flex": "Wrist_Pitch",
    "wrist_roll": "Wrist_Roll",
    "gripper": "Jaw",
}

CAMERAS = ("head", "left", "right")

# Routes served, and what each one becomes. Kept as data so `GET /lex/routes`
# can answer the only question that matters when you point a UI at this thing:
# which of its buttons actually work, and which will refuse.
IMPLEMENTED = {
    ("GET", "/health"): "sidecar /health + the loaded grant",
    ("GET", "/joint-positions"): "read_joints on both arms",
    ("GET", "/teleoperation-status"): "adapter session state (no robot call)",
    ("POST", "/move-arm"): "move_arm — absolute Cartesian target, grant-gated",
    ("POST", "/stop-teleoperation"): "ends the adapter's jog session (no robot call)",
    ("GET", "/available-cameras"): "read_camera probe on head/left/right",
    ("GET", "/camera-feed/{cam}"): "read_camera at LEX_LELAB_CAMERA_HZ, as MJPEG",
    ("POST", "/start-recording"): "teach_start",
    ("POST", "/stop-recording"): "teach_stop",
    ("POST", "/recording-exit-early"): "teach_stop",
    ("GET", "/recording-status"): "teach_status",
    ("GET", "/datasets"): "teach_list",
    ("GET", "/lex/routes"): "this table",
    ("GET", "/lex/governance"): "redirect to the sidecar's governance view",
}

_NOT_EXPRESSIBLE = (
    "not expressible through the lex skill API: {why}. Implementing it here "
    "would mean a second path to the servos that the grant does not cover, "
    "which is the one thing this layer exists to prevent."
)
_NOT_THIS_LAYER = (
    "not lex-robot's layer: {why}. It never touches the arm, so there is "
    "nothing to govern — run leLab against LeRobot directly for it."
)

REFUSED = {
    "/start-calibration": _NOT_EXPRESSIBLE.format(
        why="the sidecar has no calibration skill, and calibration drives the "
            "servos through their full range"),
    "/stop-calibration": _NOT_EXPRESSIBLE.format(why="see /start-calibration"),
    "/calibration-status": _NOT_EXPRESSIBLE.format(why="see /start-calibration"),
    "/complete-calibration-step": _NOT_EXPRESSIBLE.format(why="see /start-calibration"),
    "/calibration-configs": _NOT_EXPRESSIBLE.format(why="see /start-calibration"),
    "/start-inference": _NOT_EXPRESSIBLE.format(
        why="this sidecar exposes no policy-execution skill (gym_sidecar.py's "
            "run_policy is the governed shape, and it is a different sidecar)"),
    "/stop-inference": _NOT_EXPRESSIBLE.format(why="see /start-inference"),
    "/inference-status": _NOT_EXPRESSIBLE.format(why="see /start-inference"),
    "/available-ports": _NOT_EXPRESSIBLE.format(
        why="port discovery is serial-bus enumeration, below the skill API"),
    "/start-port-detection": _NOT_EXPRESSIBLE.format(why="see /available-ports"),
    "/detect-port-after-disconnect": _NOT_EXPRESSIBLE.format(why="see /available-ports"),
    "/save-robot-port": _NOT_EXPRESSIBLE.format(why="see /available-ports"),
    "/robot-port": _NOT_EXPRESSIBLE.format(why="see /available-ports"),
    "/jobs": _NOT_THIS_LAYER.format(why="training is LeRobot's job"),
    "/upload-dataset": _NOT_THIS_LAYER.format(why="Hub upload is LeRobot's job"),
    "/dataset-info": _NOT_THIS_LAYER.format(why="dataset inspection is LeRobot's job"),
    "/delete-dataset": _NOT_THIS_LAYER.format(why="dataset management is LeRobot's job"),
    "/dataset-repair": _NOT_THIS_LAYER.format(why="dataset management is LeRobot's job"),
    "/hf-auth-status": _NOT_THIS_LAYER.format(why="Hub credentials are LeRobot's job"),
    "/hf-auth": _NOT_THIS_LAYER.format(why="Hub credentials are LeRobot's job"),
    "/system": _NOT_THIS_LAYER.format(why="dependency installs are LeRobot's job"),
    "/get-configs": _NOT_THIS_LAYER.format(why="robot config files are LeRobot's job"),
    "/robots": _NOT_THIS_LAYER.format(why="robot config files are LeRobot's job"),
    "/save-robot-config": _NOT_THIS_LAYER.format(why="robot config files are LeRobot's job"),
    "/robot-config": _NOT_THIS_LAYER.format(why="robot config files are LeRobot's job"),
    "/ws": _NOT_EXPRESSIBLE.format(
        why="leLab streams joint data over a WebSocket; the sidecar's own "
            "/stream is the governed equivalent and speaks a different shape"),
    "/ws-test": _NOT_EXPRESSIBLE.format(why="see /ws"),
    "/recording-rerecord-episode": _NOT_EXPRESSIBLE.format(
        why="teach records one demonstration at a time, with no episode index "
            "to re-take (teach_delete then teach_start is the equivalent)"),
}


class SidecarDown(RuntimeError):
    """The sidecar is unreachable. Never downgraded into a local fallback: an
    adapter that answered from its own state while the robot was gone would be
    reporting a robot that isn't there."""


# ---------------------------------------------------------------------------
# The translation. Pure functions — no I/O, no globals — so the mapping is
# testable without a robot, a sidecar, or a socket.
# ---------------------------------------------------------------------------

def joint_positions_payload(per_arm: dict, now: float) -> dict:
    """leLab's `{success, joint_positions, timestamp}` from read_joints replies.

    leLab renders URDF joint names; lex-robot reports `{arm}_{motor}` in
    degrees. Both arms are returned, prefixed, because leLab's single-arm shape
    has nowhere to put a second one and dropping it silently would hide half
    the robot.
    """
    joints, errors = {}, {}
    for arm, reply in sorted(per_arm.items()):
        if not isinstance(reply, dict) or "positions" not in reply:
            errors[arm] = (reply or {}).get("error", "no positions in reply") \
                if isinstance(reply, dict) else "unreadable reply"
            continue
        names = reply.get("names") or []
        for i, pos in enumerate(reply["positions"]):
            motor = names[i] if i < len(names) else f"joint_{i}"
            motor = motor[len(arm) + 1:] if motor.startswith(f"{arm}_") else motor
            joints[f"{arm}_{JOINT_NAMES.get(motor, motor)}"] = float(pos)
    return {"success": not errors, "joint_positions": joints, "timestamp": now,
            **({"errors": errors} if errors else {})}


def move_arm_request(body: dict):
    """leLab's POST /move-arm → a `move_arm` skill call, or a refusal.

    leLab's own TeleoperateRequest is `{leader_port, follower_port,
    leader_config, follower_config}` — "mirror this leader arm onto that
    follower until told to stop". That is a continuous stream with no target in
    it, and there is no leader on this side to read, so it is refused rather
    than approximated. A body carrying an absolute Cartesian target — what a
    jog UI sends — is a `move_arm`, and goes through the grant like any other.
    """
    if not isinstance(body, dict):
        return None, "expected a JSON object"
    if "leader_port" in body or "follower_port" in body:
        return None, _NOT_EXPRESSIBLE.format(
            why="leader→follower teleoperation is a continuous mirroring loop "
                "between two arms, and this sidecar exposes no leader arm to "
                "read; the grant gates discrete commands, which is not that")
    missing = [k for k in ("x", "y", "z") if k not in body]
    if missing:
        return None, f"absolute Cartesian target required; missing {', '.join(missing)}"
    arm = body.get("arm", "left")
    if arm not in ("left", "right"):
        return None, f"unknown arm {arm!r} (use left|right)"
    try:
        args = {"arm": arm, "x": float(body["x"]), "y": float(body["y"]), "z": float(body["z"])}
    except (TypeError, ValueError):
        return None, "x, y and z must be numbers (metres, arm frame)"
    return args, None


def start_recording_request(body: dict):
    """leLab's RecordingRequest → `teach_start` args, or a refusal.

    The fields that survive are the ones a taught demonstration actually has:
    task, fps, episode length, cameras. `num_episodes` does not — teach records
    one demonstration per start/stop, so a request for several is refused
    instead of silently recording one and reporting success.
    """
    if not isinstance(body, dict):
        return None, "expected a JSON object"
    episodes = int(body.get("num_episodes", 1) or 1)
    if episodes > 1:
        return None, (f"teach records ONE demonstration per start/stop; "
                      f"num_episodes={episodes} would silently record one. Drive "
                      f"the loop from the UI, calling /start-recording per episode.")
    if body.get("push_to_hub"):
        return None, _NOT_THIS_LAYER.format(why="Hub upload is LeRobot's job")
    name = body.get("dataset_repo_id") or body.get("single_task") or "lelab"
    cameras = body.get("cameras")
    args = {
        "arm": body.get("arm", "left"),
        "name": str(name).replace("/", "_"),
        "task": body.get("single_task", ""),
        "tags": list(body.get("tags") or []),
        "fps": float(body.get("fps", 20) or 20),
        "seconds": float(body.get("episode_time_s", 120) or 120),
    }
    if isinstance(cameras, dict) and cameras:
        args["cameras"] = sorted(cameras)
    elif isinstance(cameras, list) and cameras:
        args["cameras"] = list(cameras)
    return args, None


def recording_status_payload(status: dict, dataset_repo_id: str = "") -> dict:
    """teach_status → leLab's recording-status shape."""
    status = status if isinstance(status, dict) else {}
    active = bool(status.get("recording"))
    error = status.get("error")
    phase = "error" if error else ("recording" if active else "completed")
    out = {
        "recording_active": active,
        "current_phase": phase,
        "session_ended": not active,
        "available_controls": {"stop_recording": active, "exit_early": active,
                               "rerecord_episode": False},
        "message": (f"teaching {status.get('arm')} arm, {status.get('frames', 0)} frames"
                    if active else "idle"),
        "dataset_repo_id": dataset_repo_id or status.get("name", ""),
        "session_elapsed_seconds": int(status.get("elapsed_s") or 0),
    }
    if active:
        out.update({"current_episode": 1, "total_episodes": 1,
                    "cameras": status.get("cameras") or []})
    if error:
        out["error"] = error
    return out


def datasets_payload(listing: dict) -> dict:
    """teach_list → leLab's /datasets shape, tagged with where they came from."""
    recordings = (listing or {}).get("recordings") or []
    return {"datasets": [
        {"repo_id": r.get("name", ""), "source": "lex-robot/teach",
         "task": r.get("task", ""), "episodes": 1, "frames": r.get("frames"),
         "arm": r.get("arm"), "created_at": r.get("created_at"),
         "duration_s": r.get("duration_s"),
         **({"error": r["error"]} if r.get("error") else {})}
        for r in recordings]}


def cameras_payload(probes: dict) -> dict:
    """read_camera probes → leLab's /available-cameras shape.

    A camera that answers with an empty frame is NOT listed as available. The
    Tier-1 stub answers every `read_camera` with a 640x480 placeholder and no
    JPEG, and a UI told three cameras exist would show three dead panes; the
    honest answer is that none is live, and which ones only exist at Tier 3.
    """
    live, dark = [], []
    for name, frame in probes.items():
        if not isinstance(frame, dict) or "error" in frame:
            dark.append({"name": name,
                         "detail": (frame or {}).get("error", "unreadable reply")
                         if isinstance(frame, dict) else "unreadable reply"})
        elif not frame.get("jpeg_b64"):
            dark.append({"name": name, "detail": "no frame — not configured at this tier"})
        else:
            live.append({"name": name, "width": frame.get("width"),
                         "height": frame.get("height"), "feed": f"/camera-feed/{name}"})
    return {"status": "success", "cameras": live,
            **({"unavailable": dark} if dark else {})}


def refusal_for(path: str):
    """The refusal covering this path, or None if the adapter serves it.

    Matched on the first path segment as well as the whole path, so the whole
    of `/jobs/17/logs` is covered by the one `/jobs` entry.
    """
    if path in REFUSED:
        return REFUSED[path]
    head = "/" + path.lstrip("/").split("/", 1)[0]
    return REFUSED.get(head)


def routes_payload() -> dict:
    return {
        "sidecar": SIDECAR,
        "implemented": [{"method": m, "path": p, "becomes": v}
                        for (m, p), v in sorted(IMPLEMENTED.items(), key=lambda kv: kv[0][1])],
        "refused": [{"path": p, "reason": r} for p, r in sorted(REFUSED.items())],
        "note": "Refused routes are refused on purpose: see this module's docstring.",
    }


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------

def skill(name: str, args: dict, timeout: float = 30.0) -> dict:
    """One POST /skill/<name> on the sidecar. The only way this file touches
    the robot — there is deliberately no second path."""
    req = urllib.request.Request(f"{SIDECAR}/skill/{name}",
                                 data=json.dumps(args).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise SidecarDown(f"{SIDECAR} unreachable: {e}") from e


def sidecar_health(timeout: float = 5.0) -> dict:
    try:
        with urllib.request.urlopen(f"{SIDECAR}/health", timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise SidecarDown(f"{SIDECAR} unreachable: {e}") from e


class Session:
    """What the adapter itself remembers: whether the operator has opened a jog
    session, and which dataset name the current recording is under. Not
    authority — the sidecar re-checks every command regardless of this."""

    def __init__(self) -> None:
        self.jogging = False
        self.dataset_repo_id = ""


SESSION = Session()


class Handler(BaseHTTPRequestHandler):
    server_version = "lex-robot-lelab-adapter"

    # -- plumbing ----------------------------------------------------------
    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", ORIGIN)
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return None

    def _refuse(self, path: str, reason: str) -> None:
        self._send(501, {"success": False, "error": "refused by lex-robot",
                         "path": path, "detail": reason,
                         "see": f"{SIDECAR}/governance"})

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_DELETE(self):
        path = self.path.split("?", 1)[0]
        reason = refusal_for(path)
        return self._refuse(path, reason or "this adapter serves no DELETE routes")

    # -- routes ------------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        try:
            if path == "/lex/routes":
                return self._send(200, routes_payload())
            if path == "/lex/governance":
                self.send_response(302)
                self.send_header("Location", f"{SIDECAR}/governance")
                self._cors()
                return self.end_headers()
            if path == "/health":
                health = sidecar_health()
                return self._send(200, {"status": "healthy", "message": "governed by lex-robot",
                                        "sidecar": health, "grant": skill("read_grant", {})})
            if path == "/joint-positions":
                per_arm = {a: skill("read_joints", {"arm": a}) for a in ("left", "right")}
                return self._send(200, joint_positions_payload(per_arm, time.time()))
            if path == "/teleoperation-status":
                return self._send(200, {
                    "teleoperation_active": SESSION.jogging,
                    "available_controls": {"stop_teleoperation": SESSION.jogging},
                    "message": "governed jog session (bounded moves, not leader→follower)"})
            if path == "/available-cameras":
                return self._send(200, cameras_payload(self._probe_cameras()))
            if path.startswith("/camera-feed/"):
                return self._mjpeg(path[len("/camera-feed/"):])
            if path == "/recording-status":
                return self._send(200, recording_status_payload(
                    skill("teach_status", {}), SESSION.dataset_repo_id))
            if path == "/datasets":
                return self._send(200, datasets_payload(skill("teach_list", {})))
        except SidecarDown as e:
            return self._send(503, {"success": False, "error": "sidecar down", "detail": str(e)})
        reason = refusal_for(path)
        if reason:
            return self._refuse(path, reason)
        return self._send(404, {"success": False, "error": f"no such route: {path}",
                                "see": "/lex/routes"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        reason = refusal_for(path)
        if reason:
            return self._refuse(path, reason)
        body = self._body()
        if body is None:
            return self._send(400, {"success": False, "error": "invalid json"})
        try:
            if path == "/move-arm":
                args, refused = move_arm_request(body)
                if refused:
                    return self._refuse(path, refused)
                result = skill("move_arm", args)
                SESSION.jogging = True
                # A grant refusal is not an adapter error: it is the system
                # working, and the UI should show it as the robot's answer.
                return self._send(200, {"success": result.get("outcome") == "reached",
                                        "governed": True, "request": args, "result": result})
            if path == "/stop-teleoperation":
                SESSION.jogging = False
                return self._send(200, {"success": True, "message": "jog session ended"})
            if path == "/start-recording":
                args, refused = start_recording_request(body)
                if refused:
                    return self._refuse(path, refused)
                result = skill("teach_start", args)
                if result.get("ok"):
                    SESSION.dataset_repo_id = args["name"]
                return self._send(200, {"success": bool(result.get("ok")),
                                        "request": args, "result": result})
            if path in ("/stop-recording", "/recording-exit-early"):
                result = skill("teach_stop", {})
                return self._send(200, {"success": bool(result.get("ok")), "result": result,
                                        "message": result.get("detail", "")})
        except SidecarDown as e:
            return self._send(503, {"success": False, "error": "sidecar down", "detail": str(e)})
        return self._send(404, {"success": False, "error": f"no such route: {path}",
                                "see": "/lex/routes"})

    # -- cameras -----------------------------------------------------------
    def _probe_cameras(self):
        return {name: skill("read_camera", {"name": name}, timeout=5.0) for name in CAMERAS}

    def _mjpeg(self, cam: str):
        if cam not in CAMERAS:
            return self._send(404, {"success": False,
                                    "error": f"unknown camera {cam!r} (have {', '.join(CAMERAS)})"})
        boundary = "lexframe"
        self.send_response(200)
        self.send_header("Content-Type", f"multipart/x-mixed-replace; boundary={boundary}")
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        period = 1.0 / max(CAMERA_HZ, 0.1)
        try:
            while True:
                t0 = time.time()
                frame = skill("read_camera", {"name": cam}, timeout=5.0)
                jpeg = base64.b64decode(frame.get("jpeg_b64") or "")
                if jpeg:
                    self.wfile.write(f"--{boundary}\r\nContent-Type: image/jpeg\r\n"
                                     f"Content-Length: {len(jpeg)}\r\n\r\n".encode())
                    self.wfile.write(jpeg + b"\r\n")
                time.sleep(max(0.0, period - (time.time() - t0)))
        except (BrokenPipeError, ConnectionResetError):
            pass          # the browser closed the <img>; normal
        except SidecarDown:
            pass          # the robot went away mid-stream; the feed just ends

    def log_message(self, *a):
        print("[lelab-adapter]", self.command, self.path)


def main() -> int:
    try:
        health = sidecar_health()
    except SidecarDown as e:
        # Refuse, don't downgrade. An adapter that started without a robot
        # behind it would answer leLab's polls with invented state, and the
        # operator would have no way to tell.
        print(f"[lelab-adapter] {e}\n"
              f"[lelab-adapter] start it first:  python3 sidecar/xlerobot_sidecar.py",
              file=sys.stderr)
        return 2
    tier = "REAL HARDWARE" if health.get("hardware") else "stub (no hardware)"
    print(f"lex-robot leLab adapter on http://{HOST}:{PORT}")
    print(f"  governed by {SIDECAR} [{tier}]   CORS origin: {ORIGIN}")
    print(f"  what is and isn't served: http://{HOST}:{PORT}/lex/routes")
    print(f"  every call lands in the ledger: {SIDECAR}/governance")
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
