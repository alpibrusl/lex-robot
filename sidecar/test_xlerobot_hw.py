"""Unit tests for xlerobot_sidecar's pure math helpers — no lerobot install,
no hardware, no HTTP server needed. These back the real-hardware (Tier 3)
control loops (_HwDiffBase.drive, _HwOmniBase.drive); testing them in
isolation is the part of the hardware seam we *can* verify without a
physical XLeRobot.
"""
import math

from xlerobot_sidecar import bearing_and_turn, clamp, diff_drive_wheel_speeds


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
