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


# ── whose collision is it ───────────────────────────────────────────────────
#
# Found on the real unit (2026-10-02): the LEFT arm, resting where the
# geometry model wrongly put it inside the tray, made every move of the RIGHT
# arm come back "denied: left:... vs cart tray". The idle arm's own problem
# says nothing about the motion being checked.

from collision import Collision  # noqa: E402


def test_the_idle_arms_own_collision_does_not_veto_this_arm():
    model = StubModel(hits=[Collision("left:wrist_link->gripper_link", "cart tray", -0.068)])
    r = robot(_collision=model, hw_arms={"left": StubArm()})
    assert r._collision_check_for("right")(ACTION) == []


def test_this_arms_collision_still_vetoes():
    hit = Collision("right:wrist_link->gripper_link", "tower", -0.02)
    r = robot(_collision=StubModel(hits=[hit]), hw_arms={"left": StubArm()})
    assert r._collision_check_for("right")(ACTION) == [hit]


def test_arm_versus_arm_vetoes_either_arm():
    # The pair is named left-first whichever arm is moving.
    hit = Collision("left:gripper_link", "right:gripper_link", -0.01)
    r = robot(_collision=StubModel(hits=[hit]), hw_arms={"left": StubArm(), "right": StubArm()})
    assert r._collision_check_for("right")(ACTION) == [hit]
    assert r._collision_check_for("left")(ACTION) == [hit]


def test_an_unexpected_hit_shape_is_judged_not_waved_through():
    # Plain strings are what the stubs above return; a filter that only knew
    # Collision would raise, and an exception there must never mean "allow".
    r = robot(_collision=StubModel(hits=["right:wrist vs tower: -20 mm"]))
    assert r._collision_check_for("right")(ACTION) == ["right:wrist vs tower: -20 mm"]
    assert r._collision_check_for("left")(ACTION) == []
