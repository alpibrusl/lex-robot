"""Tests for the read-only servo-bus health gate.

No hardware, no lerobot: every bus is injected. The safety-critical test is
`test_the_gate_never_writes_and_never_enables_torque` — this module is allowed
to run at any time precisely because it only pings and reads, and that property
should fail loudly if anyone adds a write.
"""

import json

import pytest

import bus_preflight
from bus_preflight import (BUS_SPECS, DEFAULT_MAX_FAIL_PCT,
                           TOWER_DEFAULT_TOLERANCE_TICKS, BusResult,
                           ServoResult, TowerReference, main, motor_name,
                           port_for, preflight, scan_bus, soak)

#: Anything a healthy bus must never be asked to do by this module.
FORBIDDEN = ("write", "sync_write", "enable_torque", "disable_torque",
             "connect", "configure", "set_half_duplex")


class FakeBus:
    """A bus that answers pings and reads, and records anything else."""

    def __init__(self, present=(), fail_ids=(), fail_every=1, positions=None):
        #: ids that answer a ping at all
        self.present = set(present)
        #: id -> its reads fail
        self.fail_ids = set(fail_ids)
        #: 1 = every read fails, 2 = every other, ...
        self.fail_every = fail_every
        #: id -> the tick value `read` reports (default 2048)
        self.positions = dict(positions or {})
        self.pings = []
        self.reads = 0
        self.forbidden_calls = []
        self.disconnected = False
        self._n = {}

    def ping(self, motor_id, num_retry=0):
        self.pings.append((motor_id, num_retry))
        return 1 if motor_id in self.present else None

    def read(self, register, name, normalize=True):
        self.reads += 1
        motor_id = int(name[1:])
        if motor_id in self.fail_ids:
            self._n[motor_id] = self._n.get(motor_id, 0) + 1
            if self._n[motor_id] % self.fail_every == 0:
                raise ConnectionError("no response")
        return self.positions.get(motor_id, 2048)

    def disconnect(self, disable_torque=True):
        self.disconnected = True
        self.disconnect_disable_torque = disable_torque
        if disable_torque:
            # lerobot's DEFAULT, and a write to every motor on the bus.
            self.forbidden_calls.append("disconnect(disable_torque=True)")

    def __getattr__(self, item):
        if item in FORBIDDEN:
            def recorder(*a, **k):
                self.forbidden_calls.append(item)
            return recorder
        raise AttributeError(item)


ALL_RIGHT = BUS_SPECS["right"][2]


def scan_right(bus, reads=10):
    return scan_bus(bus, "right", "/dev/fake", ALL_RIGHT, reads)


# --- the property that makes this safe to run unattended ----------------------

def test_closing_the_bus_does_not_disable_torque():
    """Regression: `MotorsBus.disconnect()` disables torque BY DEFAULT.

    That is a write to every motor, and against an arm holding a pose it would
    drop torque on all six joints and let the arm fall — the same hazard
    `teach_free` is grant-gated for. Found on real hardware, where a bare
    `disconnect()` raised trying to write `Torque_Enable` to a motor id that
    was not on the bus. The read-only claim is only true with
    `disable_torque=False`, so it is pinned here rather than trusted.

    `scan_bus` alone cannot catch this — it never closes the bus — which is
    exactly why the original safety test missed it.
    """
    bus = FakeBus(present=ALL_RIGHT)
    preflight(["right"], reads=2, opener=lambda p, i: bus)
    assert bus.disconnected
    assert bus.disconnect_disable_torque is False
    assert bus.forbidden_calls == []


def test_the_bus_is_closed_without_writing_even_when_scanning_raises(monkeypatch):
    bus = FakeBus(present=ALL_RIGHT)
    monkeypatch.setattr(bus_preflight, "scan_bus",
                        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    with pytest.raises(RuntimeError):
        preflight(["right"], reads=1, opener=lambda p, i: bus)
    assert bus.disconnect_disable_torque is False
    assert bus.forbidden_calls == []


def test_the_gate_never_writes_and_never_enables_torque():
    bus = FakeBus(present=ALL_RIGHT)
    scan_right(bus, reads=5)
    assert bus.forbidden_calls == []
    assert bus.reads == len(ALL_RIGHT) * 5


def test_the_gate_does_not_retry_pings():
    """Retries would hide the exact signal this gate exists to detect."""
    bus = FakeBus(present=ALL_RIGHT)
    scan_right(bus, reads=1)
    assert [p[1] for p in bus.pings] == [0] * len(ALL_RIGHT)
    # exactly one ping per id, like lerobot's own _assert_motors_exist
    assert [p[0] for p in bus.pings] == list(ALL_RIGHT)


# --- verdicts -----------------------------------------------------------------

def test_a_healthy_bus_passes():
    r = scan_right(FakeBus(present=ALL_RIGHT))
    assert r.ok()
    assert r.reasons() == []
    assert r.missing_ids == []
    assert r.worst_fail_pct == 0.0


def test_missing_motors_fail_the_handshake_and_are_named():
    r = scan_right(FakeBus(present=[1, 2, 3]))
    assert not r.ok()
    assert r.missing_ids == [4, 5, 6, 9, 10]
    assert "SO101Follower would refuse this arm" in " ".join(r.reasons())


def test_dropped_reads_fail_and_name_the_id_and_rate():
    """The 2026-08-23 shape: pings answer, sustained reads do not."""
    r = scan_right(FakeBus(present=ALL_RIGHT, fail_ids=[9]), reads=20)
    assert not r.ok()
    assert r.missing_ids == []          # the handshake alone would have passed
    reasons = " ".join(r.reasons())
    assert "id 9" in reasons and "100.0%" in reasons
    assert r.worst_fail_pct == 100.0


def test_a_partial_dropper_is_still_a_failure():
    r = scan_right(FakeBus(present=ALL_RIGHT, fail_ids=[9], fail_every=2), reads=20)
    assert not r.ok()
    assert r.worst_fail_pct == pytest.approx(50.0)


def test_max_fail_pct_can_tolerate_a_known_rate():
    bus = FakeBus(present=ALL_RIGHT, fail_ids=[9], fail_every=4)   # 25%
    r = scan_right(bus, reads=20)
    assert not r.ok(DEFAULT_MAX_FAIL_PCT)
    assert r.ok(max_fail_pct=30.0)


def test_zero_is_the_default_tolerance():
    assert DEFAULT_MAX_FAIL_PCT == 0.0
    r = BusResult(name="x", port="p", expected_ids=(1,),
                  handshake_found=(1,),
                  servos=[ServoResult(id=1, reads=100, failures=1)])
    assert not r.ok()


# --- opening failures are a different verdict ---------------------------------

def test_a_bus_that_cannot_be_opened_is_reported_as_such():
    def boom(port, ids):
        raise FileNotFoundError(port)

    (r,) = preflight(["right"], reads=5, opener=boom)
    assert r.error and "FileNotFoundError" in r.error
    assert not r.ok()
    assert "could not be opened" in r.reasons()[0]


def test_the_bus_is_disconnected_even_when_scanning_raises(monkeypatch):
    bus = FakeBus(present=ALL_RIGHT)
    monkeypatch.setattr(bus_preflight, "scan_bus",
                        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))
    with pytest.raises(RuntimeError):
        preflight(["right"], reads=1, opener=lambda p, i: bus)
    assert bus.disconnected


# --- ports --------------------------------------------------------------------

def test_port_falls_back_to_the_stable_by_id_path(monkeypatch):
    monkeypatch.delenv("LEX_XLE_RIGHT_PORT", raising=False)
    port = port_for("right")
    assert port.startswith("/dev/serial/by-id/")
    assert "5B61033220" in port          # the adapter serial, not ttyACM ordering


def test_env_var_overrides_the_by_id_path(monkeypatch):
    monkeypatch.setenv("LEX_XLE_RIGHT_PORT", "/dev/ttyACM7")
    assert port_for("right") == "/dev/ttyACM7"


def test_motor_names_match_what_open_bus_builds():
    assert motor_name(9) == "m9"


# --- exit status is the contract ---------------------------------------------

def _run(monkeypatch, bus, argv):
    monkeypatch.setattr(bus_preflight, "open_bus", lambda p, i: bus)
    return main(argv)


def test_exit_0_when_healthy(monkeypatch, capsys):
    code = _run(monkeypatch, FakeBus(present=ALL_RIGHT), ["--bus", "right", "--reads", "5"])
    assert code == 0
    assert "safe to start" in capsys.readouterr().out


def test_exit_1_when_dropping(monkeypatch, capsys):
    code = _run(monkeypatch, FakeBus(present=ALL_RIGHT, fail_ids=[9]),
                ["--bus", "right", "--reads", "5"])
    assert code == 1
    err = capsys.readouterr().err
    assert "REFUSING" in err and "silently" in err


def test_exit_2_when_the_bus_is_absent(monkeypatch, capsys):
    def boom(port, ids):
        raise FileNotFoundError(port)
    monkeypatch.setattr(bus_preflight, "open_bus", boom)
    code = main(["--bus", "right", "--reads", "5"])
    assert code == 2


def test_json_output_is_machine_readable(monkeypatch, capsys):
    code = _run(monkeypatch, FakeBus(present=ALL_RIGHT, fail_ids=[9]),
                ["--bus", "right", "--reads", "4", "--json"])
    assert code == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is False
    (bus,) = payload["buses"]
    assert bus["bus"] == "right"
    assert bus["worst_fail_pct"] == 100.0
    assert any(s["id"] == 9 and s["failures"] == 4 for s in bus["servos"])


# --- the tower: the third silent failure mode ---------------------------------

ALL_LEFT = BUS_SPECS["left"][2]


def scan_left(bus, tower_ref=None, reads=5):
    return scan_bus(bus, "left", "/dev/fake", ALL_LEFT, reads, tower_ref)


def a_tower_at(pan, tilt, tolerance=TOWER_DEFAULT_TOLERANCE_TICKS):
    return TowerReference(pan_ticks=pan, tilt_ticks=tilt,
                          tolerance_ticks=tolerance)


def test_a_tower_still_at_its_calibration_pose_passes():
    bus = FakeBus(present=ALL_LEFT, positions={7: 1600, 8: 2800})
    r = scan_left(bus, a_tower_at(1600, 2800))
    assert r.tower_checked and r.ok()
    assert r.tower_observed == {"pan": 1600, "tilt": 2800}


def test_small_drift_inside_tolerance_is_accepted():
    bus = FakeBus(present=ALL_LEFT, positions={7: 1604, 8: 2795})
    assert scan_left(bus, a_tower_at(1600, 2800)).ok()


def test_a_knocked_tower_fails_and_says_the_camera_model_is_invalid():
    bus = FakeBus(present=ALL_LEFT, positions={7: 1600, 8: 2700})
    r = scan_left(bus, a_tower_at(1600, 2800))
    assert not r.ok()
    reason = " ".join(r.reasons())
    assert "tower tilt moved 100 ticks" in reason
    assert "CameraModel is no longer valid" in reason


def test_an_unchecked_tower_does_not_read_as_a_passed_tower():
    r = scan_left(FakeBus(present=ALL_LEFT))          # no reference given
    assert r.tower_checked is False
    assert r.tower_observed == {}


def test_the_tower_reference_is_ignored_on_a_bus_that_does_not_carry_it():
    """The tower is on the LEFT bus; scanning the right one must not fail."""
    r = scan_right(FakeBus(present=ALL_RIGHT))
    r2 = scan_bus(FakeBus(present=ALL_RIGHT), "right", "/dev/fake", ALL_RIGHT,
                  5, a_tower_at(1600, 2800))
    assert r.ok() and r2.ok()
    assert r2.tower_checked is False


def test_an_unreadable_tower_servo_is_a_failure_not_a_pass():
    bus = FakeBus(present=ALL_LEFT, fail_ids=[8])
    r = scan_left(bus, a_tower_at(1600, 2800))
    assert not r.ok()
    assert "tower tilt (id 8) unreadable" in " ".join(r.reasons())


def test_tower_reference_is_read_from_the_camera_calibration(tmp_path):
    f = tmp_path / "cam.json"
    f.write_text(json.dumps({"pos": [0, 0, 1],
                             "tower": {"pan_ticks": 1600, "tilt_ticks": 2800}}))
    ref = TowerReference.from_calibration(str(f))
    assert (ref.pan_ticks, ref.tilt_ticks) == (1600, 2800)
    assert ref.pan_id == 7 and ref.tilt_id == 8
    assert ref.tolerance_ticks == TOWER_DEFAULT_TOLERANCE_TICKS


def test_a_calibration_without_a_tower_block_is_absent_not_zero(tmp_path):
    """Absent must not silently become "calibrated at tick 0"."""
    f = tmp_path / "cam.json"
    f.write_text(json.dumps({"pos": [0, 0, 1]}))
    assert TowerReference.from_calibration(str(f)) is None


# --- soak ---------------------------------------------------------------------

def test_soak_runs_the_requested_rounds_and_counts_drops():
    calls = {"n": 0}
    slept = []

    def run():
        calls["n"] += 1
        return "dropping" if calls["n"] == 2 else "ok"

    run_count, dropping, unavailable = soak(run, rounds=3, interval=7,
                                            sleep=slept.append,
                                            out=lambda *_: None)
    assert (run_count, dropping, unavailable) == (3, 1, 0)
    # sleeps BETWEEN rounds only — not after the last one
    assert slept == [7, 7]


def test_soak_reports_a_clean_run():
    n, dropping, unavailable = soak(lambda: "ok", rounds=4, interval=0,
                                    sleep=lambda _: None, out=lambda *_: None)
    assert (n, dropping, unavailable) == (4, 0, 0)


def test_soak_counts_unavailability_apart_from_dropping():
    """An unplugged robot or a held port is not a verdict about the bus."""
    seq = iter(["ok", "unavailable", "unavailable", "dropping"])
    n, dropping, unavailable = soak(lambda: next(seq), rounds=4, interval=0,
                                    sleep=lambda _: None, out=lambda *_: None)
    assert (n, dropping, unavailable) == (4, 1, 2)


def test_repeat_exits_1_when_any_round_failed(monkeypatch, capsys):
    monkeypatch.setattr(bus_preflight.time, "sleep", lambda _: None)
    monkeypatch.setattr(bus_preflight, "open_bus",
                        lambda p, i: FakeBus(present=ALL_RIGHT, fail_ids=[9]))
    code = main(["--bus", "right", "--reads", "2", "--repeat", "2",
                 "--interval", "0"])
    assert code == 1
    assert "REFUSING" in capsys.readouterr().err


def test_repeat_exits_0_when_every_round_passed(monkeypatch, capsys):
    monkeypatch.setattr(bus_preflight.time, "sleep", lambda _: None)
    monkeypatch.setattr(bus_preflight, "open_bus",
                        lambda p, i: FakeBus(present=ALL_RIGHT))
    code = main(["--bus", "right", "--reads", "2", "--repeat", "3",
                 "--interval", "0"])
    assert code == 0
    out = capsys.readouterr().out
    assert "3 rounds: 3 clean, 0 dropping, 0 unavailable" in out


def test_a_calibration_without_a_tower_block_is_refused_by_the_cli(tmp_path, capsys):
    f = tmp_path / "cam.json"
    f.write_text(json.dumps({"pos": [0, 0, 1]}))
    code = main(["--bus", "left", "--tower-calib", str(f)])
    assert code == 2
    assert "never recorded" in capsys.readouterr().err


def test_a_disconnected_robot_is_inconclusive_not_a_fault_verdict(monkeypatch,
                                                                  capsys):
    """The exact case that produced a false positive during the first soak."""
    def gone(port, ids):
        raise FileNotFoundError(port)

    monkeypatch.setattr(bus_preflight.time, "sleep", lambda _: None)
    monkeypatch.setattr(bus_preflight, "open_bus", gone)
    code = main(["--bus", "right", "--reads", "2", "--repeat", "3",
                 "--interval", "0"])
    assert code == 2                       # inconclusive, NOT 1
    err = capsys.readouterr().err
    assert "INCONCLUSIVE" in err
    assert "port is exclusive" in err


def test_dropping_outranks_unavailability_in_the_exit_code(monkeypatch, capsys):
    """A real drop must not be masked by rounds that could not open."""
    buses = iter([FakeBus(present=ALL_RIGHT, fail_ids=[9]), None])

    def opener(port, ids):
        bus = next(buses)
        if bus is None:
            raise FileNotFoundError(port)
        return bus

    monkeypatch.setattr(bus_preflight.time, "sleep", lambda _: None)
    monkeypatch.setattr(bus_preflight, "open_bus", opener)
    code = main(["--bus", "right", "--reads", "2", "--repeat", "2",
                 "--interval", "0"])
    assert code == 1
    assert "dropped responses in 1 of 2 rounds" in capsys.readouterr().err


def test_a_single_run_against_an_absent_bus_says_inconclusive(monkeypatch,
                                                              capsys):
    monkeypatch.setattr(bus_preflight, "open_bus",
                        lambda p, i: (_ for _ in ()).throw(FileNotFoundError(p)))
    assert main(["--bus", "right", "--reads", "2"]) == 2
    assert "INCONCLUSIVE" in capsys.readouterr().err
