"""Unit tests for the scripted teleoperator's trajectory math.

No lerobot hardware and no robot needed — this is the part of the
record-without-a-human seam that can be verified in isolation, the same way
test_xlerobot_hw.py covers the sidecar's pure helpers.
"""
import time
from pathlib import Path

from scripted_teleop import JOINTS, ScriptedArmTeleop, ScriptedArmTeleopConfig

WAYPOINTS = str(Path(__file__).parent / "waypoints_pick_place.json")
FPS = 30


def _teleop(**kw):
    cfg = ScriptedArmTeleopConfig(waypoints_path=WAYPOINTS, **kw)
    t = ScriptedArmTeleop(cfg)
    t.connect()
    return t


def _sample(t, cycles=3):
    """Walk a deterministic clock across whole cycles, collecting actions."""
    out = []
    for i in range(int(t.cycle_s * FPS) * cycles):
        t._t0 = time.perf_counter() - i / FPS
        out.append(t.get_action())
    return out


def test_action_features_match_so101_keys():
    assert list(_teleop().action_features) == [f"{j}.pos" for j in JOINTS]


def test_cycle_duration_is_sum_of_move_and_hold():
    t = _teleop()
    expected = sum(s.get("move_s", 1.0) + s.get("hold_s", 0.0) for s in t._steps)
    assert abs(t.cycle_s - expected) < 1e-9


def test_actions_stay_in_normalized_range():
    for a in _sample(_teleop(jitter=3.0)):
        for k, v in a.items():
            lo, hi = (0.0, 100.0) if k == "gripper.pos" else (-100.0, 100.0)
            assert lo <= v <= hi, f"{k}={v} out of range"


def test_joint_limits_clamp_beyond_waypoints():
    # the shipped trajectory dips to shoulder_lift=-20; the clamp must hold at -15
    vals = [a["shoulder_lift.pos"] for a in _sample(_teleop(joint_limits={"shoulder_lift": [-15, 15]}))]
    assert min(vals) >= -15.0 - 1e-6
    assert max(vals) <= 15.0 + 1e-6


def test_jitter_varies_per_cycle_but_is_seed_reproducible():
    a = _teleop(jitter=3.0, seed=7)
    assert a._jittered_poses(0) != a._jittered_poses(1)          # episodes differ
    b = _teleop(jitter=3.0, seed=7)
    assert a._jittered_poses(3) == b._jittered_poses(3)          # same seed reproduces


def test_zero_jitter_leaves_waypoints_untouched():
    t = _teleop(jitter=0.0)
    assert t._jittered_poses(0) == [s["pose"] for s in t._steps]


def test_body_joints_are_continuous_across_cycle_boundaries():
    """Regression: jitter used to be gated per-segment and added to the
    interpolated output, which stepped the command by up to `jitter` units in
    a single frame when the trajectory crossed into an unjittered waypoint.
    Baking the offset into the waypoint target keeps the path continuous."""
    jittered = _sample(_teleop(jitter=3.0, seed=1))
    plain = _sample(_teleop(jitter=0.0))

    def worst_body_step(samples):
        return max(
            abs(b[k] - a[k])
            for a, b in zip(samples, samples[1:])
            for k in a
            if k != "gripper.pos"
        )

    # Jitter must not introduce motion the un-jittered trajectory doesn't have.
    assert worst_body_step(jittered) <= worst_body_step(plain) + 1e-6


def test_gripper_ramp_is_the_only_fast_axis():
    """The trajectory's sharpest move is the gripper closing (60->8 in 0.8s).
    Documented so that lowering it is a deliberate waypoint-timing decision."""
    samples = _sample(_teleop(jitter=3.0))
    steps = {
        k: max(abs(b[k] - a[k]) for a, b in zip(samples, samples[1:]))
        for k in samples[0]
    }
    assert max(steps, key=steps.get) == "gripper.pos"
    assert max(steps[k] for k in steps if k != "gripper.pos") < steps["gripper.pos"]
