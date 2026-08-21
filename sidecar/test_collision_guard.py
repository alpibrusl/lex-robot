"""Tests for move_arm's collision pre-check wiring.

The geometric maths lives in test_collision.py. What matters here is the
POLICY: when the guard runs, what it can see, and -- importantly -- how it
behaves when it cannot do its job.
"""
import os

import pytest

import xlerobot_sidecar as X


def robot(**attrs):
    """An XLeRobot without running its heavy __init__."""
    r = object.__new__(X.XLeRobot)
    r._hw_arms = attrs.pop("hw_arms", {})
    for k, v in attrs.items():
        setattr(r, k, v)
    return r


class StubModel:
    def __init__(self, hits=(), raises=False):
        self.hits, self.raises, self.calls = list(hits), raises, []

    def check(self, **kw):
        self.calls.append(kw)
        if self.raises:
            raise RuntimeError("model exploded")
        return list(self.hits)


class StubArm:
    def __init__(self, joints=None, raises=False):
        self.raises = raises
        self.follower = self
        self._joints = joints or {f"{j}.pos": 0.0 for j in X.ARM_JOINTS}

    def get_observation(self):
        if self.raises:
            raise RuntimeError("bus glitch")
        return dict(self._joints)


ACTION = {f"{j}.pos": 10.0 for j in X.ARM_JOINTS}


def test_no_check_when_the_model_is_unavailable():
    r = robot(_collision=None)
    assert r._collision_check_for("left") is None


def test_disabled_by_env(monkeypatch):
    monkeypatch.setenv("LEX_XLE_COLLISION", "0")
    r = robot()
    assert r._collision_model() is None


def test_colliding_pose_is_reported():
    model = StubModel(hits=["left:wrist vs tower: -20 mm"])
    r = robot(_collision=model)
    assert r._collision_check_for("left")(ACTION) == ["left:wrist vs tower: -20 mm"]


def test_clear_pose_reports_nothing():
    r = robot(_collision=StubModel(hits=[]))
    assert r._collision_check_for("left")(ACTION) == []


def test_the_other_arm_is_included_so_arm_versus_arm_is_checked():
    """Neither arm can see this constraint alone -- that is the whole reason
    the check is built at the robot level rather than inside _HwArm."""
    model = StubModel()
    r = robot(_collision=model, hw_arms={"right": StubArm()})
    r._collision_check_for("left")(ACTION)
    assert set(model.calls[0]) == {"left_joints_deg", "right_joints_deg"}


def test_only_this_arm_when_the_other_is_absent():
    model = StubModel()
    r = robot(_collision=model, hw_arms={})
    r._collision_check_for("left")(ACTION)
    assert set(model.calls[0]) == {"left_joints_deg"}


def test_only_this_arm_when_the_other_cannot_be_read():
    """A bus glitch on the idle arm must not stop the moving arm being checked
    against the tower -- degrade to the checks still possible."""
    model = StubModel()
    r = robot(_collision=model, hw_arms={"right": StubArm(raises=True)})
    r._collision_check_for("left")(ACTION)
    assert set(model.calls[0]) == {"left_joints_deg"}


def test_joint_order_matches_the_model():
    model = StubModel()
    action = {f"{j}.pos": float(i) for i, j in enumerate(X.ARM_JOINTS)}
    r = robot(_collision=model)
    r._collision_check_for("left")(action)
    assert model.calls[0]["left_joints_deg"] == [0.0, 1.0, 2.0, 3.0, 4.0]


def test_unreadable_action_does_not_block_the_move():
    """Fail OPEN, deliberately. This guard is an addition; if it cannot read
    the proposed pose it must not veto motion that worked before it existed."""
    r = robot(_collision=StubModel(hits=["would collide"]))
    assert r._collision_check_for("left")({"nonsense": 1}) == []


def test_model_error_does_not_block_the_move():
    r = robot(_collision=StubModel(raises=True))
    assert r._collision_check_for("left")(ACTION) == []


def test_stall_thresholds_are_configurable_and_sane():
    assert X.STALL_CONFIRM >= 2, "one lagging sample must never be a stall"
    assert X.STALL_ERROR_DEG > 0
