"""Unit tests for xlerobot_sidecar's pure math helpers, the stub-mode
(Tier-1) QR bootstrap round trip, and the display mechanism (which is
tier-independent and thus fully real here, not stubbed) — no lerobot
install, no hardware, no HTTP server needed for any of it. The math helpers
back the real-hardware (Tier 3) control loops (_HwDiffBase.drive,
_HwOmniBase.drive); testing them in isolation is the part of the hardware
seam we *can* verify without a physical XLeRobot.
"""
import math

import pytest

from xlerobot_sidecar import (
    ARM_JOINTS,
    DisplayState,
    XLeRobot,
    _HwDiffBase,
    bearing_and_turn,
    clamp,
    diff_drive_wheel_speeds,
)


def test_clamp_bounds():
    assert clamp(5, 0, 10) == 5
    assert clamp(-1, 0, 10) == 0
    assert clamp(11, 0, 10) == 10


def test_diff_drive_straight_line_wheels_match():
    # Pure forward motion: both wheels spin at the same speed, no turning.
    left, right = diff_drive_wheel_speeds(0.3, 0.0, wheel_radius_m=0.05, track_width_m=0.30)
    assert math.isclose(left, right)
    assert left > 0


def test_diff_drive_in_place_turn_is_symmetric_opposite():
    # Pure rotation: wheels spin at equal and opposite speed.
    left, right = diff_drive_wheel_speeds(0.0, 1.0, wheel_radius_m=0.05, track_width_m=0.30)
    assert math.isclose(left, -right)
    assert right > 0  # CCW (positive omega) -> right wheel forward, left back


def test_diff_drive_wheel_speed_scales_with_radius():
    # Smaller wheel radius -> higher angular speed for the same linear velocity.
    small, _ = diff_drive_wheel_speeds(0.3, 0.0, wheel_radius_m=0.025, track_width_m=0.30)
    large, _ = diff_drive_wheel_speeds(0.3, 0.0, wheel_radius_m=0.05, track_width_m=0.30)
    assert small > large


def test_bearing_and_turn_target_ahead():
    dist, bearing, turn = bearing_and_turn(0.0, 0.0, 0.0, 1.0, 0.0)
    assert math.isclose(dist, 1.0)
    assert math.isclose(bearing, 0.0, abs_tol=1e-9)
    assert math.isclose(turn, 0.0, abs_tol=1e-9)


def test_bearing_and_turn_target_behind_wraps_to_pi():
    dist, bearing, turn = bearing_and_turn(0.0, 0.0, 0.0, -1.0, 0.0)
    assert math.isclose(dist, 1.0)
    assert abs(turn) <= math.pi + 1e-9
    assert math.isclose(abs(turn), math.pi, abs_tol=1e-6)


def test_bearing_and_turn_target_to_the_left_is_positive_turn():
    dist, bearing, turn = bearing_and_turn(0.0, 0.0, 0.0, 0.0, 1.0)
    assert turn > 0  # need to turn CCW (positive) to face +y from heading 0


def test_bearing_and_turn_at_target_keeps_current_heading():
    dist, bearing, turn = bearing_and_turn(1.0, 1.0, 0.7, 1.0, 1.0)
    assert dist == 0.0
    assert bearing == 0.7
    assert turn == 0.0


def test_stub_qr_round_trip():
    # Tier-1 has no display or camera to actually show/scan a code (see
    # XLeRobot.render_qr's docstring) — render_qr's payload comes back out
    # of scan_qr unchanged, the same honest-simulation contract speak/listen
    # use at this tier.
    robot = XLeRobot()
    robot.render_qr("bootstrap-blob-payload")
    assert robot.scan_qr() == {"payload": "bootstrap-blob-payload"}


def test_stub_scan_qr_before_any_render_is_empty():
    robot = XLeRobot()
    assert robot.scan_qr() == {"payload": ""}


def test_display_starts_blank():
    d = DisplayState()
    assert d.to_json() == {"kind": "blank", "content": "", "version": 0}


def test_display_local_file_gets_a_cache_busting_content_url():
    d = DisplayState()
    result = d.set_local_file("image", "/tmp/whatever.png")
    assert result == {"outcome": "reached", "detail": "showing local image file /tmp/whatever.png"}
    assert d.kind == "image"
    assert d.local_path == "/tmp/whatever.png"
    assert d.content == "/display/content?v=1"  # the kiosk page's <img src>


def test_display_remote_url_is_used_directly_no_local_path():
    d = DisplayState()
    d.set_remote("video", "https://example.com/clip.mp4")
    assert d.kind == "video"
    assert d.content == "https://example.com/clip.mp4"
    assert d.local_path is None  # nothing for GET /display/content to serve


def test_display_version_increments_across_every_kind_of_change():
    d = DisplayState()
    d.set_text("hello")
    assert d.version == 1
    d.set_remote("url", "https://example.com")
    assert d.version == 2
    d.clear()
    assert d.version == 3
    assert d.kind == "blank" and d.content == "" and d.local_path is None


def test_show_image_routes_by_source_prefix():
    robot = XLeRobot()
    robot.show_image("https://example.com/cup.jpg")
    assert robot.display.kind == "image"
    assert robot.display.content == "https://example.com/cup.jpg"
    robot.show_image("/tmp/local_cup.jpg")
    assert robot.display.local_path == "/tmp/local_cup.jpg"


def test_show_image_rejects_empty_source():
    robot = XLeRobot()
    assert robot.show_image("")["outcome"] == "stalled"


def test_render_qr_feeds_the_shared_display_on_stub_tier_too():
    # Tier-1 render_qr doesn't touch DisplayState today (no real image is
    # written to feed it) -- confirms that boundary rather than assuming it,
    # so a future change to one doesn't silently break the other unnoticed.
    robot = XLeRobot()
    robot.render_qr("payload")
    assert robot.display.kind == "blank"


def test_read_arm_pose_stub_matches_last_moved_position():
    robot = XLeRobot()
    robot.move_arm("left", 0.3, 0.1, 0.2)
    assert robot.read_arm_pose("left") == {"ok": True, "x": 0.3, "y": 0.1, "z": 0.2}


def test_read_arm_pose_stub_unknown_arm_falls_back_to_left():
    robot = XLeRobot()
    robot.move_arm("left", 0.25, 0.05, 0.15)
    assert robot.read_arm_pose("nonsense") == {"ok": True, "x": 0.25, "y": 0.05, "z": 0.15}


def test_read_arm_pose_stub_defaults_to_origin_before_any_move():
    robot = XLeRobot()
    assert robot.read_arm_pose("right") == {"ok": True, "x": 0.0, "y": 0.0, "z": 0.0}


# ---- grant enforcement (workspace box + grip-force ceiling) ----------------
#
# The default grant is manifests/xlerobot.capsule.json (loaded by absolute
# path relative to this file's location, so it doesn't depend on CWD). One
# test below checks that real file's actual shape loads correctly -- the
# rest set robot._grant directly to a small, controlled dict so the
# enforcement *logic* is tested in isolation from that file's specific
# numbers, which could otherwise change out from under these tests.

_TEST_GRANT = {
    "arms": {
        "left": {
            "workspace_m": [
                {"min": 0.0, "max": 1.0},
                {"min": 0.0, "max": 1.0},
                {"min": 0.0, "max": 1.0},
            ],
            "max_velocity_mps": 0.25,
            "max_force_n": 15.0,
        },
    },
    "grippers": {"left": {"max_grip_force_n": 10.0}},
    "bases": {"base": {"floor_area_m": [{"min": 0.0, "max": 4.0},
                                        {"min": 0.0, "max": 3.0}],
                       "max_speed_mps": 0.5}},
}


def test_read_grant_stub_loads_the_real_default_capsule():
    robot = XLeRobot()
    result = robot.read_grant()
    assert result["ok"] is True
    assert result["arms"]["left"]["workspace_m"][0] == {"min": 0.05, "max": 0.45}
    assert result["grippers"]["left"] == 15.0


def test_move_arm_denied_outside_granted_workspace():
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    result = robot.move_arm("left", 5.0, 0.5, 0.5)  # x=5.0 way outside [0,1]
    assert result["outcome"] == "denied"
    assert "x=5.000" in result["detail"]
    # never applied -- the stub's tracked position is untouched
    assert robot.read_arm_pose("left") == {"ok": True, "x": 0.0, "y": 0.0, "z": 0.0}


def test_move_arm_reached_inside_granted_workspace():
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    result = robot.move_arm("left", 0.5, 0.5, 0.5)
    assert result["outcome"] == "reached"


def test_move_arm_unrestricted_when_no_grant_configured():
    robot = XLeRobot()
    robot._grant = None
    result = robot.move_arm("left", 999.0, 999.0, 999.0)
    assert result["outcome"] == "reached"


def test_grasp_arm_clamps_force_to_granted_max():
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    result = robot.grasp_arm("left", 99.0)  # grant caps left gripper at 10.0N
    assert result["outcome"] == "reached"
    assert "10.0N" in result["detail"]


def test_grasp_arm_unrestricted_when_no_grant_configured():
    robot = XLeRobot()
    robot._grant = None
    result = robot.grasp_arm("left", 20.0)  # under HARD_GRIP_N, no grant to clamp it
    assert result["outcome"] == "reached"
    assert "20.0N" in result["detail"]


def test_read_grant_reports_the_base_bound():
    # A governed program can only respect an envelope it can read.
    robot = XLeRobot()
    result = robot.read_grant()
    assert result["base"]["floor_area_m"][0] == {"min": 0.0, "max": 4.0}
    assert result["base"]["max_speed_mps"] == 0.5


def test_move_base_denied_outside_the_granted_floor_area():
    # The bound was in the capsule from the start but only ever checked on the
    # Lex side, so a direct caller could drive out of the granted room.
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    result = robot.move_base(4.5, 1.5, 0.3)      # x=4.5 outside [0,4]
    assert result["outcome"] == "denied"
    assert "x=4.500 outside granted floor area [0.00,4.00]" in result["detail"]
    assert robot.base["x"] == 0.0 and robot.base["y"] == 0.0   # never applied


def test_move_base_denies_on_either_axis():
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    assert robot.move_base(1.0, -0.5, 0.3)["outcome"] == "denied"
    assert robot.move_base(1.0, 3.5, 0.3)["outcome"] == "denied"


def test_move_base_reached_inside_the_granted_floor_area():
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    result = robot.move_base(2.55, 0.85, 0.3)
    assert result["outcome"] == "reached"
    assert robot.base["x"] == 2.55


def test_move_base_clamps_speed_to_the_granted_max():
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    result = robot.move_base(1.0, 1.0, 2.0)      # grant caps the base at 0.5 m/s
    assert result["outcome"] == "reached"
    assert "0.50m/s" in result["detail"]


def test_move_base_never_amplifies_a_slower_request():
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    assert "0.20m/s" in robot.move_base(1.0, 1.0, 0.2)["detail"]


def test_move_base_unrestricted_when_no_grant_configured():
    robot = XLeRobot()
    robot._grant = None
    result = robot.move_base(999.0, 999.0, 0.3)
    assert result["outcome"] == "reached"


def test_move_base_ignores_a_grant_with_no_base_bound():
    robot = XLeRobot()
    robot._grant = {"arms": {}, "grippers": {}}
    assert robot.move_base(999.0, 999.0, 0.3)["outcome"] == "reached"


def test_move_base_refuses_to_guess_between_two_base_bounds():
    # Two entries and no "base" key: which floor box applies is ambiguous, and
    # guessing wrong means guessing a room. Unbounded and honest beats bounded
    # by an envelope nobody chose.
    robot = XLeRobot()
    robot._grant = {"bases": {"cart_a": {"max_speed_mps": 0.1},
                              "cart_b": {"max_speed_mps": 0.9}}}
    assert robot._base_grant() is None
    assert "0.30m/s" in robot.move_base(1.0, 1.0, 0.3)["detail"]


def test_a_single_differently_named_base_still_binds():
    robot = XLeRobot()
    robot._grant = {"bases": {"cart": {"floor_area_m": [{"min": 0.0, "max": 1.0},
                                                        {"min": 0.0, "max": 1.0}]}}}
    assert robot.move_base(5.0, 0.5, 0.3)["outcome"] == "denied"


def test_hw_base_missing_when_no_base_configured():
    # Mirrors _hw_arm_missing's contract: an arms-only build with no base
    # wired up must refuse honestly, not crash trying to call a method on
    # None (the read_base/move_base bug this guard fixes).
    robot = XLeRobot()
    missing = robot._hw_base_missing()
    assert missing is not None
    assert missing["ok"] is False
    assert "not configured" in missing["detail"]


def test_hw_base_missing_when_base_configured():
    robot = XLeRobot()
    robot._hw_base = object()  # presence is all _hw_base_missing checks for
    assert robot._hw_base_missing() is None


def test_missing_arm_refuses_instead_of_substituting():
    # Partial-build honesty: a request for an unconfigured arm is refused
    # with a named reason — never silently routed to the other physical arm.
    r = XLeRobot()
    assert r._hw_arm_missing("left") is not None  # stub mode: no hw arms at all
    out = r._hw_arm_missing("right")
    assert out["outcome"] == "stalled"
    assert "not configured" in out["detail"]
    r._hw_arms["left"] = object()
    assert r._hw_arm_missing("left") is None
    assert r._hw_arm_missing("right") is not None


# ---- _HwDiffBase's port/shared_bus contract ---------------------------------
#
# The wheels on this hardware family share a physical bus with one arm's own
# servos rather than having a dedicated port (see SIDECAR.md), so _HwDiffBase
# accepts exactly one of port or shared_bus. This validation happens before
# any lerobot import or hardware I/O, so it's testable without a real bus.

def test_hw_diff_base_rejects_neither_port_nor_shared_bus():
    with pytest.raises(ValueError, match="exactly one of port or shared_bus"):
        _HwDiffBase(1, 2, 0.05, 0.30)


def test_hw_diff_base_rejects_both_port_and_shared_bus():
    with pytest.raises(ValueError, match="exactly one of port or shared_bus"):
        _HwDiffBase(1, 2, 0.05, 0.30, port="/dev/ttyACM0", shared_bus=object())


# ---- grant enforcement (taught trajectories) -------------------------------
#
# Replay and go-to-home drive the arm through *joint-space* poses, so the
# grant's Cartesian workspace box only applies through forward kinematics.
# These tests inject a fake arm whose FK is a plain function, so the envelope
# logic is testable with no URDF, no lerobot install and no hardware.

class _FakeFkArm:
    """An arm whose FK is whatever the test says it is.

    `ee` maps a joint tuple to an (x, y, z) end-effector position; anything
    not in the map comes back None, which is how the real _HwArm reports "no
    kinematics available for this pose".
    """

    def __init__(self, ee=None):
        self.ee = ee or {}

    def _forward_kinematics_ee(self, joints):
        key = tuple(round(joints[f"{j}.pos"], 6) for j in ARM_JOINTS)
        return self.ee.get(key)


def _fk_arm(*poses):
    """A fake arm mapping each frame (a 6-tuple of joint angles) to an ee."""
    return _FakeFkArm({tuple(float(v) for v in frame): ee for frame, ee in poses})


def _traj_robot(*poses):
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    robot._hw_arms = {"left": _fk_arm(*poses)}
    return robot


_INSIDE = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
_OUTSIDE = (1.0, 1.0, 1.0, 1.0, 1.0, 1.0)


def test_trajectory_inside_the_granted_workspace_is_allowed():
    robot = _traj_robot((_INSIDE, (0.5, 0.5, 0.5)))
    assert robot._grant_trajectory_violation("left", ARM_JOINTS, [list(_INSIDE)]) is None


def test_trajectory_leaving_the_granted_workspace_is_refused():
    # The recording could be taught anywhere a hand can reach; nothing bounded
    # where it *ended up* until this check existed.
    robot = _traj_robot((_INSIDE, (0.5, 0.5, 0.5)), (_OUTSIDE, (5.0, 0.5, 0.5)))
    detail = robot._grant_trajectory_violation(
        "left", ARM_JOINTS, [list(_INSIDE), list(_OUTSIDE)])
    assert detail is not None
    assert "frame 1 of 2" in detail
    assert "x=5.000" in detail
    assert "[0.00,1.00]" in detail


def test_trajectory_is_checked_whole_before_any_frame_moves():
    # A replay stopped halfway leaves the arm in a pose it was only ever meant
    # to pass through, so the last frame's violation must refuse the first.
    robot = _traj_robot((_INSIDE, (0.5, 0.5, 0.5)), (_OUTSIDE, (0.5, 0.5, 9.0)))
    detail = robot._grant_trajectory_violation(
        "left", ARM_JOINTS, [list(_INSIDE)] * 4 + [list(_OUTSIDE)])
    assert "frame 4 of 5" in detail and "z=9.000" in detail


def test_trajectory_refused_when_kinematics_are_unavailable():
    # Refuse, don't downgrade: a box IS declared, the check cannot run, and
    # replaying anyway would claim an envelope nothing verified.
    robot = _traj_robot()   # empty FK map -> every lookup returns None
    detail = robot._grant_trajectory_violation("left", ARM_JOINTS, [list(_INSIDE)])
    assert "no forward kinematics available" in detail


def test_trajectory_refused_when_the_recording_misses_a_modelled_joint():
    # Padding the gap with zeros would be checking a pose the arm never held.
    robot = _traj_robot((_INSIDE, (0.5, 0.5, 0.5)))
    detail = robot._grant_trajectory_violation("left", ARM_JOINTS[:5], [[0.0] * 5])
    assert "recorded without gripper" in detail


def test_trajectory_unrestricted_when_no_grant_configured():
    robot = _traj_robot()
    robot._grant = None
    assert robot._grant_trajectory_violation("left", ARM_JOINTS, [list(_OUTSIDE)]) is None


def test_trajectory_unrestricted_when_the_grant_does_not_cover_this_arm():
    # _TEST_GRANT bounds the left arm only; the right one has no box, and
    # inventing one would be a bound nobody granted.
    robot = _traj_robot()
    robot._hw_arms["right"] = _fk_arm()
    assert robot._grant_trajectory_violation("right", ARM_JOINTS, [list(_OUTSIDE)]) is None


def test_trajectory_check_is_inert_without_a_configured_arm():
    # No hardware to drive means nothing to bound; the caller's own
    # "arm not configured" answer is the honest one, not a grant denial.
    robot = XLeRobot()
    robot._grant = _TEST_GRANT
    robot._hw_arms = {}
    assert robot._grant_trajectory_violation("left", ARM_JOINTS, [list(_OUTSIDE)]) is None


def test_reset_answers_on_the_same_wire_contract_as_every_other_skill():
    # reset used to return the new state alone, with no `outcome` key -- which
    # src/skills.lex's parse_outcome could only read as Stalled, reporting a
    # successful reset as a failure.
    robot = XLeRobot()
    robot.move_arm("left", 0.3, 0.1, 0.2)
    result = robot.reset()
    assert result["outcome"] == "reached"
    assert result["base"] == {"x": 0.0, "y": 0.0, "heading": 0.0}
    assert result["arms"]["left"] == [0.0] * 6
