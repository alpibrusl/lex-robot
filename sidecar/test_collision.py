"""Tests for the collision model.

Most of this exercises the distance math against cases with a known answer,
because that is the part that must be exactly right: everything the model
concludes rests on it. The model-level tests use synthetic geometry rather than
the real robot_geometry.json, whose numbers are estimates.
"""
import math

import numpy as np
import pytest

from collision import (ARM_FRAMES, ArmMount, Capsule, RobotCollisionModel,
                       capsule_clearance, capsule_plane_clearance,
                       point_segment_distance, segment_segment_distance)


# ── point/segment ───────────────────────────────────────────────────────────

def test_point_segment_perpendicular():
    assert point_segment_distance((0, 2, 0), (-1, 0, 0), (1, 0, 0)) == pytest.approx(2.0)


def test_point_segment_clamps_beyond_the_end():
    """Not the perpendicular distance to the infinite line -- the segment ends."""
    assert point_segment_distance((5, 0, 0), (-1, 0, 0), (1, 0, 0)) == pytest.approx(4.0)


def test_point_segment_degenerate_segment_is_point_distance():
    assert point_segment_distance((3, 4, 0), (0, 0, 0), (0, 0, 0)) == pytest.approx(5.0)


# ── segment/segment ─────────────────────────────────────────────────────────

def test_parallel_segments():
    assert segment_segment_distance((0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0)) == pytest.approx(1.0)


def test_crossing_segments_touch():
    d = segment_segment_distance((-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0))
    assert d == pytest.approx(0.0, abs=1e-9)


def test_skew_segments():
    """Classic skew case: along x at z=0, along y at z=1 -> distance is 1."""
    d = segment_segment_distance((-1, 0, 0), (1, 0, 0), (0, -1, 1), (0, 1, 1))
    assert d == pytest.approx(1.0)


def test_segments_that_only_miss_because_they_are_finite():
    """REGRESSION for treating segments as infinite lines: as infinite lines
    these cross, so an unclamped implementation returns 0."""
    d = segment_segment_distance((0, 0, 0), (1, 0, 0), (5, -1, 0), (5, 1, 0))
    assert d == pytest.approx(4.0)


def test_both_segments_degenerate():
    assert segment_segment_distance((0, 0, 0), (0, 0, 0), (3, 4, 0), (3, 4, 0)) == pytest.approx(5.0)


def test_one_segment_degenerate_matches_point_distance():
    d = segment_segment_distance((2, 2, 0), (2, 2, 0), (-1, 0, 0), (1, 0, 0))
    assert d == pytest.approx(point_segment_distance((2, 2, 0), (-1, 0, 0), (1, 0, 0)))


def test_distance_is_symmetric():
    a, b = ((0, 0, 0), (1, 2, 3)), ((4, 0, 1), (2, 5, 0))
    assert segment_segment_distance(*a, *b) == pytest.approx(segment_segment_distance(*b, *a))


# ── capsules ────────────────────────────────────────────────────────────────

def test_capsule_clearance_subtracts_both_radii():
    c1 = Capsule((0, 0, 0), (1, 0, 0), 0.1)
    c2 = Capsule((0, 1, 0), (1, 1, 0), 0.2)
    assert capsule_clearance(c1, c2) == pytest.approx(1.0 - 0.3)


def test_capsule_clearance_goes_negative_when_interpenetrating():
    c1 = Capsule((0, 0, 0), (1, 0, 0), 0.4)
    c2 = Capsule((0, 0.5, 0), (1, 0.5, 0), 0.4)
    assert capsule_clearance(c1, c2) == pytest.approx(-0.3)


def test_capsule_plane_clearance_uses_the_lower_end_and_the_radius():
    c = Capsule((0, 0, 0.5), (1, 0, 0.2), 0.05)
    assert capsule_plane_clearance(c, 0.0) == pytest.approx(0.15)


def test_capsule_below_plane_is_negative():
    c = Capsule((0, 0, 0.02), (1, 0, 0.02), 0.05)
    assert capsule_plane_clearance(c, 0.0) == pytest.approx(-0.03)


# ── mounting transform ──────────────────────────────────────────────────────

def test_mount_translates():
    m = ArmMount((1, 2, 3), 0.0)
    assert m.transform((1, 0, 0)) == pytest.approx((2, 2, 3))


def test_mount_yaw_rotates_about_vertical():
    m = ArmMount((0, 0, 0), 90.0)
    assert m.transform((1, 0, 0)) == pytest.approx((0, 1, 0), abs=1e-9)


def test_mount_yaw_leaves_height_alone():
    m = ArmMount((0, 0, 0), 37.0)
    assert m.transform((1, 2, 0.5))[2] == pytest.approx(0.5)


# ── the model, on synthetic geometry ────────────────────────────────────────

class FakeFK:
    """Stands in for placo: a straight arm along +x, one point per frame, so the
    resulting capsule chain is trivially predictable."""
    def __init__(self, spacing=0.1):
        self.spacing = spacing
        self.index = 0

    def forward_kinematics(self, q):
        T = np.eye(4)
        T[:3, 3] = np.array([self.index * self.spacing, 0.0, 0.0])
        return T


def synthetic_model(**kw):
    m = RobotCollisionModel(
        mounts={"left": ArmMount((0, 0.3, 0), 0.0), "right": ArmMount((0, -0.3, 0), 0.0)},
        link_radii={"default": 0.02},
        tower=kw.pop("tower", None),
        tray_z=kw.pop("tray_z", None),
        margin=kw.pop("margin", 0.01),
    )
    for i, f in enumerate(ARM_FRAMES):
        fk = FakeFK(); fk.index = i
        m._fk[f] = fk
    return m


ZERO = [0.0] * 5


def test_arm_capsules_form_a_chain_in_the_robot_frame():
    m = synthetic_model()
    caps = m.arm_capsules("left", ZERO)
    assert len(caps) == len(ARM_FRAMES) - 1
    assert caps[0].a == pytest.approx((0.0, 0.3, 0.0))       # mount offset applied
    for c1, c2 in zip(caps, caps[1:]):
        assert c1.b == pytest.approx(c2.a)                    # contiguous


def test_clear_pose_reports_nothing():
    m = synthetic_model(tower=Capsule((0, 0, 0), (0, 0, 0.5), 0.04, "tower"), tray_z=-1.0)
    assert m.check(ZERO, ZERO) == []


def test_arm_through_the_tower_is_caught():
    """The arms run along +x at y=+0.3/-0.3; put the tower on top of the left one."""
    m = synthetic_model(tower=Capsule((0.3, 0.3, -0.5), (0.3, 0.3, 0.5), 0.05, "tower"))
    hits = m.check(left_joints_deg=ZERO)
    assert hits, "an arm passing through the mast must be reported"
    assert all(h.b == "tower" for h in hits)
    assert hits[0].clearance < 0


def test_arm_below_the_tray_is_caught():
    m = synthetic_model(tray_z=0.1)                # arms sit at z=0, below the tray
    hits = m.check(left_joints_deg=ZERO)
    assert hits and all(h.b == "cart tray" for h in hits)


def test_arm_versus_arm_is_caught_when_they_overlap():
    m = RobotCollisionModel(
        mounts={"left": ArmMount((0, 0.01, 0), 0.0), "right": ArmMount((0, -0.01, 0), 0.0)},
        link_radii={"default": 0.02}, tower=None, tray_z=None, margin=0.01)
    for i, f in enumerate(ARM_FRAMES):
        fk = FakeFK(); fk.index = i; m._fk[f] = fk
    hits = m.check(ZERO, ZERO)
    assert hits, "arms 20 mm apart with 20 mm radii must collide"
    assert any("left:" in h.a and "right:" in h.b for h in hits)


def test_arms_far_apart_do_not_collide():
    m = synthetic_model()
    assert m.check(ZERO, ZERO) == []


def test_margin_reports_near_misses():
    """A pose that clears by less than the margin is still refused -- grazing
    the mast is not success."""
    tower = Capsule((0.3, 0.36, -0.5), (0.3, 0.36, 0.5), 0.02, "tower")
    tight = synthetic_model(tower=tower, margin=0.0)
    loose = synthetic_model(tower=tower, margin=0.05)
    assert tight.check(left_joints_deg=ZERO) == []
    assert loose.check(left_joints_deg=ZERO), "margin must catch a near miss"


def test_worst_collision_is_reported_first():
    m = synthetic_model(tray_z=0.5)     # everything is deep below the tray
    hits = m.check(left_joints_deg=ZERO)
    assert hits == sorted(hits, key=lambda h: h.clearance)


def test_checking_one_arm_alone_skips_arm_versus_arm():
    m = RobotCollisionModel(
        mounts={"left": ArmMount((0, 0, 0), 0.0), "right": ArmMount((0, 0, 0), 0.0)},
        link_radii={"default": 0.02}, tower=None, tray_z=None, margin=0.01)
    for i, f in enumerate(ARM_FRAMES):
        fk = FakeFK(); fk.index = i; m._fk[f] = fk
    assert m.check(left_joints_deg=ZERO) == []      # coincident arms, but only one given
    assert m.check(ZERO, ZERO), "both given -> the overlap must be found"


def test_the_mounting_links_are_not_flagged_against_the_tray():
    """REGRESSION: the base plate and shoulder are bolted to the tray, so they
    sit within a capsule radius of it at EVERY pose. Checking them made the
    guard fire on every pose once the radii were widened -- which, with a deny
    verdict, would have refused all motion."""
    m = synthetic_model(tray_z=0.0)
    caps = m.arm_capsules("left", ZERO)
    assert min(caps[1].a[2], caps[1].b[2]) - caps[1].radius < 0.0, "fixture must actually be near the tray"
    hits = [h for h in m.check(left_joints_deg=ZERO) if h.b == "cart tray"]
    assert not any(h.a == caps[0].name or h.a == caps[1].name for h in hits)


def test_links_beyond_the_mount_are_still_checked_against_the_tray():
    m = synthetic_model(tray_z=0.5)          # everything well below the tray
    hits = [h.a for h in m.check(left_joints_deg=ZERO) if h.b == "cart tray"]
    caps = m.arm_capsules("left", ZERO)
    assert caps[2].name in hits, "a link that can be driven into the tray must still be caught"
