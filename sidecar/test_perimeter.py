#!/usr/bin/env python3
"""Unit tests for sidecar/perimeter.py -- the bind guard, the two-layer
authorization, and the base deadman.

Pure stdlib, no hardware, no `lerobot`: run with `pytest sidecar/test_perimeter.py`
alongside the other standalone sidecar tests.
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import perimeter  # noqa: E402
from perimeter import Deadman, RemoteBindRefused  # noqa: E402


# ── The bind guard ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("host", ["127.0.0.1", "::1", "localhost", "127.0.0.53"])
def test_loopback_addresses_bind_freely(host):
    perimeter.assert_loopback(host, env={})


@pytest.mark.parametrize("host", ["0.0.0.0", "", "192.168.1.10", "::", "10.0.0.4"])
def test_a_reachable_address_is_refused(host):
    """The wrong-interface bug class: a typo, a config, or a 'make it work from
    my laptop' patch must not silently expose actuation to the network."""
    with pytest.raises(RemoteBindRefused):
        perimeter.assert_loopback(host, env={})


def test_the_override_is_explicit_and_names_the_token():
    perimeter.assert_loopback("0.0.0.0", env={perimeter.ALLOW_REMOTE_BIND_ENV: "1"})
    # And the refusal has to tell whoever hit it what to do about it, or they
    # will reach for the override without the token that makes it survivable.
    with pytest.raises(RemoteBindRefused) as e:
        perimeter.assert_loopback("0.0.0.0", env={})
    assert perimeter.ALLOW_REMOTE_BIND_ENV in str(e.value)
    assert "LEX_ROBOT_SIDECAR_TOKEN" in str(e.value)


def test_a_hostname_that_is_not_localhost_is_not_trusted():
    """No DNS: a name that resolves to loopback today can resolve elsewhere
    tomorrow, and refusing what we cannot prove is the resolver's rule."""
    with pytest.raises(RemoteBindRefused):
        perimeter.assert_loopback("my-robot.local", env={})


# ── Which calls are gated ────────────────────────────────────────────────────

def test_reads_are_not_mutating():
    for skill in ("read_joints", "read_base", "read_grant", "locate_object"):
        assert not perimeter.is_mutating(skill)


def test_actuation_is_mutating():
    for skill in ("move_arm", "grasp_arm", "move_base", "speak", "teach_replay"):
        assert perimeter.is_mutating(skill)


def test_an_unknown_skill_is_mutating():
    """The load-bearing default. A read-only allow-list someone forgets to
    extend needlessly gates a new sensor read; a mutating deny-list someone
    forgets to extend leaves a new actuator ungated. Only one is survivable."""
    assert perimeter.is_mutating("some_skill_added_next_release")
    assert perimeter.is_mutating("")


# ── The token ────────────────────────────────────────────────────────────────

ENV = {perimeter.TOKEN_ENV: "s3cret"}


def test_token_auth_is_off_by_default():
    """Every existing demo, test and curl in this repo must behave as before."""
    assert perimeter.check_token(None, "move_base", env={}) is None


def test_a_mutating_call_needs_the_token():
    assert perimeter.check_token(None, "move_base", env=ENV) is not None
    assert perimeter.check_token("Bearer s3cret", "move_base", env=ENV) is None


def test_a_wrong_token_is_refused():
    assert perimeter.check_token("Bearer nope", "move_base", env=ENV) == "bad bearer token"


def test_a_read_is_ungated_even_with_a_token_configured():
    """microduck's rule: support must be able to inspect a robot it is not
    authorised to change."""
    assert perimeter.check_token(None, "read_joints", env=ENV) is None


def test_the_scheme_is_parsed_case_insensitively_and_junk_is_refused():
    assert perimeter.check_token("bearer s3cret", "move_base", env=ENV) is None
    assert perimeter.check_token("s3cret", "move_base", env=ENV) is not None
    assert perimeter.check_token("Basic s3cret", "move_base", env=ENV) is not None


def test_a_token_file_is_read_and_stripped(tmp_path):
    p = tmp_path / "token"
    p.write_text("from-a-file\n")
    env = {perimeter.TOKEN_FILE_ENV: str(p)}
    assert perimeter.check_token("Bearer from-a-file", "move_base", env=env) is None
    assert perimeter.check_token("Bearer other", "move_base", env=env) is not None


def test_an_unreadable_token_file_does_not_silently_open_the_gate():
    """A missing file means auth is OFF, which is the safe-by-default reading
    only because the bind guard is separately holding the door. Assert the
    behaviour explicitly so a change to it is a deliberate one."""
    env = {perimeter.TOKEN_FILE_ENV: "/nonexistent/token"}
    assert perimeter.configured_token(env) is None


# ── Peer credentials ─────────────────────────────────────────────────────────

def test_peer_allow_list_is_off_by_default():
    assert perimeter.peer_allowed((1234, 1234), "move_base", env={}) is None


def test_a_listed_uid_may_change_the_robot():
    env = {perimeter.ALLOW_UIDS_ENV: "1000,1001"}
    assert perimeter.peer_allowed((1000, 50), "move_base", env=env, own_uid=0) is None
    assert perimeter.peer_allowed((1002, 50), "move_base", env=env, own_uid=0) is not None


def test_a_listed_gid_may_change_the_robot():
    env = {perimeter.ALLOW_GIDS_ENV: "44"}
    assert perimeter.peer_allowed((1002, 44), "move_base", env=env, own_uid=0) is None
    assert perimeter.peer_allowed((1002, 45), "move_base", env=env, own_uid=0) is not None


def test_our_own_uid_is_always_permitted():
    """It could replace the sidecar binary regardless; refusing it is theatre."""
    env = {perimeter.ALLOW_UIDS_ENV: "1000"}
    assert perimeter.peer_allowed((7, 7), "move_base", env=env, own_uid=7) is None


def test_reads_stay_ungated_under_an_allow_list():
    env = {perimeter.ALLOW_UIDS_ENV: "1000"}
    assert perimeter.peer_allowed((1002, 50), "read_joints", env=env, own_uid=0) is None


def test_unavailable_credentials_are_refused_not_assumed():
    """Refuse, don't downgrade: a platform that cannot answer 'who is this'
    must not be read as 'anyone'."""
    env = {perimeter.ALLOW_UIDS_ENV: "1000"}
    reason = perimeter.peer_allowed(None, "move_base", env=env, own_uid=0)
    assert reason is not None and "refusing rather than guessing" in reason


# ── The deadman ──────────────────────────────────────────────────────────────

class FakeClock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def test_an_unconfigured_deadman_never_fires():
    clock = FakeClock()
    d = Deadman(0, clock=clock)
    d.beat()
    clock.advance(3600)
    assert not d.armed
    assert not d.expired()


def test_a_configured_deadman_that_nobody_beats_never_fires():
    """The property every existing demo depends on: nothing in this repo sends
    a heartbeat, so nothing in this repo is ever stopped by one. A deadman
    armed from birth would stop the first base move of every program that had
    never heard of it -- which is how a safety feature gets switched off."""
    clock = FakeClock()
    d = Deadman(500, clock=clock)
    clock.advance(3600)
    assert not d.armed
    assert not d.expired()


def test_one_beat_arms_it_and_silence_then_fires():
    clock = FakeClock()
    d = Deadman(500, clock=clock)
    d.beat()
    assert d.armed
    clock.advance(0.4)
    assert not d.expired(), "still inside the interval"
    clock.advance(0.2)
    assert d.expired(), "0.6s of silence past a 0.5s deadman"


def test_a_beat_clears_it():
    clock = FakeClock()
    d = Deadman(500, clock=clock)
    d.beat()
    clock.advance(0.6)
    assert d.expired()
    d.beat()
    assert not d.expired(), "a live caller un-expires the deadman"


def test_it_cannot_be_disarmed_once_armed():
    """Once a caller has claimed to be alive it does not get to take that
    back -- otherwise the failure mode is a client that 'turns off' the
    deadman by crashing in the right order."""
    clock = FakeClock()
    d = Deadman(500, clock=clock)
    d.beat()
    clock.advance(10)
    assert d.armed and d.expired()


def test_from_env_reads_the_interval_and_tolerates_junk():
    assert Deadman.from_env(env={}).interval_s == 0.0
    assert Deadman.from_env(env={perimeter.DEADMAN_MS_ENV: "750"}).interval_s == 0.75
    assert Deadman.from_env(env={perimeter.DEADMAN_MS_ENV: "not-a-number"}).interval_s == 0.0


def test_the_stop_is_reported_and_says_what_it_did_not_touch():
    """A stop the caller cannot explain is the failure microduck's state frame
    exists to prevent -- and the arm exemption is the whole design, so it says
    so."""
    clock = FakeClock()
    d = Deadman(500, clock=clock)
    d.beat()
    clock.advance(0.9)
    detail = d.stop_detail()
    assert "deadman" in detail
    assert "900ms" in detail
    assert "Arm hold is untouched" in detail


def test_status_is_reportable_before_any_beat():
    d = Deadman(500, clock=FakeClock())
    s = d.status()
    assert s == {"armed": False, "interval_ms": 500, "age_ms": None, "expired": False}
