"""Unit tests for xlerobot_sidecar's pure math helpers, the stub-mode
(Tier-1) QR bootstrap round trip, and the display mechanism (which is
tier-independent and thus fully real here, not stubbed) — no lerobot
install, no hardware, no HTTP server needed for any of it. The math helpers
back the real-hardware (Tier 3) control loops (_HwDiffBase.drive,
_HwOmniBase.drive); testing them in isolation is the part of the hardware
seam we *can* verify without a physical XLeRobot.
"""
import math

from xlerobot_sidecar import DisplayState, XLeRobot, bearing_and_turn, clamp, diff_drive_wheel_speeds


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
