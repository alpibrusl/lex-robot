"""Tests for the joint range probe.

The two tests that matter most are the regressions for how the ad-hoc version
of this lied: a single lagging sample read as a stall, and a fixed-time wait
treated a still-moving joint as settled. Both produced confident, wrong
"mechanical stop" reports on a robot that was in fact free to move.
"""
import pytest

from probe_range import (MECHANICAL_STOP, SOFTWARE_LIMIT, TRAVEL_CAP,
                         RangeProbe, StallDetector, ticks_to_deg)


# ── StallDetector ───────────────────────────────────────────────────────────

def test_single_lagging_sample_is_not_a_stall():
    """REGRESSION: a joint still travelling back from a previous sweep lags by
    hundreds of ticks. The old probe called that a mechanical stop on sample 1."""
    d = StallDetector(error_threshold=35, confirm=3)
    assert d.update(goal=1000, position=700) is False
    assert d.stalled is False


def test_stall_requires_consecutive_samples():
    d = StallDetector(error_threshold=35, confirm=3)
    assert d.update(1000, 700) is False
    assert d.update(1015, 715) is False
    assert d.update(1030, 730) is True          # third consecutive -> stalled
    assert d.stalled is True


def test_streak_resets_when_the_joint_catches_up():
    """A transient bus hiccup or a moment of lag must not accumulate toward a
    verdict once the joint is tracking again."""
    d = StallDetector(error_threshold=35, confirm=3)
    d.update(1000, 700); d.update(1015, 715)
    assert d.update(1030, 1029) is False        # caught up
    assert d.streak == 0
    assert d.update(1045, 700) is False         # streak starts over
    assert d.stalled is False


def test_worst_error_is_retained_for_reporting():
    d = StallDetector()
    d.update(1000, 500); d.update(1000, 990)
    assert d.worst == 500


def test_ticks_to_deg():
    assert ticks_to_deg(4096) == pytest.approx(360.0)
    assert ticks_to_deg(1024) == pytest.approx(90.0)


# ── a fake servo ────────────────────────────────────────────────────────────

class FakeBus:
    """A servo that moves toward its goal at a finite rate, with an optional
    hard stop. Finite speed is the point: an instantly-teleporting fake would
    never have exposed the settle bug."""

    def __init__(self, pos=2000, lo=800, hi=3400, rate=40, wall=None):
        self.pos, self.lo, self.hi, self.rate, self.wall = pos, lo, hi, rate, wall
        self.goal = pos
        self.regs = {"Torque_Limit": 1000, "Torque_Enable": 0,
                     "Present_Load": 30, "Present_Temperature": 40}

    def _tick(self):
        delta = max(-self.rate, min(self.rate, self.goal - self.pos))
        nxt = self.pos + delta
        if self.wall is not None and nxt >= self.wall:
            nxt = self.wall
            self.regs["Present_Load"] = 300
        self.pos = nxt

    def read(self, reg, joint, normalize=False):
        if reg == "Present_Position":
            self._tick()
            return self.pos
        if reg == "Min_Position_Limit": return self.lo
        if reg == "Max_Position_Limit": return self.hi
        if reg == "Goal_Position": return self.goal
        return self.regs.get(reg, 0)

    def write(self, reg, joint, val, normalize=False):
        if reg == "Goal_Position": self.goal = val
        else: self.regs[reg] = val


def probe(bus, **kw):
    kw.setdefault("dwell_s", 0.0)
    kw.setdefault("settle_timeout_s", 5.0)
    return RangeProbe(bus, "shoulder_pan", **kw)


# ── settle ──────────────────────────────────────────────────────────────────

def test_settle_waits_for_actual_arrival_not_elapsed_time():
    """REGRESSION: the joint needs many ticks to cross a long distance. settle_to
    must not return until the encoder says it arrived -- the old code slept a
    fixed 0.9 s and then measured a joint that was still 1000+ ticks away."""
    bus = FakeBus(pos=3400, rate=300)
    p = probe(bus)
    assert bus.pos - 1000 > 2000, "the fake must start far away for this to mean anything"
    assert p.settle_to(1000) is True
    assert abs(bus.pos - 1000) <= p.settle_tol


def test_settle_reports_failure_rather_than_pretending():
    bus = FakeBus(pos=3400, rate=1)            # far too slow to arrive in time
    p = probe(bus, settle_timeout_s=0.5)
    assert p.settle_to(800) is False


class OneWayBus(FakeBus):
    """Moves only upward, so it can never return to home. Models the real
    failure the guard exists for: the second direction must not be measured
    from a position the probe never actually reached."""
    def _tick(self):
        if self.goal > self.pos:
            super()._tick()


def test_direction_not_measured_when_the_joint_cannot_return_home():
    """A probe that cannot reach its start position must report nothing, not a
    number derived from an unknown starting point."""
    bus = OneWayBus(pos=2000, lo=800, hi=3400, rate=200)
    res = probe(bus, travel_cap=600, settle_timeout_s=0.6).run()
    assert res["directions"]["increasing"] is not None   # first pass is fine
    assert res["directions"]["decreasing"] is None       # cannot get home -> not measured


# ── classification ──────────────────────────────────────────────────────────

def test_software_limit_is_not_reported_as_mechanical():
    bus = FakeBus(pos=3300, lo=800, hi=3400, rate=200)
    r = probe(bus).run()["directions"]["increasing"]
    assert r.reason == SOFTWARE_LIMIT
    assert "3400" in r.detail


def test_real_wall_is_reported_as_mechanical():
    bus = FakeBus(pos=2000, lo=800, hi=3400, rate=200, wall=2200)
    r = probe(bus).run()["directions"]["increasing"]
    assert r.reason == MECHANICAL_STOP
    assert r.end <= 2200


def test_free_travel_reports_the_cap_not_a_stop():
    """Hitting our own exploration cap must never masquerade as the robot's limit."""
    bus = FakeBus(pos=2000, lo=0, hi=4095, rate=200)
    r = probe(bus, travel_cap=300).run()["directions"]["increasing"]
    assert r.reason == TRAVEL_CAP


# ── state restoration ───────────────────────────────────────────────────────

def test_torque_limit_and_state_are_restored():
    bus = FakeBus(pos=2000, rate=200)
    bus.regs["Torque_Limit"] = 777
    bus.regs["Torque_Enable"] = 0
    probe(bus, probe_torque=400).run()
    assert bus.regs["Torque_Limit"] == 777
    assert bus.regs["Torque_Enable"] == 0


def test_state_restored_even_when_probing_raises():
    bus = FakeBus(pos=2000, rate=200)
    bus.regs["Torque_Limit"] = 777
    p = probe(bus)
    p.probe_direction = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("bus died"))
    with pytest.raises(RuntimeError):
        p.run()
    assert bus.regs["Torque_Limit"] == 777
    assert bus.regs["Torque_Enable"] == 0


def test_probing_closes_without_undoing_its_own_torque_restore(monkeypatch):
    """Regression: `MotorsBus.disconnect()` disables torque BY DEFAULT.

    `RangeProbe.run()` saves `Torque_Enable`, probes, and restores it in its own
    `finally` — and this module's docstring promises that restore. A bare
    `disconnect()` then wrote `Torque_Enable=0` one line later, silently undoing
    it for any joint that was powered beforehand. The close must only close.
    """
    import probe_range

    closed = {}

    class ClosingBus(FakeBus):
        def __init__(self):
            super().__init__()
            self.regs["Torque_Enable"] = 1        # powered BEFORE probing

        def disconnect(self, disable_torque=True):
            closed["disable_torque"] = disable_torque
            closed["torque_at_close"] = self.regs["Torque_Enable"]

    bus = ClosingBus()
    monkeypatch.setattr(probe_range, "_open_bus", lambda *a, **k: bus)
    monkeypatch.setattr(probe_range.time, "sleep", lambda *_a: None)
    import sys
    monkeypatch.setattr(
        sys, "argv",
        ["probe_range.py", "--port", "/dev/null", "--joint", "shoulder_pan"])

    probe_range.main()

    assert closed["disable_torque"] is False
    # and the restore RangeProbe performed is still standing at close
    assert closed["torque_at_close"] == 1
    assert bus.regs["Torque_Enable"] == 1
