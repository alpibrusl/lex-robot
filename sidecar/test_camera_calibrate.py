"""Tests for the chessboard calibration tool.

The geometry is pure and tested without a camera. The two tests that matter
most are the round trips: `project_world_to_pixel` is pinned against the REAL
`CameraModel.project_to_plane` that will consume its output, and the pose
recovery is pinned against OpenCV's own `solvePnP` with a known ground truth.
A calibration that is self-consistent but wrong is exactly the failure this
tool exists to prevent, so "it agrees with itself" is not a test.
"""

import json
import math

import pytest

from camera_calibrate import (board_frame_to_arm, board_object_points,
                              intrinsics_to_normalized, main, parse_board,
                              pose_to_camera_axes, project_world_to_pixel)


def a_camera(pos, right, down, forward, fx=1.0, fy=1.0, cx0=0.5, cy0=0.5):
    return {"pos": list(pos), "right": list(right), "down": list(down),
            "forward": list(forward), "fx": fx, "fy": fy, "cx0": cx0, "cy0": cy0}


#: A physically realizable overhead camera: right-handed (right x down =
#: forward), looking straight down from 0.6 m. Note this is NOT camera.lex's
#: `overhead_camera` helper, whose axes are mirrored — that helper is an
#: idealisation, and solvePnP produces genuine rotations.
OVERHEAD = a_camera(pos=(0.25, 0.0, 0.6), right=(1, 0, 0), down=(0, -1, 0),
                    forward=(0, 0, -1))


# --- intrinsics ---------------------------------------------------------------

def test_pixel_intrinsics_normalize_by_image_size():
    """camera.lex documents fx/fy in image-width/-height units."""
    K = [[320.0, 0.0, 316.0], [0.0, 240.0, 238.0], [0.0, 0.0, 1.0]]
    n = intrinsics_to_normalized(K, 640, 480)
    assert n == {"fx": 0.5, "fy": 0.5, "cx0": 316.0 / 640, "cy0": 238.0 / 480}


def test_a_centred_principal_point_normalizes_to_a_half():
    K = [[600.0, 0.0, 320.0], [0.0, 600.0, 240.0], [0.0, 0.0, 1.0]]
    n = intrinsics_to_normalized(K, 640, 480)
    assert n["cx0"] == pytest.approx(0.5) and n["cy0"] == pytest.approx(0.5)


# --- pose algebra --------------------------------------------------------------

def test_identity_rotation_puts_the_camera_at_minus_t():
    eye = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
    pos, right, down, forward = pose_to_camera_axes(eye, [0.1, 0.2, 0.3])
    assert pos == pytest.approx([-0.1, -0.2, -0.3])
    assert right == [1, 0, 0] and down == [0, 1, 0] and forward == [0, 0, 1]


def test_camera_axes_are_the_rows_of_the_board_to_camera_rotation():
    R = [[0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]]
    _, right, down, forward = pose_to_camera_axes(R, [0.0, 0.0, 0.0])
    assert right == [0, 1, 0] and down == [0, 0, 1] and forward == [1, 0, 0]


def test_board_to_arm_with_no_yaw_only_translates():
    pos, right, down, forward = board_frame_to_arm(
        [0.0, 0.0, 0.5], [1, 0, 0], [0, -1, 0], [0, 0, -1],
        origin=[0.3, -0.1, 0.0], yaw_deg=0.0)
    assert pos == pytest.approx([0.3, -0.1, 0.5])
    assert right == pytest.approx([1, 0, 0])       # directions unchanged
    assert forward == pytest.approx([0, 0, -1])


def test_board_yaw_rotates_directions_as_well_as_position():
    pos, right, _, _ = board_frame_to_arm(
        [1.0, 0.0, 0.0], [1, 0, 0], [0, -1, 0], [0, 0, -1],
        origin=[0.0, 0.0, 0.0], yaw_deg=90.0)
    assert pos == pytest.approx([0.0, 1.0, 0.0], abs=1e-9)
    assert right == pytest.approx([0.0, 1.0, 0.0], abs=1e-9)


# --- board spec ----------------------------------------------------------------

def test_board_spec_parses_inner_corners():
    assert parse_board("9x6") == (9, 6)


def test_a_square_board_is_refused_because_its_orientation_is_ambiguous():
    with pytest.raises(ValueError, match="NOT.*square|square"):
        parse_board("6x6")


def test_nonsense_board_spec_is_refused():
    with pytest.raises(ValueError):
        parse_board("nine-by-six")


def test_object_points_are_row_major_and_flat():
    pts = board_object_points(3, 2, 0.025)
    assert len(pts) == 6
    assert pts[0] == [0.0, 0.0, 0.0]
    assert pts[1] == [0.025, 0.0, 0.0]
    assert pts[3] == [0.0, 0.025, 0.0]
    assert all(p[2] == 0.0 for p in pts)


# --- forward projection ---------------------------------------------------------

def test_the_point_under_an_overhead_camera_lands_at_frame_centre():
    u, v = project_world_to_pixel(OVERHEAD, [0.25, 0.0, 0.0])
    assert (u, v) == pytest.approx((0.5, 0.5))


def test_a_point_behind_the_camera_is_refused_not_guessed():
    with pytest.raises(ValueError, match="behind the camera"):
        project_world_to_pixel(OVERHEAD, [0.25, 0.0, 1.2])


# --- the round trip that matters: pinned against the real consumer ---------------

def _camera_model_cls():
    pytest.importorskip("lerobot", reason="CameraModel lives in vision_reset_teleop")
    from vision_reset_teleop import CameraModel
    return CameraModel


@pytest.mark.parametrize("world", [
    [0.25, 0.00, 0.0], [0.35, 0.10, 0.0], [0.15, -0.08, 0.0],
])
def test_round_trip_through_the_real_project_to_plane(world):
    """Forward-project a table point, then let the REAL CameraModel invert it."""
    CameraModel = _camera_model_cls()
    u, v = project_world_to_pixel(OVERHEAD, world)
    cam = CameraModel(pos=tuple(OVERHEAD["pos"]), right=tuple(OVERHEAD["right"]),
                      down=tuple(OVERHEAD["down"]), forward=tuple(OVERHEAD["forward"]),
                      fx=OVERHEAD["fx"], fy=OVERHEAD["fy"],
                      cx0=OVERHEAD["cx0"], cy0=OVERHEAD["cy0"])
    assert list(cam.project_to_plane(u, v, 0.0)) == pytest.approx(world, abs=1e-9)


def test_round_trip_holds_for_a_tilted_camera():
    """The overhead case is degenerate; a real head camera is oblique."""
    CameraModel = _camera_model_cls()
    a = math.radians(35.0)
    # The straight-down right-handed frame (right, down, forward) =
    # ((1,0,0), (0,-1,0), (0,0,-1)), rotated about the world x-axis by `a`.
    ca, sa = math.cos(a), math.sin(a)
    cam_d = a_camera(pos=(0.0, -0.4, 0.5),
                     right=(1.0, 0.0, 0.0),
                     down=(0.0, -ca, -sa),
                     forward=(0.0, sa, -ca))
    # orthonormality, else the dot-product inverse is not an inverse at all
    for axis in ("right", "down", "forward"):
        assert sum(c * c for c in cam_d[axis]) == pytest.approx(1.0, abs=1e-12)
    for u_, v_ in (("right", "down"), ("right", "forward"), ("down", "forward")):
        assert sum(cam_d[u_][i] * cam_d[v_][i]
                   for i in range(3)) == pytest.approx(0.0, abs=1e-12)

    world = [0.05, -0.02, 0.0]
    u, v = project_world_to_pixel(cam_d, world)
    cam = CameraModel(pos=tuple(cam_d["pos"]), right=tuple(cam_d["right"]),
                      down=tuple(cam_d["down"]), forward=tuple(cam_d["forward"]),
                      fx=cam_d["fx"], fy=cam_d["fy"],
                      cx0=cam_d["cx0"], cy0=cam_d["cy0"])
    assert list(cam.project_to_plane(u, v, 0.0)) == pytest.approx(world, abs=1e-9)


# --- pose recovery pinned against OpenCV's own solvePnP --------------------------

def test_pose_recovery_matches_a_known_ground_truth():
    """Synthesise a camera pose, project a board, recover it. No hardware."""
    cv2 = pytest.importorskip("cv2")
    np = pytest.importorskip("numpy")

    cols, rows, square = 9, 6, 0.025
    objp = np.array(board_object_points(cols, rows, square), dtype=np.float64)
    K = np.array([[600.0, 0, 320.0], [0, 600.0, 240.0], [0, 0, 1.0]])
    dist = np.zeros(5)

    rvec = np.array([[0.30], [-0.20], [0.10]])
    tvec = np.array([[-0.10], [-0.05], [0.70]])
    img, _ = cv2.projectPoints(objp, rvec, tvec, K, dist)

    ok, rv, tv = cv2.solvePnP(objp.astype(np.float32), img, K, dist)
    assert ok
    R, _ = cv2.Rodrigues(rv)
    pos, right, down, forward = pose_to_camera_axes(R.tolist(), tv.ravel().tolist())

    R_true, _ = cv2.Rodrigues(rvec)
    expected = (-R_true.T @ tvec).ravel()
    assert pos == pytest.approx(list(expected), abs=1e-6)

    # a recovered pose must be an orthonormal frame, or the model is nonsense
    for axis in (right, down, forward):
        assert sum(c * c for c in axis) == pytest.approx(1.0, abs=1e-9)
    assert sum(right[i] * down[i] for i in range(3)) == pytest.approx(0.0, abs=1e-9)


# --- the tool refuses rather than guesses ----------------------------------------

def test_verify_needs_a_point(tmp_path, capsys):
    f = tmp_path / "cam.json"
    f.write_text(json.dumps(OVERHEAD))
    assert main(["verify", "--model", str(f)]) == 2
    assert "at least one --point" in capsys.readouterr().err


def test_verify_flags_a_point_that_falls_outside_the_image(tmp_path, capsys):
    f = tmp_path / "cam.json"
    f.write_text(json.dumps(OVERHEAD))
    assert main(["verify", "--model", str(f), "--point", "9", "9", "0"]) == 0
    assert "OUTSIDE the image" in capsys.readouterr().out


def test_verify_reports_a_point_behind_the_camera_as_refused(tmp_path, capsys):
    f = tmp_path / "cam.json"
    f.write_text(json.dumps(OVERHEAD))
    assert main(["verify", "--model", str(f), "--point", "0.25", "0", "1.2"]) == 0
    assert "REFUSED" in capsys.readouterr().out
