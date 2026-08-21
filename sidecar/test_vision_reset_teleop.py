"""Tests for the vision self-reset loop: the projection port, the refusal
paths, and the self-resetting place target. No camera, no robot, no model.

The projection cases are lifted verbatim from src/camera.lex's own inline
examples, so this file fails if the Python port ever drifts from the Lex
implementation it mirrors.
"""
import json
import os
from pathlib import Path

import numpy as np
import pytest

from vision_reset_teleop import CameraModel, VisionResetTeleop, VisionResetTeleopConfig

HERE = Path(__file__).parent
TEMPLATE = str(HERE / "waypoints_vision_reset.json")
CALIB = str(HERE / "camera_calib_example.json")


def overhead(pos=(0.25, 0.0, 0.6)) -> CameraModel:
    """camera.lex's `overhead_camera` helper."""
    return CameraModel(pos=pos, right=(1.0, 0.0, 0.0), down=(0.0, 1.0, 0.0),
                       forward=(0.0, 0.0, -1.0), fx=1.0, fy=1.0, cx0=0.5, cy0=0.5)


def mm(v):
    return tuple(round(x * 1000) for x in v)


# ── the projection must agree with src/camera.lex ───────────────────────────

def test_projection_matches_camera_lex_offset_example():
    # camera.lex: project_to_plane_mm(overhead_camera({0.25,0,0.6}), 0.62, 0.55, 0.0)
    #             => Ok({ x_mm: 322, y_mm: 30, z_mm: 0 })
    assert mm(overhead().project_to_plane(0.62, 0.55, 0.0)) == (322, 30, 0)


def test_projection_matches_camera_lex_centre_example():
    # => Ok({ x_mm: 250, y_mm: 0, z_mm: 0 })
    assert mm(overhead().project_to_plane(0.5, 0.5, 0.0)) == (250, 0, 0)


def test_projection_refuses_plane_behind_camera():
    # camera.lex returns Err("the calibrated plane is behind the camera ray")
    with pytest.raises(ValueError, match="behind the camera ray"):
        overhead().project_to_plane(0.5, 0.5, 1.0)


def test_projection_refuses_ray_parallel_to_plane():
    # camera.lex's fourth example: a camera whose forward is horizontal
    cam = CameraModel(pos=(0.0, 0.0, 0.5), right=(0.0, -1.0, 0.0), down=(0.0, 0.0, -1.0),
                      forward=(1.0, 0.0, 0.0), fx=1.0, fy=1.0, cx0=0.5, cy0=0.5)
    with pytest.raises(ValueError, match="parallel to the calibrated plane"):
        cam.project_to_plane(0.5, 0.5, 0.0)


def test_calibration_example_file_loads_and_matches_overhead():
    cam = CameraModel.from_json(CALIB)
    assert mm(cam.project_to_plane(0.62, 0.55, 0.0)) == (322, 30, 0)


# ── the teleop ──────────────────────────────────────────────────────────────

class FakeKin:
    """Stands in for placo: a self-consistent FK/IK pair, so solve_joints'
    convergence loop terminates on the first iteration. Joint values are a
    scaled copy of the target, so different targets give different poses."""
    def inverse_kinematics(self, seed, pose, position_weight=1.0, orientation_weight=0.0):
        x, y, z = pose[:3, 3]
        return np.array([x * 100.0, y * 100.0, z * 100.0, 0.0, 0.0])

    def forward_kinematics(self, q):
        T = np.eye(4)
        T[:3, 3] = np.array([q[0] / 100.0, q[1] / 100.0, q[2] / 100.0])
        return T


class NeverConvergesKin(FakeKin):
    """FK that never matches the request, to exercise the non-convergence path."""
    def forward_kinematics(self, q):
        T = np.eye(4)
        T[:3, 3] = np.array([99.0, 99.0, 99.0])
        return T


def _teleop(**kw):
    kw.setdefault("urdf_path", "unused-in-tests")
    cfg = VisionResetTeleopConfig(waypoints_path=TEMPLATE, camera_calib_path=CALIB, **kw)
    t = VisionResetTeleop(cfg)
    t._kin = FakeKin()
    return t


def test_requires_calibration_and_urdf():
    with pytest.raises(ValueError, match="camera_calib_path"):
        VisionResetTeleop(VisionResetTeleopConfig(waypoints_path=TEMPLATE, urdf_path="x"))
    with pytest.raises(ValueError, match="urdf_path"):
        VisionResetTeleop(VisionResetTeleopConfig(waypoints_path=TEMPLATE, camera_calib_path=CALIB))


def test_failed_detection_holds_home_pose_rather_than_guessing():
    t = _teleop()
    t.detect_world_pose = lambda: (_ for _ in ()).throw(ValueError("not found"))
    poses = t._poses_for_cycle(0)
    assert len(poses) == len(t._steps)
    assert all(p == t._home for p in poses), "a failed detection must not produce a trajectory"


def test_failed_ik_holds_home_pose():
    t = _teleop()
    t.detect_world_pose = lambda: (0.25, 0.0, 0.0)
    t.solve_joints = lambda xyz, seed: (_ for _ in ()).throw(RuntimeError("no solution"))
    assert all(p == t._home for p in t._poses_for_cycle(0))


def test_place_target_is_self_resetting_and_inside_the_region():
    region = [[0.20, 0.30], [-0.10, 0.10]]
    seen = set()
    for cycle in range(6):
        t = _teleop(place_region=region, seed=99)
        t.detect_world_pose = lambda: (0.25, 0.0, 0.0)
        t._poses_for_cycle(cycle)
        x, y, z = t._last_place
        assert region[0][0] <= x <= region[0][1]
        assert region[1][0] <= y <= region[1][1]
        seen.add((round(x, 6), round(y, 6)))
    assert len(seen) > 1, "the drop target must move between episodes -- that IS the self-reset"


def test_place_target_is_seed_reproducible():
    def place(seed):
        t = _teleop(seed=seed)
        t.detect_world_pose = lambda: (0.25, 0.0, 0.0)
        t._poses_for_cycle(4)
        return t._last_place
    assert place(11) == place(11)
    assert place(11) != place(12)


def test_gripper_values_come_from_the_template():
    t = _teleop()
    t.detect_world_pose = lambda: (0.25, 0.0, 0.0)
    poses = t._poses_for_cycle(0)
    template = [s["pose"]["gripper"] for s in t._steps]
    assert [p["gripper"] for p in poses] == [float(g) for g in template]


def test_pick_and_place_phases_resolve_to_different_joint_targets():
    t = _teleop()
    t.detect_world_pose = lambda: (0.10, 0.05, 0.0)
    poses = t._poses_for_cycle(0)
    names = [s["name"] for s in t._steps]
    pick = poses[names.index("descend_pick")]
    place = poses[names.index("descend_place")]
    assert pick != place, "pick and place must not collapse to the same pose"


def test_confidence_floor_refuses_a_weak_detection(monkeypatch):
    import vision_reset_teleop as m

    class FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self):
            return json.dumps({"found": True, "cx": 0.5, "cy": 0.5,
                               "w": 0.1, "h": 0.1, "confidence": 0.42}).encode()

    monkeypatch.setattr(m.urllib.request, "urlopen", lambda *a, **k: FakeResp())
    t = _teleop(min_confidence=0.9)
    t._grabber = lambda: np.zeros((48, 64, 3), dtype=np.uint8)
    with pytest.raises(ValueError, match="below floor"):
        t.detect_world_pose()


def test_detection_flows_through_projection_to_world(monkeypatch):
    import vision_reset_teleop as m

    class FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self):
            return json.dumps({"found": True, "cx": 0.62, "cy": 0.55,
                               "w": 0.1, "h": 0.1, "confidence": 0.95}).encode()

    monkeypatch.setattr(m.urllib.request, "urlopen", lambda *a, **k: FakeResp())
    t = _teleop(min_confidence=0.6, plane_z=0.0)
    t._grabber = lambda: np.zeros((48, 64, 3), dtype=np.uint8)
    assert mm(t.detect_world_pose()) == (322, 30, 0)


def test_ik_that_never_converges_drops_the_episode():
    """A target the solver cannot reach must not yield a trajectory that
    misses the object -- the episode is dropped and the arm holds home."""
    t = _teleop()
    t._kin = NeverConvergesKin()
    t.detect_world_pose = lambda: (0.25, 0.0, 0.0)
    assert all(p == t._home for p in t._poses_for_cycle(0))


def test_solve_joints_raises_with_a_diagnostic_when_out_of_reach():
    t = _teleop(ik_max_iters=3)
    t._kin = NeverConvergesKin()
    with pytest.raises(ValueError, match="did not converge"):
        t.solve_joints((0.25, 0.0, 0.0), [0.0] * 5)


# ── the real placo path, when a URDF is available ───────────────────────────

REAL_URDF = os.environ.get("LEX_XLE_URDF_PATH")


@pytest.mark.skipif(not REAL_URDF, reason="set LEX_XLE_URDF_PATH to exercise real placo IK")
def test_real_ik_converges_and_round_trips():
    """Regression for the single-step solve: lerobot calls placo's solver once,
    which is a differential step, not a solution. solve_joints must iterate."""
    from lerobot.model.kinematics import RobotKinematics
    from scripted_teleop import BODY as B

    t = _teleop(urdf_path=REAL_URDF, ik_tolerance_m=0.002)
    t._kin = None                                   # use the real thing
    kin = RobotKinematics(urdf_path=REAL_URDF, target_frame_name="gripper_frame_link", joint_names=B)

    truth = np.array([10.0, -20.0, 25.0, 5.0, 0.0])
    target_xyz = tuple(kin.forward_kinematics(truth)[:3, 3])

    sol = t.solve_joints(target_xyz, [0.0] * 5)
    reached = kin.forward_kinematics(np.array([sol[j] for j in B]))
    assert np.linalg.norm(reached[:3, 3] - np.array(target_xyz)) <= 0.002


@pytest.mark.skipif(not REAL_URDF, reason="set LEX_XLE_URDF_PATH to exercise real placo IK")
def test_real_ik_refuses_an_unreachable_target():
    t = _teleop(urdf_path=REAL_URDF, ik_max_iters=15)
    t._kin = None
    with pytest.raises(ValueError, match="did not converge"):
        t.solve_joints((5.0, 5.0, 5.0), [0.0] * 5)   # metres away — far out of reach
