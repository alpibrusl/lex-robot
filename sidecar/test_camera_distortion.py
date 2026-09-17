"""Lens distortion: the Python model, OpenCV, and src/camera.lex must agree.

There are two independent implementations of this projection in the repo --
`src/camera.lex` and `vision_reset_teleop.CameraModel` -- and a third, forward
form in `camera_calibrate.project_world_to_pixel`. They are only useful if they
produce the same numbers, so these tests pin all three against each other and
against OpenCV, using this unit's own MEASURED coefficients rather than
invented ones.
"""
import math

import pytest

from camera_calibrate import project_world_to_pixel
from vision_reset_teleop import CameraModel

# calibration/head_intrinsics_mac_640x480.pooled.json, 117 views at 640x480.
MEASURED = dict(fx=0.54517, fy=0.72347, cx0=0.534, cy0=0.52051,
                k1=0.0919, k2=-0.1347, k3=0.0435, p1=0.00024, p2=-0.00114)
OVERHEAD = dict(pos=(0.25, 0.0, 0.6), right=(1.0, 0.0, 0.0),
                down=(0.0, 1.0, 0.0), forward=(0.0, 0.0, -1.0))


def cam(**over):
    return CameraModel(**{**OVERHEAD, **MEASURED, **over})


def test_zero_distortion_is_the_identity():
    c = cam(k1=0.0, k2=0.0, k3=0.0, p1=0.0, p2=0.0)
    for xd, yd in ((0.0, 0.0), (0.3, -0.2), (-0.8, 0.45)):
        assert c.undistort(xd, yd) == (xd, yd)


def test_distortion_vanishes_at_the_principal_point():
    # r = 0 kills every radial and tangential term. If this ever fails, the
    # model has picked up an offset it should not have.
    x, y = cam().undistort(0.0, 0.0)
    assert (x, y) == (0.0, 0.0)


def test_undistort_inverts_the_forward_model():
    c = cam()
    for x, y in ((0.2, 0.1), (-0.6, 0.4), (0.65, 0.52)):
        r2 = x * x + y * y
        radial = 1 + c.k1 * r2 + c.k2 * r2 * r2 + c.k3 * r2 * r2 * r2
        xd = x * radial + 2 * c.p1 * x * y + c.p2 * (r2 + 2 * x * x)
        yd = y * radial + c.p1 * (r2 + 2 * y * y) + 2 * c.p2 * x * y
        xr, yr = c.undistort(xd, yd)
        assert math.isclose(xr, x, abs_tol=1e-9), (x, xr)
        assert math.isclose(yr, y, abs_tol=1e-9), (y, yr)


def test_matches_opencv_undistort_points():
    cv2 = pytest.importorskip("cv2")
    np = pytest.importorskip("numpy")
    c = cam()
    K = np.eye(3)                       # already normalized coordinates
    dist = np.array([c.k1, c.k2, c.p1, c.p2, c.k3], float)
    for u, v in ((0.5, 0.5), (0.9, 0.5), (0.9, 0.9), (0.1, 0.85)):
        xd, yd = (u - c.cx0) / c.fx, (v - c.cy0) / c.fy
        mine = c.undistort(xd, yd)
        ref = cv2.undistortPoints(np.array([[[xd, yd]]], float), K, dist).reshape(2)
        assert math.isclose(mine[0], ref[0], abs_tol=1e-7), (u, v, mine, ref)
        assert math.isclose(mine[1], ref[1], abs_tol=1e-7), (u, v, mine, ref)


@pytest.mark.parametrize("u,v,x_mm,y_mm", [
    (0.534, 0.52051, 250, 0),      # principal point: agrees with the pinhole
    (0.9, 0.9, 649, 311),          # pinhole would say (653, 315) -- 5.7 mm out
    (0.1, 0.85, -222, 270),        # pinhole would say (-228, 273) -- 6.7 mm out
])
def test_agrees_with_camera_lex_examples(u, v, x_mm, y_mm):
    """The same cases `src/camera.lex`'s project_to_plane_mm examples assert.

    Two implementations of one model in two languages; this is what stops them
    drifting apart silently.
    """
    p = cam().project_to_plane(u, v, 0.0)
    assert round(p[0] * 1000) == x_mm
    assert round(p[1] * 1000) == y_mm


def test_forward_projection_is_the_inverse_of_the_ray():
    """project_world_to_pixel must undo project_to_plane, distortion included.

    `verify` uses it to ask whether a calibration predicts reality, so if it
    skipped distortion it would measure the pinhole model against a distorted
    lens and report an error that is really its own.
    """
    c = cam()
    model = {**OVERHEAD, **MEASURED}
    model = {k: (list(v) if isinstance(v, tuple) else v) for k, v in model.items()}
    for u, v in ((0.6, 0.55), (0.9, 0.9), (0.15, 0.8)):
        world = c.project_to_plane(u, v, 0.0)
        ru, rv = project_world_to_pixel(model, world)
        assert math.isclose(ru, u, abs_tol=1e-6), (u, ru)
        assert math.isclose(rv, v, abs_tol=1e-6), (v, rv)
