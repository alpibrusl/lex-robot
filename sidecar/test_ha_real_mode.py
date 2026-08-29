#!/usr/bin/env python3
"""Integration tests: ha_sidecar's REAL mode against a mock Home Assistant.

`ha_sidecar.py`'s `RealHouse` was untested — every existing test exercises the
stub house. This drives a live `ha_sidecar.py` in real mode (`LEX_HA_URL` +
`LEX_HA_TOKEN` set) against `mock_ha.py`, with no Home Assistant and no
appliance anywhere.

Each test runs the sidecar as a subprocess with its own environment, because
`USE_HA`, `START_SERVICE` and `STOP_SERVICE` are read at import time — a test
that mutated the parent's `os.environ` would be testing something the shipped
code never does. Same reasoning, same shape, as `test_perimeter_live.py`.

    pytest sidecar/test_ha_real_mode.py
"""

import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

from mock_ha import TOKEN, MockHA

HERE = os.path.dirname(os.path.abspath(__file__))
SIDECAR = os.path.join(HERE, "ha_sidecar.py")

VACUUM = "vacuum.xiaomi_s10"
WASHER = "switch.washer"


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Sidecar:
    """A live ha_sidecar in real mode, torn down on exit."""

    def __init__(self, ha_url, **env_overrides):
        self.port = _free_port()
        env = dict(os.environ)
        env["LEX_ROBOT_SIDECAR_PORT"] = str(self.port)
        env["LEX_HA_URL"] = ha_url
        env["LEX_HA_TOKEN"] = TOKEN
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
            self.proc.wait(timeout=10)

    def get(self, path):
        with urllib.request.urlopen(
                f"http://127.0.0.1:{self.port}{path}", timeout=5) as r:
            return json.loads(r.read() or b"{}")

    def skill(self, name, **args):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/skill/{name}",
            data=json.dumps(args).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"{}")


def test_real_mode_is_actually_engaged():
    """A sanity check with teeth: if this fails, every test below is silently
    exercising the stub house and proving nothing about RealHouse."""
    with MockHA() as ha, Sidecar(ha.url) as sc:
        assert sc.get("/health")["ha"] is True


def test_read_state_reaches_the_vacuum():
    with MockHA() as ha, Sidecar(ha.url) as sc:
        out = sc.skill("read_state", entity=VACUUM)
        assert out["state"] == "docked"
        assert ha.url in out["detail"]


def test_read_state_of_an_unknown_entity_does_not_invent_one():
    with MockHA() as ha, Sidecar(ha.url) as sc:
        out = sc.skill("read_state", entity="vacuum.nonexistent")
        assert out["state"] == ""


def test_vacuum_start_and_stop_with_the_right_services():
    """The workaround that works today: point the env vars at vacuum services."""
    with MockHA() as ha, Sidecar(ha.url, LEX_HA_START_SERVICE="vacuum.start",
                                 LEX_HA_STOP_SERVICE="vacuum.return_to_base") as sc:
        assert sc.skill("appliance_start", entity=VACUUM)["outcome"] == "reached"
        assert ha.state_of(VACUUM) == "cleaning"
        assert sc.skill("appliance_stop", entity=VACUUM)["outcome"] == "reached"
        assert ha.state_of(VACUUM) == "returning"


def test_stop_returns_to_base_rather_than_stranding_the_robot():
    """A vacuum halted mid-floor is an obstacle, not a stopped appliance."""
    with MockHA() as ha, Sidecar(ha.url, LEX_HA_START_SERVICE="vacuum.start",
                                 LEX_HA_STOP_SERVICE="vacuum.return_to_base") as sc:
        sc.skill("appliance_start", entity=VACUUM)
        sc.skill("appliance_stop", entity=VACUUM)
        assert ha.state_of(VACUUM) == "returning"
        assert ha.calls[-1]["service"] == "vacuum.return_to_base"


def test_unreachable_ha_stalls_and_says_why():
    """The contract RealHouse already keeps, pinned so it stays kept."""
    with MockHA() as ha:
        dead = ha.url
    with Sidecar(dead) as sc:
        out = sc.skill("appliance_start", entity=VACUUM)
        assert out["outcome"] == "stalled"
        assert out["detail"]


def test_the_service_is_derived_from_the_entity_with_no_env_vars():
    """#198: the fix. No LEX_HA_*_SERVICE anywhere — the vacuum is driven by
    vacuum.start because it is a vacuum, not because someone configured it."""
    with MockHA() as ha, Sidecar(ha.url) as sc:
        assert sc.skill("appliance_start", entity=VACUUM)["outcome"] == "reached"
        assert ha.state_of(VACUUM) == "cleaning"
        assert ha.calls[-1]["service"] == "vacuum.start"


def test_one_sidecar_drives_a_vacuum_and_a_washer_at_once():
    """The acceptance criterion from #198. Previously impossible: a single
    global service map is only ever right for one of the two."""
    with MockHA() as ha, Sidecar(ha.url) as sc:
        assert sc.skill("appliance_start", entity=VACUUM)["outcome"] == "reached"
        assert sc.skill("appliance_start", entity=WASHER)["outcome"] == "reached"
        assert ha.state_of(VACUUM) == "cleaning"
        assert ha.state_of(WASHER) == "running"
        assert {c["service"] for c in ha.calls} == {"vacuum.start", "switch.turn_on"}


def test_a_cross_domain_override_is_refused_before_it_is_sent():
    """The bug this pinned as xfail until #198 was fixed. An override that
    cannot work is refused rather than sent and misread as success — and
    nothing reaches HA at all, which is the part worth asserting: a refusal
    that still made the call would be a different bug wearing this one's face.
    """
    with MockHA() as ha, Sidecar(ha.url, LEX_HA_START_SERVICE="switch.turn_on") as sc:
        out = sc.skill("appliance_start", entity=VACUUM)
        assert out["outcome"] == "stalled", out
        assert "does not reach" in out["detail"]
        assert ha.state_of(VACUUM) == "docked"
        assert ha.calls == []


def test_a_homeassistant_domain_service_is_allowed_through():
    """`homeassistant.*` deliberately acts on any domain, so the guard must not
    refuse it. Without this the fix would trade one wrong answer for another."""
    with MockHA() as ha, Sidecar(
            ha.url, LEX_HA_START_SERVICE="homeassistant.turn_on") as sc:
        sc.skill("appliance_start", entity=VACUUM)
        assert ha.calls[-1]["service"] == "homeassistant.turn_on"


def test_an_unknown_domain_is_not_silently_guessed_at():
    """A domain DOMAIN_SERVICES does not know falls back to switch.turn_on —
    which the guard then refuses, because a sensor is not a switch. The guess
    is made, but it is never sent."""
    with MockHA() as ha, Sidecar(ha.url) as sc:
        out = sc.skill("appliance_start", entity="sensor.pvpc")
        assert out["outcome"] == "stalled", out
        assert ha.calls == []
