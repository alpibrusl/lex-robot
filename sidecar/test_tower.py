"""Unit tests for the tower driver's pure helpers and its motion planning.

No hardware: the bus is a fake that records every write, which is enough to
pin the ordering guarantees that matter (goal synced before torque; clamping
applied before anything is commanded).
"""
import pytest

import tower
from tower import CENTRE_TICKS, TowerDriver, clamp_ticks, deg_to_ticks, plan_steps, ticks_to_deg


# ── pure helpers ────────────────────────────────────────────────────────────

def test_centre_tick_is_zero_degrees():
    assert ticks_to_deg(CENTRE_TICKS) == 0.0
    assert deg_to_ticks(0.0) == CENTRE_TICKS


def test_degrees_round_trip():
    for d in (-90, -33.5, 0, 12.25, 90):
        assert ticks_to_deg(deg_to_ticks(d)) == pytest.approx(d, abs=0.1)


def test_quarter_turn_is_a_quarter_of_the_ticks():
    assert deg_to_ticks(90) - CENTRE_TICKS == tower.TICKS_PER_REV // 4


def test_clamp_respects_both_bounds():
    assert clamp_ticks(5000, (1024, 3072)) == 3072
    assert clamp_ticks(-5, (1024, 3072)) == 1024
    assert clamp_ticks(2000, (1024, 3072)) == 2000


def test_plan_steps_never_exceeds_step_size():
    plan = plan_steps(1000, 1097, 15)
    prev = 1000
    for p in plan:
        assert abs(p - prev) <= 15
        prev = p
    assert plan[-1] == 1097


def test_plan_steps_handles_descending_and_noop():
    assert plan_steps(1100, 1070, 15) == [1085, 1070]
    assert plan_steps(500, 500, 15) == [500]


def test_plan_steps_rejects_bad_step():
    with pytest.raises(ValueError):
        plan_steps(0, 10, 0)


# ── the driver, against a fake bus ──────────────────────────────────────────

class FakeBus:
    """Records writes; serves positions from a dict. Mirrors only the private
    ID-based primitives the driver is allowed to use on a shared bus."""
    model_ctrl_table = {"sts3215": {}}

    def __init__(self, positions):
        self.positions = dict(positions)
        self.writes = []          # (register_name, sid, value)
        self._names = {}

    def _write(self, addr, length, sid, value):
        self.writes.append((self._names[addr], sid, value))
        if self._names[addr] == "Goal_Position":
            self.positions[sid] = value

    def _read(self, addr, length, sid):
        """Mirrors lerobot's real contract: (value, comm_result, error).
        An earlier version of this fake returned a bare int, so the suite
        passed while the driver raised TypeError against real hardware."""
        name = self._names[addr]
        if name == "Present_Position":
            return (self.positions[sid], 0, 0)
        if name == "Present_Temperature":
            return (41, 0, 0)
        if name == "Torque_Enable":
            last = [v for n, s, v in self.writes if n == "Torque_Enable" and s == sid]
            return (last[-1] if last else 0, 0, 0)
        return (0, 0, 0)


def fake_driver(pan=1590, tilt=2839, **kw):
    bus = FakeBus({7: pan, 8: tilt})
    addrs = {"Operating_Mode": 1, "Torque_Enable": 2, "Goal_Position": 3,
             "Present_Position": 4, "Present_Temperature": 5}
    bus._names = {a: n for n, a in addrs.items()}
    tower_mod_get_address = lambda table, model, name: (addrs[name], 2)
    import lerobot.motors.motors_bus as mb
    orig = mb.get_address
    mb.get_address = tower_mod_get_address
    try:
        d = TowerDriver(shared_bus=bus, dwell_s=0.0, **kw)
    finally:
        mb.get_address = orig
    return d, bus


def test_requires_exactly_one_of_port_or_bus():
    with pytest.raises(ValueError):
        TowerDriver()
    with pytest.raises(ValueError):
        TowerDriver(shared_bus=object(), port="/dev/null")


def test_construction_sets_position_mode_on_both_servos():
    _, bus = fake_driver()
    modes = [(s, v) for n, s, v in bus.writes if n == "Operating_Mode"]
    assert modes == [(7, 0), (8, 0)]


def test_hold_syncs_goal_before_enabling_torque():
    """Engaging torque against a stale goal would snap the camera. Goal must be
    written first, and it must equal the present position."""
    d, bus = fake_driver(pan=1590, tilt=2839)
    bus.writes.clear()
    d.hold()
    seq = [(n, s, v) for n, s, v in bus.writes if n in ("Goal_Position", "Torque_Enable")]
    assert seq[0] == ("Goal_Position", 7, 1590)
    assert seq[1] == ("Torque_Enable", 7, 1)
    assert seq[2] == ("Goal_Position", 8, 2839)
    assert seq[3] == ("Torque_Enable", 8, 1)


def test_release_disables_torque_on_both():
    d, bus = fake_driver()
    bus.writes.clear()
    d.release()
    assert [(s, v) for n, s, v in bus.writes if n == "Torque_Enable"] == [(7, 0), (8, 0)]


def test_move_to_clamps_to_the_envelope():
    d, bus = fake_driver(pan=1590, pan_limits=(1024, 1700))
    bus.writes.clear()
    d.move_to(pan_ticks=9999)
    goals = [v for n, s, v in bus.writes if n == "Goal_Position" and s == 7]
    assert max(goals) == 1700, "target must be clamped, not commanded raw"


def test_move_to_creeps_rather_than_jumping():
    d, bus = fake_driver(pan=1590, step_ticks=15)
    bus.writes.clear()
    d.move_to(pan_ticks=1700)
    goals = [v for n, s, v in bus.writes if n == "Goal_Position" and s == 7]
    assert goals[0] == 1590, "first write re-states the present position"
    deltas = [abs(b - a) for a, b in zip(goals, goals[1:])]
    assert max(deltas) <= 15
    assert goals[-1] == 1700


def test_move_to_leaves_the_other_axis_alone():
    d, bus = fake_driver()
    bus.writes.clear()
    d.move_to(pan_ticks=1700)
    assert not [w for w in bus.writes if w[1] == 8]


def test_move_to_with_no_targets_is_a_read():
    d, bus = fake_driver()
    bus.writes.clear()
    d.move_to()
    assert not [w for w in bus.writes if w[0] in ("Goal_Position", "Torque_Enable")]


def test_read_reports_ticks_degrees_and_hold_state():
    d, _ = fake_driver(pan=1590, tilt=2839)
    r = d.read()
    assert r["pan_ticks"] == 1590 and r["tilt_ticks"] == 2839
    assert r["pan_deg"] == pytest.approx(-40.25, abs=0.01)
    assert r["held"] is False
    assert d.hold()["held"] is True
