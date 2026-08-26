"""Unit tests for the scripted teleoperator's trajectory math.

No lerobot hardware and no robot needed — this is the part of the
record-without-a-human seam that can be verified in isolation, the same way
test_xlerobot_hw.py covers the sidecar's pure helpers.
"""
from pathlib import Path

from scripted_teleop import BODY, JOINTS, ScriptedArmTeleop, ScriptedArmTeleopConfig

WAYPOINTS = str(Path(__file__).parent / "waypoints_pick_place.json")
FPS = 30


def _teleop(**kw):
    cfg = ScriptedArmTeleopConfig(waypoints_path=WAYPOINTS, **kw)
    t = ScriptedArmTeleop(cfg)
    t.connect()
    return t


def _sample(t, cycles=3):
    """Walk a deterministic clock across whole cycles, collecting actions.

    get_action() reads the clock itself, so the clock has to be REPLACED rather
    than nudged via `_t0`: rewinding `_t0` by i/FPS off a fresh perf_counter()
    leaves every frame a few microseconds *past* its nominal phase, by a margin
    that varies per call. That shifted where a ramp got sampled relative to its
    peak, which is what made this file flaky (#187).

    The teleop takes its clock from `self._now`, so this replaces that one
    instance's clock rather than patching the `time` module — nothing outside
    this teleop sees a stopped clock.
    """
    clock = [0.0]
    t._now = lambda: clock[0]
    t._t0 = 0.0
    out = []
    for i in range(int(t.cycle_s * FPS) * cycles):
        clock[0] = i / FPS
        out.append(t.get_action())
    return out


def _worst_body_step(samples):
    return max(
        abs(b[k] - a[k])
        for a, b in zip(samples, samples[1:])
        for k in a
        if k != "gripper.pos"
    )


def _peak_body_step(t, jitter):
    """The fastest single-frame body move this trajectory can command.

    A segment covering `d` units in `move_s` peaks at 1.5*d/move_s, because
    smoothstep's peak speed is 1.5x its average; per frame that is /FPS. A
    sampled step can only be smaller (mean value theorem). Jitter displaces a
    flagged waypoint by up to `jitter` units in either direction, so it can
    lengthen a segment by that much at each jitter-flagged end.
    """
    bound = 0.0
    prev = t._steps[-1]                   # a cycle starts from where it ended
    for step in t._steps:
        slack = jitter * (bool(prev.get("jitter")) + bool(step.get("jitter")))
        for j in BODY:
            d = abs(step["pose"][j] - prev["pose"][j]) + slack
            bound = max(bound, 1.5 * d / float(step.get("move_s", 1.0)) / FPS)
        prev = step
    return bound


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
    Baking the offset into the waypoint target keeps the path continuous.

    The bound is interpolation's own peak speed, not the un-jittered
    trajectory's: displacing a waypoint away from its neighbour genuinely
    lengthens that segment, and the ramp covers it in the same move_s. On the
    shipped trajectory a +2.7 draw on `traverse` (seeds 8, 9 and 10) outruns the
    un-jittered worst step by 4.8% — smooth motion, not a discontinuity, which
    is why `jittered <= plain` was never a sound assertion and passed only
    because the old test pinned seed=1. The old bug's
    single-frame `jitter`-sized hop (3.0 units, ~5x this bound) is what has to
    stay caught, so sweep seeds rather than trusting one lucky draw.
    """
    jitter = 3.0
    # Seeds 8-10 are the ones that actually draw the lengthening offset on
    # `traverse` and exceed the un-jittered worst step, so a sweep that stops
    # short of them never exercises the case this bound exists for.
    for seed in range(12):
        t = _teleop(jitter=jitter, seed=seed)
        worst = _worst_body_step(_sample(t))
        assert worst <= _peak_body_step(t, jitter), f"seed={seed}"

    plain = _teleop(jitter=0.0)
    assert _worst_body_step(_sample(plain)) <= _peak_body_step(plain, 0.0)


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
