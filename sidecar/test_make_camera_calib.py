"""Tests for scripts/make_camera_calib.py.

The property that matters is not "does it emit JSON" — it is that it CANNOT
emit a calibration nobody checked. A wrong CameraModel makes project_to_plane
return confident world positions that no downstream code can tell are nonsense
(lex-robot#150 risk 3), so the refusal path is the feature.
"""
import importlib.util
import math
import pathlib

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "mcc", pathlib.Path(__file__).resolve().parent.parent / "scripts" / "make_camera_calib.py")
mcc = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(mcc)


OVERHEAD = {"pos": [0.25, 0.0, 0.6], "right": [1, 0, 0], "down": [0, 1, 0],
            "forward": [0, 0, -1], "fx": 1.0, "fy": 1.0, "cx0": 0.5, "cy0": 0.5}


def test_projection_matches_camera_lex_documented_example():
    """The tool must do the SAME maths as src/camera.lex, or validating with it
    proves nothing. These are camera.lex's own asserted examples."""
    x, y, z = mcc.project(OVERHEAD, 0.62, 0.55, 0.0)
    assert (round(x * 1000), round(y * 1000), round(z * 1000)) == (322, 30, 0)
    x, y, z = mcc.project(OVERHEAD, 0.5, 0.5, 0.0)
    assert (round(x * 1000), round(y * 1000), round(z * 1000)) == (250, 0, 0)


def test_a_plane_behind_the_camera_is_refused_not_extrapolated():
    with pytest.raises(ValueError):
        mcc.project(OVERHEAD, 0.5, 0.5, 1.0)     # plane above an overhead camera


def test_normalized_focals_follow_ray_directions_algebra():
    """fx = f_px/width, fy = f_px/height — the convention ray_direction implies.
    Getting this wrong scales every bearing."""
    a = _args(focal_px=348.4, width=640, height=480)
    cam = mcc.build(a)
    assert cam["fx"] == pytest.approx(348.4 / 640, abs=1e-6)
    assert cam["fy"] == pytest.approx(348.4 / 480, abs=1e-6)


def test_position_is_the_sourced_urdf_offset_not_a_guess():
    cam = mcc.build(_args())
    # head tilt joint (-0.178, 0, 1.16815) minus left arm base (-0.135, 0.133, 0.760)
    assert cam["pos"] == [-0.043, -0.133, 0.4082]


def test_the_two_arms_differ_only_in_y():
    left = mcc.build(_args(arm="left"))["pos"]
    right = mcc.build(_args(arm="right"))["pos"]
    assert left[0] == right[0] and left[2] == right[2]
    assert left[1] == -right[1]


def test_zero_tilt_offset_gives_a_level_camera():
    cam = mcc.build(_args(tilt_ticks=2523, tilt_zero=2523))
    assert cam["forward"][2] == pytest.approx(0.0, abs=1e-9), "level means no z component"


def test_tilting_down_points_the_optical_axis_downward():
    cam = mcc.build(_args(tilt_ticks=2523 + 512, tilt_zero=2523))   # +45 deg
    assert cam["forward"][2] == pytest.approx(-math.sin(math.radians(45)), abs=1e-6)


def test_the_two_handedness_conventions_are_mirrors_of_each_other():
    """The trap this tool exists to surface: camera.lex's overhead_camera and a
    physically-derived level camera disagree by a left-right flip, and nothing
    in the pipeline detects it."""
    phys = mcc.build(_args(handedness="physical"))["down"]
    over = mcc.build(_args(handedness="overhead"))["down"]
    assert phys == [pytest.approx(-x) for x in over]


def test_every_field_carries_provenance():
    prov = mcc.build(_args())["_provenance"]
    for key in ("fx_fy", "cx0_cy0", "pos", "orientation", "handedness"):
        assert prov[key], f"{key} must say where its value came from"
    assert prov["validated"] is None, "unchecked calibrations must say so"


def test_provenance_admits_the_principal_point_is_assumed():
    assert "ASSUMED" in mcc.build(_args())["_provenance"]["cx0_cy0"]


def test_provenance_warns_that_the_zeroes_are_operator_supplied():
    o = mcc.build(_args())["_provenance"]["orientation"]
    assert "OPERATOR-SUPPLIED" in o


def _args(**over):
    class A:
        arm = "left"
        pan_ticks = 1547
        tilt_ticks = 3394
        pan_zero = 1547
        tilt_zero = 2523
        focal_px = mcc.MEASURED_F_PX
        width, height = 640, 480
        cx0 = cy0 = 0.5
        handedness = "physical"
    a = A()
    for k, v in over.items():
        setattr(a, k, v)
    return a
