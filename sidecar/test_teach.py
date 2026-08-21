"""Tests for lead-through teaching. No hardware: the interesting logic is the
trajectory handling and, above all, the refusals that stop replay lurching.
"""
import json

import pytest

from teach import (Trajectory, approach_path, max_step, replay, resample, trim_still)


def frames(*rows):
    return [list(r) for r in rows]


# ── max_step ────────────────────────────────────────────────────────────────

def test_max_step_finds_the_worst_joint_of_the_worst_frame():
    f = frames((0, 0), (1, 0), (1, 9), (2, 9))
    assert max_step(f) == pytest.approx(9.0)


def test_max_step_of_a_single_frame_is_zero():
    assert max_step(frames((1, 2, 3))) == 0.0
    assert max_step([]) == 0.0


def test_max_step_ignores_direction():
    assert max_step(frames((10,), (0,))) == pytest.approx(10.0)


# ── trim_still ──────────────────────────────────────────────────────────────

def test_trim_removes_the_reach_and_the_let_go():
    f = frames((0, 0), (0, 0), (0, 0), (5, 0), (10, 0), (10, 0), (10, 0))
    assert trim_still(f) == frames((0, 0), (5, 0), (10, 0))


def test_trim_keeps_a_recording_that_is_all_motion():
    f = frames((0,), (5,), (10,))
    assert trim_still(f) == f


def test_trim_of_a_completely_still_recording_keeps_one_frame():
    """Nothing was taught; do not return an empty trajectory that replays as a
    no-op with no explanation."""
    assert len(trim_still(frames((3,), (3,), (3,)))) == 1


def test_trim_respects_the_threshold():
    f = frames((0,), (0.2,), (0.4,), (9,))
    assert trim_still(f, threshold_deg=0.5) == frames((0.4,), (9,))


def test_trim_of_empty_is_empty():
    assert trim_still([]) == []


# ── approach_path ───────────────────────────────────────────────────────────

def test_approach_never_exceeds_the_step_limit():
    path = approach_path([0, 0], [30, -18], max_step_deg=6.0)
    prev = [0, 0]
    for f in path:
        assert max(abs(a - b) for a, b in zip(f, prev)) <= 6.0 + 1e-9
        prev = f


def test_approach_ends_exactly_on_the_target():
    assert approach_path([0, 0], [30, -18], 6.0)[-1] == pytest.approx([30, -18])


def test_approach_from_the_target_is_a_single_frame():
    assert approach_path([5, 5], [5, 5], 6.0) == [[5, 5]]


def test_approach_rejects_a_nonpositive_step():
    with pytest.raises(ValueError):
        approach_path([0], [10], 0)


# ── resample ────────────────────────────────────────────────────────────────

def test_resample_to_half_rate_halves_the_frames():
    f = frames(*[(i,) for i in range(20)])
    assert len(resample(f, src_fps=20, dst_fps=10)) == pytest.approx(10, abs=1)


def test_resample_preserves_the_endpoints():
    f = frames((0,), (5,), (10,))
    out = resample(f, 10, 30)
    assert out[0] == pytest.approx([0]) and out[-1] == pytest.approx([10])


def test_resample_of_empty_is_empty():
    assert resample([], 10, 20) == []


# ── round trip ──────────────────────────────────────────────────────────────

def test_trajectory_round_trips_through_disk(tmp_path):
    t = Trajectory(20.0, ["a", "b"], frames((1.5, 2.5), (3.5, 4.5)), note="pick")
    p = tmp_path / "t.json"
    t.save(str(p))
    back = Trajectory.load(str(p))
    assert back.fps == t.fps and back.joints == t.joints and back.note == "pick"
    assert back.frames == t.frames


def test_duration_follows_frame_count_and_rate():
    assert Trajectory(20.0, ["a"], frames(*[(0,)] * 40)).duration_s == pytest.approx(2.0)


# ── the refusals, which are the point ───────────────────────────────────────

def test_replay_refuses_an_empty_trajectory():
    r = replay("/dev/null", "x", Trajectory(20.0, ["a"], []))
    assert r["outcome"] == "refused" and "empty" in r["detail"]


def test_replay_refuses_a_discontinuous_trajectory_without_touching_hardware():
    """A dropped frame or a hand slip leaves a jump. Replaying it at the
    recorded rate would fling the arm -- refuse, and say why. Note the port is
    /dev/null: reaching hardware at all would fail the test."""
    t = Trajectory(20.0, ["a"], frames((0,), (1,), (40,)))
    r = replay("/dev/null", "x", t, max_step_deg=6.0)
    assert r["outcome"] == "refused"
    assert "39.0 deg" in r["detail"] and "hand slip" in r["detail"]


def test_replay_accepts_a_smooth_trajectory_up_to_the_limit(monkeypatch):
    """Guard against an off-by-one that would reject a legitimate recording:
    a trajectory exactly at the limit must get PAST the refusal and go on to
    touch hardware. Detected by making the hardware call raise a sentinel."""
    import teach

    class Reached(Exception):
        pass

    monkeypatch.setattr(teach, "_robot", lambda *a, **k: (_ for _ in ()).throw(Reached()))
    t = Trajectory(20.0, ["a"], frames((0,), (6,), (12,)))
    with pytest.raises(Reached):
        teach.replay("/dev/null", "x", t, max_step_deg=6.0)


def test_replay_vetoed_by_the_collision_check_stops_partway(monkeypatch):
    """A taught motion is not automatically a safe one -- the object or the
    other arm may have moved since. Every frame goes through the same guard
    move_arm uses."""
    import teach

    class FakeBus:
        def __init__(self): self.written = 0
        def sync_read(self, *_a, **_k): return {"a": 0.0}
        def sync_write(self, *_a, **_k): self.written += 1
        def enable_torque(self): pass
        def disconnect(self): pass

    class FakeRobot:
        def __init__(self): self.bus = FakeBus()

    fake = FakeRobot()
    monkeypatch.setattr(teach, "_robot", lambda *a, **k: fake)
    monkeypatch.setattr(teach.time, "sleep", lambda *_a: None)
    t = Trajectory(20.0, ["a"], frames((0,), (1,), (2,), (3,)))
    r = teach.replay("/dev/null", "x", t, collision_check=lambda f: ["a vs tower: -5 mm"] if f["a"] >= 2 else [])
    assert r["outcome"] == "denied"
    assert r["frames_sent"] == 2, "must stop at the offending frame, not finish the motion"


def test_resampling_down_makes_steps_bigger_not_slower():
    """Pins the corrected semantics: resample changes frame DENSITY, not speed.
    Halving the rate covers the same motion in half the frames, so each step
    doubles -- which can trip replay's max_step refusal. Use replay(speed=...)
    to go slower."""
    f = [[float(i)] for i in range(21)]          # 1 deg per frame at 20 fps
    coarse = resample(f, src_fps=20, dst_fps=10)
    assert max_step(coarse) > max_step(f)


def test_resampling_up_smooths_the_steps():
    f = [[float(i * 4)] for i in range(11)]      # 4 deg per frame
    fine = resample(f, src_fps=10, dst_fps=40)
    assert max_step(fine) < max_step(f)


def test_recording_frees_the_body_but_keeps_the_gripper_powered(monkeypatch):
    """Freeing everything would mean squeezing the fingers shut by hand while
    also supporting and moving the arm. The gripper stays commandable."""
    import teach

    class FakeBus:
        def __init__(self): self.freed = None
        def disable_torque(self, joints=None): self.freed = joints
        def sync_read(self, *_a, **_k): return {j: 0.0 for j in teach.ARM_JOINTS}
        def disconnect(self): pass

    class FakeRobot:
        def __init__(self): self.bus = FakeBus()

    fake = FakeRobot()
    monkeypatch.setattr(teach, "_robot", lambda *a, **k: fake)
    monkeypatch.setattr(teach.time, "sleep", lambda *_a: None)
    teach.record("/dev/null", "x", seconds=0.0)
    assert fake.bus.freed == teach.BODY_JOINTS
    assert "gripper" not in fake.bus.freed


def test_the_gripper_can_be_freed_explicitly(monkeypatch):
    import teach

    class FakeBus:
        def __init__(self): self.freed = None
        def disable_torque(self, joints=None): self.freed = joints
        def sync_read(self, *_a, **_k): return {j: 0.0 for j in teach.ARM_JOINTS}
        def disconnect(self): pass

    class FakeRobot:
        def __init__(self): self.bus = FakeBus()

    fake = FakeRobot()
    monkeypatch.setattr(teach, "_robot", lambda *a, **k: fake)
    monkeypatch.setattr(teach.time, "sleep", lambda *_a: None)
    teach.record("/dev/null", "x", seconds=0.0, free=teach.ARM_JOINTS)
    assert "gripper" in fake.bus.freed


def test_recording_still_captures_every_joint_including_the_powered_one(monkeypatch):
    """A powered joint is still READ -- the trajectory must contain the gripper
    column so replay can command it."""
    import teach

    class FakeBus:
        def disable_torque(self, joints=None): pass
        def sync_read(self, *_a, **_k): return {j: 1.0 for j in teach.ARM_JOINTS}
        def disconnect(self): pass

    class FakeRobot:
        def __init__(self): self.bus = FakeBus()

    monkeypatch.setattr(teach, "_robot", lambda *a, **k: FakeRobot())
    monkeypatch.setattr(teach.time, "sleep", lambda *_a: None)
    t = teach.record("/dev/null", "x", seconds=0.0)
    assert t.joints == teach.ARM_JOINTS


# ── keeping images, timestamps and poses aligned ────────────────────────────

def test_trim_trajectory_returns_the_original_indices_kept():
    """Image files are named by frame index, so trimming must report WHICH
    original frames survived -- trimming the joints alone would misalign every
    picture from the pose it was taken at."""
    import teach
    t = teach.Trajectory(20.0, ["a"], frames((0,), (0,), (5,), (10,), (10,)))
    kept = teach.trim_trajectory(t)
    assert kept == [1, 2, 3]
    assert t.frames == frames((0,), (5,), (10,))


def test_trim_trajectory_trims_timestamps_to_match_and_rebases_them():
    import teach
    t = teach.Trajectory(20.0, ["a"], frames((0,), (0,), (5,), (10,), (10,)))
    t.timestamps = [0.0, 0.05, 0.10, 0.15, 0.20]
    teach.trim_trajectory(t)
    assert len(t.timestamps) == len(t.frames)
    assert t.timestamps[0] == pytest.approx(0.0)


def test_achieved_fps_is_measured_not_assumed():
    """If capture could not keep up, a dataset stamped with the REQUESTED rate
    would teach a policy the wrong dynamics."""
    import teach
    t = teach.Trajectory(20.0, ["a"], frames(*[(0,)] * 5))
    t.timestamps = [0.0, 0.1, 0.2, 0.3, 0.4]        # actually 10 Hz
    assert t.achieved_fps == pytest.approx(10.0)


def test_achieved_fps_falls_back_to_requested_without_timestamps():
    import teach
    assert teach.Trajectory(20.0, ["a"], frames((0,))).achieved_fps == pytest.approx(20.0)


def test_validate_warns_when_capture_lagged_the_requested_rate():
    import teach
    t = teach.Trajectory(20.0, list(teach.ARM_JOINTS),
                         [[float(i)] * 6 for i in range(20)],
                         task="pick", arm="left", cameras=["head"])
    t.timestamps = [i * 0.1 for i in range(20)]      # 10 Hz, not 20
    assert any("not the requested" in w for w in teach.validate(t)["warnings"])


def test_validate_warns_about_a_state_only_recording():
    import teach
    t = teach.Trajectory(20.0, list(teach.ARM_JOINTS),
                         [[float(i)] * 6 for i in range(20)], task="pick", arm="left")
    assert any("state-only" in w for w in teach.validate(t)["warnings"])
