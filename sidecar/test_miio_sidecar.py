#!/usr/bin/env python3
"""Integration tests: the pure-Lex miio sidecar against a mock vacuum.

`miio_sidecar.lex` speaks a Xiaomi Robot Vacuum X10 (`dreame.vacuum.r2209`,
retail B102GL) directly — no Home Assistant, no Python in the request
path. These drive it as a subprocess against `mock_miio.py`, so the whole
thing runs in CI with no vacuum, no HA, and nothing on the LAN.

What the mock is for: proving the Lex client's framing agrees with an
*independent* implementation of the protocol. The mock's own AES is
checked against a NIST vector in `test_mock_miio_is_a_valid_reference`,
because a mock that got the crypto wrong in the same way as the client
would let both pass while neither worked against the real device.

    pytest sidecar/test_miio_sidecar.py

Skipped when no `lex` binary carrying `net.udp_*` and
`crypto.aes_cbc_encrypt_raw` is on PATH (lex-lang#761/#762) — those
builtins are what make this file possible at all.
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mock_miio import (  # noqa: E402
    CHARGING, RETURNING, SWEEPING, TOKEN, MockVacuum,
    _encrypt_block, _expand_key,
)

HERE = os.path.dirname(os.path.abspath(__file__))
SIDECAR = os.path.join(HERE, "miio_sidecar.lex")
LEX = os.environ.get("LEX_BIN") or shutil.which("lex")


def _lex_has_udp():
    """Whether the `lex` on PATH carries the #760 primitives."""
    if not LEX:
        return False
    probe = os.path.join(HERE, ".udp_probe.lex")
    with open(probe, "w") as f:
        f.write('import "std.net" as net\n\n'
                'fn p() -> [net] Result[Int, Str] { net.udp_open(0) }\n')
    try:
        r = subprocess.run([LEX, "check", probe], capture_output=True, text=True, timeout=60)
        return r.stdout.startswith("ok")
    except Exception:
        return False
    finally:
        os.path.exists(probe) and os.remove(probe)


pytestmark = pytest.mark.skipif(
    not _lex_has_udp(),
    reason="needs a lex with net.udp_* and crypto.aes_cbc_* (lex-lang#761/#762)",
)


def _free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Sidecar:
    """The Lex sidecar as a subprocess, torn down on exit."""

    def __init__(self, vacuum_port, **env_overrides):
        self.port = _free_port()
        env = dict(os.environ)
        env.update({
            "LEX_MIIO_HOST": "127.0.0.1",
            "LEX_MIIO_PORT": str(vacuum_port),
            "LEX_MIIO_TOKEN": TOKEN.hex(),
            "LEX_MIIO_TIMEOUT_MS": "800",
            "LEX_ROBOT_SIDECAR_PORT": str(self.port),
        })
        env.update({k: str(v) for k, v in env_overrides.items()})
        self.env = env
        self.proc = None

    def __enter__(self):
        self.proc = subprocess.Popen(
            [LEX, "run", "--allow-effects", "env,io,net", SIDECAR, "run"],
            env=self.env, cwd=os.path.dirname(HERE),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError("sidecar exited: " + self.proc.stdout.read())
            try:
                self.get("/health")
                return self
            except (urllib.error.URLError, ConnectionError, OSError):
                time.sleep(0.1)
        raise RuntimeError("sidecar did not come up")

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(timeout=15)

    def get(self, path):
        with urllib.request.urlopen(
                f"http://127.0.0.1:{self.port}{path}", timeout=5) as r:
            return json.loads(r.read() or b"{}")

    def skill(self, name):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/skill/{name}", data=b"{}",
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read() or b"{}")


# ── the mock is only useful if it is right ───────────────────────

def test_mock_miio_is_a_valid_reference():
    """Pin the mock's AES to a published vector.

    Every test below compares the Lex client against this mock. If the
    mock's crypto were wrong, the client could be wrong in exactly the
    same way and every test would still pass — while nothing worked
    against the actual vacuum. This is the test that rules that out.
    """
    key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
    block = bytes.fromhex("6bc1bee22e409f96e93d7e117393172a")
    expected = bytes.fromhex("3ad77bb40d7a3660a89ecaf32466ef97")
    assert _encrypt_block(block, _expand_key(key)) == expected, \
        "mock AES-128 must match NIST SP 800-38A F.1.1"


# ── reading ──────────────────────────────────────────────────────

def test_read_state_reaches_the_vacuum():
    with MockVacuum(port=0) as v, Sidecar(v.port) as sc:
        assert sc.get("/health")["mode"] == "miio direct"
        out = sc.skill("read_state")
        assert out["state"] == "charging"
        assert "battery 100%" in out["detail"]


def test_the_client_speaks_miot_not_the_older_verbs():
    """This generation of Dreame is MIoT-spec. Asserting on what the
    device actually received catches a client that guessed at
    `app_start`-era methods and happened to get a plausible reply."""
    with MockVacuum(port=0) as v, Sidecar(v.port) as sc:
        sc.skill("read_state")
        methods = [r["method"] for r in v.requests]
        assert "get_properties" in methods
        params = v.requests[0]["params"][0]
        assert (params["siid"], params["piid"]) == (2, 1), \
            "status is siid 2 piid 1 for r2209"


# ── actuation, verified ──────────────────────────────────────────

def test_start_moves_the_vacuum_and_says_it_verified_that():
    with MockVacuum(port=0) as v, Sidecar(v.port) as sc:
        assert v.status == CHARGING
        out = sc.skill("appliance_start")
        assert out["outcome"] == "reached", out
        assert out["verified"] is True
        assert v.status == SWEEPING, "the device really moved"


def test_stop_docks_rather_than_stranding_the_robot():
    """Same call ha_sidecar makes when it maps stop onto
    return_to_base. A vacuum halted mid-floor is an obstacle."""
    with MockVacuum(port=0) as v, Sidecar(v.port) as sc:
        sc.skill("appliance_start")
        out = sc.skill("appliance_stop")
        assert out["outcome"] == "reached", out
        assert v.status == RETURNING, "docking, not merely stopped"
        assert (3, 1) in [(r["params"]["siid"], r["params"]["aiid"])
                          for r in v.requests if r["method"] == "action"], \
            "dock is siid 3 aiid 1, not the stop action"


def test_an_appliance_that_ignores_the_command_is_not_reported_as_reached():
    """The #198 property, carried over to this sidecar: HA is not
    involved, but 'the device accepted it' is still not evidence it
    acted. Here the mock accepts the action and refuses to move."""
    with MockVacuum(port=0) as v:
        v._dispatch_real = v._dispatch

        def deaf(req):
            out = v._dispatch_real(req)
            v.status = CHARGING     # accepted, then ignored
            return out
        v._dispatch = deaf
        with Sidecar(v.port) as sc:
            out = sc.skill("appliance_start")
            assert out["outcome"] == "timeout", out
            assert out["verified"] is False
            assert "did nothing observable" in out["detail"]


# ── failure paths ────────────────────────────────────────────────

def test_a_wrong_token_is_diagnosed_rather_than_reported_as_a_timeout():
    """The handshake is unencrypted, so it succeeds even with a bad
    token and only the command goes unanswered. That is a
    distinguishable signal and worth spending on: the alternative is a
    bare timeout that sends someone looking at cables."""
    with MockVacuum(port=0) as v, Sidecar(v.port, LEX_MIIO_TOKEN="ff" * 16) as sc:
        out = sc.skill("read_state")
        assert out["state"] == ""
        assert "token is wrong" in out["detail"], out


def test_an_unreachable_vacuum_stalls_and_says_why():
    with MockVacuum(port=0) as v:
        dead = v.port
    with Sidecar(dead, LEX_MIIO_TIMEOUT_MS="300") as sc:
        out = sc.skill("appliance_start")
        assert out["outcome"] == "stalled", out
        assert "handshake" in out["detail"]


def test_an_unknown_skill_is_named_not_swallowed():
    with MockVacuum(port=0) as v, Sidecar(v.port) as sc:
        assert "unknown skill" in sc.skill("nope")["error"]


@pytest.mark.parametrize("env,expect", [
    ({"LEX_MIIO_TOKEN": "not-hex"}, "not valid hex"),
    ({"LEX_MIIO_TOKEN": "aabb"}, "16 bytes"),
    ({"LEX_MIIO_HOST": ""}, "LEX_MIIO_HOST is not set"),
])
def test_bad_configuration_refuses_to_start_rather_than_half_working(env, expect):
    """A sidecar that came up and then failed every call would look
    like a broken vacuum. Fail at the door, naming the field."""
    e = dict(os.environ)
    e.update({
        "LEX_MIIO_HOST": "127.0.0.1", "LEX_MIIO_PORT": "54321",
        "LEX_MIIO_TOKEN": TOKEN.hex(), "LEX_ROBOT_SIDECAR_PORT": str(_free_port()),
    })
    e.update(env)
    r = subprocess.run(
        [LEX, "run", "--allow-effects", "env,io,net", SIDECAR, "run"],
        env=e, cwd=os.path.dirname(HERE), capture_output=True, text=True, timeout=60)
    assert expect in r.stdout, r.stdout
