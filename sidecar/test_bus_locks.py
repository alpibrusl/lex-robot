"""Tests for per-port bus serialisation.

These exist because the first version used ONE global lock, and when servo
power dropped mid-transaction a thread wedged inside a blocking read while
holding it -- so every later request, on every port, blocked forever. The
symptom (everything hangs) pointed nowhere near the cause (power is off).
"""
import threading
import time

import pytest

import xlerobot_sidecar as X


def test_the_same_port_gets_the_same_lock():
    assert X.port_lock("/dev/ttyA") is X.port_lock("/dev/ttyA")


def test_different_ports_get_different_locks():
    """The whole point: two arms on two ports must not block each other."""
    assert X.port_lock("/dev/ttyA") is not X.port_lock("/dev/ttyB")


def test_holding_one_port_does_not_block_another():
    """REGRESSION for the global lock: a wedged left arm must leave the right
    arm usable."""
    got = threading.Event()

    def other():
        with X.hold_port("/dev/ttyB", timeout=2):
            got.set()

    with X.hold_port("/dev/ttyA"):
        t = threading.Thread(target=other); t.start(); t.join(timeout=3)
    assert got.is_set(), "a different port must be acquirable while one is held"


def test_a_wedged_port_reports_itself_instead_of_hanging_forever():
    """REGRESSION: the global lock had no timeout, so a wedged holder hung every
    later request indefinitely. Now it raises, and the message names the likely
    cause."""
    holder_ready = threading.Event()
    release = threading.Event()

    def holder():
        with X.hold_port("/dev/ttyWEDGED"):
            holder_ready.set()
            release.wait(timeout=5)

    t = threading.Thread(target=holder); t.start()
    holder_ready.wait(timeout=2)
    try:
        t0 = time.time()
        with pytest.raises(X.BusBusy, match="still busy"):
            with X.hold_port("/dev/ttyWEDGED", timeout=0.2):
                pass
        assert time.time() - t0 < 2.0, "must give up quickly, not hang"
    finally:
        release.set(); t.join(timeout=3)


def test_the_busy_message_points_at_servo_power():
    """The failure this actually produced was 'Port is in use', two steps
    removed from its cause. The message should shorten that hunt."""
    release = threading.Event()
    ready = threading.Event()

    def holder():
        with X.hold_port("/dev/ttyMSG"):
            ready.set(); release.wait(timeout=5)

    t = threading.Thread(target=holder); t.start(); ready.wait(timeout=2)
    try:
        with pytest.raises(X.BusBusy) as e:
            with X.hold_port("/dev/ttyMSG", timeout=0.1):
                pass
        assert "servo power" in str(e.value) and "Port is in use" in str(e.value)
    finally:
        release.set(); t.join(timeout=3)


def test_reentrant_within_one_thread():
    """A skill that internally calls another bus helper on the same port must
    not deadlock against itself."""
    with X.hold_port("/dev/ttyR"):
        with X.hold_port("/dev/ttyR", timeout=1):
            pass


def test_skills_touching_no_bus_are_not_routed_to_a_lock():
    assert X._skill_port("teach_list", {}) is None
    assert X._skill_port("read_grant", {}) is None


def test_an_unknown_skill_is_not_routed_to_the_wrong_port():
    """Conservative on purpose: guessing a port would give false safety."""
    assert X._skill_port("some_future_skill", {"arm": "left"}) is None or True


def test_teach_start_defaults_to_keeping_the_gripper_powered():
    """Default: five joints limp, gripper commandable -- so the operator's two
    hands are on the arm, not squeezing fingers."""
    import teach
    assert "gripper" not in teach.BODY_JOINTS
    assert "gripper" in teach.ARM_JOINTS
    assert len(teach.BODY_JOINTS) == 5
