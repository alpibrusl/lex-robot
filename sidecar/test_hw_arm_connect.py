"""Tests for how a real arm is brought up — _HwArm._connect_without_snapping.

The POLICY under test is an ordering one, and it is a safety property: the
servos must be told where they already are BEFORE torque is engaged. lerobot's
own SOFollower.connect() does not do this (configure()'s `torque_disabled()`
context manager re-enables torque on the way out and nothing writes
Goal_Position), so an arm whose servos still hold the power-up default of 0
would be commanded to the bottom of its encoder the instant it connects.

Measured on the real unit, Raspberry Pi 5, after a fresh power-up: every joint
read Goal_Position=0 while the arms rested limp, the furthest 3046 ticks
(~268 deg) from where it was. tower.py's hold() has always taken this care with
the tower servos; these tests hold the arm path to the same standard.
"""
import pytest

import xlerobot_sidecar as X


class FakeBus:
    """Records the order of operations. Only the calls the connect path is
    allowed to make."""

    def __init__(self, present):
        self.present = dict(present)
        self.calls = []          # ordered (operation, payload)
        self.connected = False

    def connect(self):
        self.connected = True
        self.calls.append(("connect", None))

    def sync_read(self, data_name, motors=None, *, normalize=True, **kw):
        assert self.connected, "read before the bus was connected"
        self.calls.append(("sync_read", (data_name, normalize)))
        return dict(self.present)

    def sync_write(self, data_name, values, *, normalize=True, **kw):
        assert self.connected, "write before the bus was connected"
        self.calls.append(("sync_write", (data_name, dict(values), normalize)))


class FakeFollower:
    def __init__(self, present, cameras=None):
        self.bus = FakeBus(present)
        self.cameras = cameras or {}
        self.configured = False

    def configure(self):
        # Stands in for the real configure(), whose only relevant behaviour
        # here is that it ends by enabling torque.
        self.bus.calls.append(("configure", None))
        self.configured = True


PRESENT = {
    "shoulder_pan": 1507,
    "shoulder_lift": 1050,
    "elbow_flex": 3046,
    "wrist_flex": 2055,
    "wrist_roll": 1538,
    "gripper": 2520,
}


def arm(follower):
    """An _HwArm without running its hardware-touching __init__."""
    a = object.__new__(X._HwArm)
    a.follower = follower
    return a


def test_goal_is_synced_to_present_before_configure_engages_torque():
    f = FakeFollower(PRESENT)
    arm(f)._connect_without_snapping()

    ops = [c[0] for c in f.bus.calls]
    assert ops.index("sync_write") < ops.index("configure"), (
        "Goal_Position must be written before configure() re-enables torque; "
        f"got {ops}"
    )
    written = next(c[1] for c in f.bus.calls if c[0] == "sync_write")
    assert written[0] == "Goal_Position"
    assert written[1] == PRESENT, "the goal written must be exactly where the arm is"


def test_the_sync_happens_in_raw_ticks():
    """Hardware-frame round trip: it must not depend on calibration being
    loaded, or on read and write agreeing about normalisation."""
    f = FakeFollower(PRESENT)
    arm(f)._connect_without_snapping()

    read = next(c[1] for c in f.bus.calls if c[0] == "sync_read")
    write = next(c[1] for c in f.bus.calls if c[0] == "sync_write")
    assert read == ("Present_Position", False)
    assert write[2] is False


def test_the_bus_is_connected_before_anything_is_read():
    f = FakeFollower(PRESENT)
    arm(f)._connect_without_snapping()
    assert f.bus.calls[0][0] == "connect"


def test_configure_still_runs():
    """The sync is an addition to the bring-up, not a replacement for it —
    dropping configure() would leave the servos in whatever mode they woke in."""
    f = FakeFollower(PRESENT)
    arm(f)._connect_without_snapping()
    assert f.configured


def test_cameras_attached_to_the_follower_are_still_connected():
    """The sidecar drives cameras itself, so this is normally empty — but the
    hand-rolled connect path must not silently drop them if it ever isn't."""

    class FakeCam:
        def __init__(self):
            self.connected = False

        def connect(self):
            self.connected = True

    cams = {"head": FakeCam()}
    f = FakeFollower(PRESENT, cameras=cams)
    arm(f)._connect_without_snapping()
    assert cams["head"].connected


def test_a_zero_goal_would_have_been_a_full_scale_slam():
    """Documents the hazard this guards, with the numbers measured on the real
    unit: had the goal been left at the power-up default, connecting would have
    commanded a ~268 degree move on the worst joint."""
    worst = max(PRESENT.values())
    assert worst - 0 > 3000
    assert (worst * 360 / 4096) > 250
