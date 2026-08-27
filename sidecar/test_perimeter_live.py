#!/usr/bin/env python3
"""Integration tests: the perimeter as the running sidecar actually applies it.

`test_perimeter.py` unit-tests the decisions; this drives a live
`xlerobot_sidecar.py` on the Tier-1 stub (no hardware, no `lerobot`) and
asserts the wiring — the gate is really in front of `/skill/`, the deadman
really stops a base move, and the unix socket really serves the same handler.

Each test runs the sidecar as a subprocess with its own environment, because
the perimeter is configured at import time and a test that mutated the parent's
`os.environ` would be testing something the shipped code never does.

    pytest sidecar/test_perimeter_live.py
"""

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SIDECAR = os.path.join(HERE, "xlerobot_sidecar.py")


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Sidecar:
    """A live stub sidecar, torn down on exit."""

    def __init__(self, **env_overrides):
        self.port = _free_port()
        env = dict(os.environ)
        env.pop("LEX_ROBOT_HW", None)  # stub, always
        env["LEX_ROBOT_SIDECAR_PORT"] = str(self.port)
        env.update({k: str(v) for k, v in env_overrides.items()})
        self.env = env
        self.proc = None

    def __enter__(self):
        self.proc = subprocess.Popen(
            [sys.executable, SIDECAR], env=self.env, cwd=HERE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError("sidecar exited: " + self.proc.stdout.read())
            try:
                self.get("/health")
                return self
            except (urllib.error.URLError, ConnectionError, OSError):
                time.sleep(0.05)
        raise RuntimeError("sidecar did not come up")

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.port}"

    def get(self, path):
        with urllib.request.urlopen(self.base_url + path, timeout=10) as r:
            return json.loads(r.read())

    def post(self, path, payload=None, token=None):
        """(status, body). A 403 is an answer here, not an exception."""
        data = json.dumps(payload or {}).encode()
        req = urllib.request.Request(self.base_url + path, data=data,
                                     headers={"Content-Type": "application/json"})
        if token is not None:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())


# ── The default: nothing changes for anyone ─────────────────────────────────

def test_an_unconfigured_sidecar_is_wide_open_and_says_so():
    """Every existing demo, test and script must behave exactly as before —
    and the operator must be told the door is unlatched rather than left to
    infer it."""
    with Sidecar() as sc:
        status, body = sc.post("/skill/move_base", {"x": 1.0, "y": 1.0, "speed": 0.2})
        assert status == 200
        assert body["outcome"] == "reached"
        health = sc.get("/health")
        assert health["perimeter"]["token_auth"] is False
        assert health["deadman"]["armed"] is False


# ── The token gate ──────────────────────────────────────────────────────────

def test_a_mutating_skill_needs_the_token():
    with Sidecar(LEX_ROBOT_SIDECAR_TOKEN="hunter2") as sc:
        status, body = sc.post("/skill/move_base", {"x": 1.0, "y": 1.0, "speed": 0.2})
        assert status == 403
        assert body["outcome"] == "denied"
        assert "perimeter" in body["detail"]

        status, body = sc.post("/skill/move_base", {"x": 1.0, "y": 1.0, "speed": 0.2},
                               token="hunter2")
        assert status == 200
        assert body["outcome"] == "reached"


def test_a_read_is_ungated_under_a_token():
    """Support must be able to inspect a robot it is not authorised to change."""
    with Sidecar(LEX_ROBOT_SIDECAR_TOKEN="hunter2") as sc:
        status, body = sc.post("/skill/read_base", {})
        assert status == 200
        assert body.get("ok") is True


def test_a_wrong_token_is_refused():
    with Sidecar(LEX_ROBOT_SIDECAR_TOKEN="hunter2") as sc:
        status, _ = sc.post("/skill/move_base", {"x": 1.0, "y": 1.0, "speed": 0.2},
                            token="wrong")
        assert status == 403


def test_an_unknown_skill_is_gated_too():
    """The fail-closed default, live: a skill nobody has added yet still needs
    the token rather than sailing past the gate."""
    with Sidecar(LEX_ROBOT_SIDECAR_TOKEN="hunter2") as sc:
        status, _ = sc.post("/skill/some_future_skill", {})
        assert status == 403


# ── The deadman ─────────────────────────────────────────────────────────────

def test_a_configured_deadman_that_nobody_beats_never_fires():
    """The property that keeps every existing program working."""
    with Sidecar(LEX_XLE_DEADMAN_MS=200) as sc:
        time.sleep(0.5)
        status, body = sc.post("/skill/move_base", {"x": 1.0, "y": 1.0, "speed": 0.2})
        assert status == 200
        assert body["outcome"] == "reached", "an un-armed deadman must not stop anything"


def test_a_beat_arms_it_and_silence_then_expires_it():
    """Over HTTP, `/health` is where the deadman's state is observable: a beat
    arms it, and silence past the interval expires it."""
    with Sidecar(LEX_XLE_DEADMAN_MS=200) as sc:
        status, body = sc.post("/heartbeat")
        assert status == 200
        assert body["deadman"]["armed"] is True
        assert body["deadman"]["expired"] is False

        time.sleep(0.5)
        assert sc.get("/health")["deadman"]["expired"] is True


def test_an_ordinary_skill_call_refreshes_but_never_arms():
    """Traffic keeps a live caller alive — a request IS an intent, which is
    why there is no pre-flight refusal on the request itself. But traffic
    alone must not ARM the deadman, or the first base move in any deployment
    that merely set the interval would trip at the deadline."""
    with Sidecar(LEX_XLE_DEADMAN_MS=400) as sc:
        sc.post("/skill/read_base", {})
        assert sc.get("/health")["deadman"]["armed"] is False, "traffic must not arm it"

        sc.post("/heartbeat")
        time.sleep(0.25)
        sc.post("/skill/read_base", {})  # a live caller, mid-interval
        time.sleep(0.25)
        assert sc.get("/health")["deadman"]["expired"] is False, "traffic must refresh it"

        time.sleep(0.5)
        assert sc.get("/health")["deadman"]["expired"] is True


# ── The deadman where it actually bites: the drive loop ─────────────────────

class _FakeClock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def test_the_drive_loop_stops_the_wheels_when_the_deadman_expires():
    """The real shipped loop, driven directly. This is the case the deadman
    exists for: the caller died AFTER the request was accepted, so nothing
    else will ever stop this drive before its 20 s timeout."""
    sys.path.insert(0, HERE)
    import perimeter
    import xlerobot_sidecar as xs

    base = object.__new__(xs._HwDiffBase)
    base.pose = {"x": 0.0, "y": 0.0, "heading": 0.0}
    commanded = []
    base._set_wheel_velocity = lambda v, w: commanded.append((v, w))

    clock = _FakeClock()
    dead = perimeter.Deadman(200, clock=clock)
    dead.beat()
    clock.advance(1.0)  # the caller went quiet

    previous = xs.DEADMAN
    xs.DEADMAN = dead
    try:
        result = base.drive(5.0, 5.0, 0.2, 20.0)
    finally:
        xs.DEADMAN = previous

    assert result["outcome"] == "stalled"
    assert "deadman" in result["detail"]
    assert commanded == [(0.0, 0.0)], \
        "the wheels must be stopped, and nothing else commanded on the way out"


def test_a_live_caller_is_not_stopped_by_the_loop_guard():
    """The other half: with beats arriving, the same loop drives normally.
    Without this the test above would pass on a loop that never moves."""
    sys.path.insert(0, HERE)
    import perimeter
    import xlerobot_sidecar as xs

    base = object.__new__(xs._HwDiffBase)
    base.pose = {"x": 0.0, "y": 0.0, "heading": 0.0}
    commanded = []
    base._set_wheel_velocity = lambda v, w: commanded.append((v, w))

    clock = _FakeClock()
    dead = perimeter.Deadman(200, clock=clock)
    dead.beat()  # armed and fresh; the fake clock never advances

    previous = xs.DEADMAN
    xs.DEADMAN = dead
    try:
        result = base.drive(0.0, 0.0, 0.2, 2.0)
    finally:
        xs.DEADMAN = previous

    assert result["outcome"] == "reached"
    assert commanded, "the loop must actually have commanded the wheels"


def test_only_base_motion_consults_the_deadman():
    """The discrimination is the whole design — microduck zeroes the twist and
    leaves the head pose alone, because a stale velocity walks the robot into a
    wall while a stale hold is harmless. Here that means the deadman is
    consulted in the two base drive loops and nowhere else; an arm path that
    grew a check would be a behaviour change, not a refactor."""
    src = open(SIDECAR).read()
    lines = src.split("\n")
    checks = [i for i, line in enumerate(lines) if "DEADMAN.expired()" in line]
    assert len(checks) == 2, f"expected 2 deadman checks, found {len(checks)}"
    for i in checks:
        enclosing = next(lines[j] for j in range(i, -1, -1)
                         if lines[j].startswith("    def "))
        assert enclosing.strip().startswith("def drive("), \
            f"a deadman check appeared outside a base drive loop: {enclosing.strip()}"


# ── The bind guard ──────────────────────────────────────────────────────────

def test_the_sidecar_refuses_to_bind_a_reachable_address(tmp_path):
    """Patched to bind 0.0.0.0 — the 'make it work from my laptop' change the
    guard exists to catch. It must refuse loudly rather than come up."""
    src = open(SIDECAR).read().replace('HOST = "127.0.0.1"', 'HOST = "0.0.0.0"', 1)
    patched = tmp_path / "xlerobot_sidecar.py"
    patched.write_text(src)
    env = dict(os.environ)
    env.pop("LEX_ROBOT_HW", None)
    env["LEX_ROBOT_SIDECAR_PORT"] = str(_free_port())
    env["PYTHONPATH"] = HERE + os.pathsep + env.get("PYTHONPATH", "")
    proc = subprocess.run([sys.executable, str(patched)], env=env, cwd=HERE,
                          capture_output=True, text=True, timeout=120)
    assert proc.returncode != 0
    assert "refusing to bind" in (proc.stdout + proc.stderr)


# ── The unix socket ─────────────────────────────────────────────────────────

class _UnixHTTPConnection:
    """The smallest thing that can POST a skill over a unix socket."""

    def __init__(self, path):
        self.path = path

    def post(self, route, payload):
        body = json.dumps(payload).encode()
        req = (f"POST {route} HTTP/1.1\r\nHost: localhost\r\n"
               f"Content-Type: application/json\r\n"
               f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(30)
            s.connect(self.path)
            s.sendall(req)
            chunks = []
            while True:
                got = s.recv(65536)
                if not got:
                    break
                chunks.append(got)
        raw = b"".join(chunks)
        head, _, payload_bytes = raw.partition(b"\r\n\r\n")
        status = int(head.split(b" ", 2)[1])
        return status, json.loads(payload_bytes)


@pytest.mark.skipif(not hasattr(socket, "AF_UNIX"), reason="no unix sockets here")
def test_the_unix_socket_serves_the_same_handler(tmp_path):
    sock = tmp_path / "xle.sock"
    with Sidecar(LEX_ROBOT_SIDECAR_SOCKET=str(sock)) as sc:
        deadline = time.monotonic() + 20
        while not sock.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert sock.exists(), "the unix listener never bound"
        # Group-owned, world-nothing: the "who may TALK to it" layer.
        assert (os.stat(sock).st_mode & 0o777) == 0o660

        conn = _UnixHTTPConnection(str(sock))
        status, body = conn.post("/skill/move_base", {"x": 1.0, "y": 1.0, "speed": 0.2})
        assert status == 200
        assert body["outcome"] == "reached"
        # And the TCP listener is still there — one handler, two front doors.
        assert sc.get("/health")["ok"] is True


@pytest.mark.skipif(not hasattr(socket, "SO_PEERCRED"), reason="SO_PEERCRED is Linux-only")
def test_our_own_uid_passes_an_allow_list_that_excludes_it_by_name(tmp_path):
    """The sidecar's own uid is always permitted — it could replace the
    sidecar regardless, so refusing it would be theatre — even when the
    allow-list names only a different uid."""
    sock = tmp_path / "xle.sock"
    with Sidecar(LEX_ROBOT_SIDECAR_SOCKET=str(sock),
                 LEX_ROBOT_SIDECAR_ALLOW_UIDS="65534") as sc:
        deadline = time.monotonic() + 20
        while not sock.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        status, body = _UnixHTTPConnection(str(sock)).post(
            "/skill/move_base", {"x": 1.0, "y": 1.0, "speed": 0.2})
        assert status == 200
        assert body["outcome"] == "reached"
        assert sc.get("/health")["perimeter"]["peer_allow_list"] is True
