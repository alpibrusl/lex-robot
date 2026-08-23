"""Tests for the bearing scale drawn onto camera frames.

The POLICY these protect: the numbers printed on the frame are the only thing
standing between a model's "there is a chair on the left" and a heading the
base will actually turn to. A scale that is subtly wrong is worse than none —
the planner would act on it with full confidence. So the geometry is pinned
here, not just the fact that something got drawn.
"""
import math

import pytest

import camera_overlay as ov


def test_centre_angle_lands_on_the_centre_pixel():
    assert ov.angle_to_x(0, 640, 90) == pytest.approx(320.0)


def test_half_fov_lands_on_the_frame_edge():
    # By definition: the edge of the image IS half the field of view.
    assert ov.angle_to_x(45, 640, 90) == pytest.approx(640.0, abs=1e-6)
    assert ov.angle_to_x(-45, 640, 90) == pytest.approx(0.0, abs=1e-6)


def test_mapping_is_tangent_not_linear():
    """Regression against the tempting shortcut.

    Linear would put 30deg at 320 + (30/45)*320 = 533.3. The correct
    rectilinear position is 320 + 320*tan(30deg) = 504.75. About 29px apart on
    a 640px frame — enough to steer a robot past the side of an obstacle.
    """
    correct = ov.angle_to_x(30, 640, 90)
    linear = 320 + (30 / 45) * 320
    assert correct == pytest.approx(320 + 320 * math.tan(math.radians(30)), abs=1e-9)
    assert correct == pytest.approx(504.75, abs=0.05)
    assert abs(correct - linear) > 20


def test_angle_and_pixel_round_trip():
    for a in (-40, -15, 0, 7.5, 33):
        x = ov.angle_to_x(a, 640, 90)
        assert ov.x_to_angle(x, 640, 90) == pytest.approx(a, abs=1e-9)


def test_marks_outside_the_lens_are_dropped_not_clamped():
    """A 60deg mark cannot exist on a 90deg lens (half-FOV is 45).

    Clamping it to the border would stack several angles on the same pixel and
    render a scale that lies. Dropping is the only honest option.
    """
    marks = ov.visible_marks(640, 90)
    angles = [a for _, a in marks]
    assert 60 not in angles and -60 not in angles
    assert 30 in angles and -30 in angles


def test_wider_lens_reveals_more_marks():
    narrow = {a for _, a in ov.visible_marks(640, 60)}
    wide = {a for _, a in ov.visible_marks(640, 140)}
    assert narrow < wide
    assert 60 in wide and 60 not in narrow


def test_marks_increase_left_to_right():
    marks = ov.visible_marks(640, 90)
    xs = [x for x, _ in marks]
    angles = [a for _, a in marks]
    assert xs == sorted(xs), "pixel columns must be ordered"
    assert angles == sorted(angles), "and bearings must increase with them"


def test_fov_changes_where_a_bearing_lands():
    """The whole accuracy warning in one assertion: same angle, different lens,
    different pixel. Get LEX_XLE_CAMERA_FOV wrong and every label is wrong."""
    assert ov.angle_to_x(20, 640, 60) != pytest.approx(ov.angle_to_x(20, 640, 90))


def test_draw_marks_the_frame_without_changing_its_shape():
    np = pytest.importorskip("numpy")
    pytest.importorskip("cv2")
    frame = np.zeros((480, 640, 3), dtype=np.uint8)
    out = ov.draw_bearing_scale(frame.copy(), fov_deg=90)
    assert out.shape == (480, 640, 3)
    assert out.any(), "something should have been drawn"


def test_arm_range_is_opt_in():
    np = pytest.importorskip("numpy")
    pytest.importorskip("cv2")
    base = np.zeros((480, 640, 3), dtype=np.uint8)
    without = ov.draw_bearing_scale(base.copy(), fov_deg=90, show_arm_range=False)
    with_arm = ov.draw_bearing_scale(base.copy(), fov_deg=90, show_arm_range=True)
    assert int(with_arm.astype(int).sum()) > int(without.astype(int).sum())


def test_focal_length_matches_the_pinhole_definition():
    assert ov.focal_px(640, 90) == pytest.approx(320.0)
    assert ov.focal_px(640, 60) == pytest.approx(320.0 / math.tan(math.radians(30)))


def test_fov_from_rotation_recovers_a_known_lens():
    """Synthesise shifts from a known focal length and check we get it back.

    Guards the self-measurement path that produced this unit's 79.3 deg.
    """
    f_true = 386.2
    samples = [(a, f_true * math.tan(math.radians(a)))
               for a in (-10.283, -7.295, 3.252, 6.855, 10.283)]
    fov, f, r2 = ov.fov_from_rotation(samples, 640)
    assert f == pytest.approx(f_true, abs=0.1)
    assert r2 == pytest.approx(1.0, abs=1e-9)
    assert fov == pytest.approx(79.3, abs=0.1)


def test_fov_from_rotation_reports_a_poor_fit_rather_than_hiding_it():
    noisy = [(-10.0, 60.0), (-5.0, 5.0), (5.0, -55.0), (10.0, -10.0)]
    _fov, _f, r2 = ov.fov_from_rotation(noisy, 640)
    assert r2 < 0.9, "inconsistent samples must show up as a bad R^2"


def test_this_units_measured_fov_moves_the_marks_meaningfully():
    """79.3 vs the generic 90 default is not a rounding difference."""
    at_79 = ov.angle_to_x(30, 640, 79.3)
    at_90 = ov.angle_to_x(30, 640, 90)
    assert abs(at_79 - at_90) > 15
