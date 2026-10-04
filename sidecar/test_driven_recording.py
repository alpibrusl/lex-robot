"""Recording while the arm is DRIVEN by the keyboard, not guided by hand.

A move holds the arm's bus lock for its whole duration, so a recorder that
needed the lock for every sample would record nothing while the arm moves --
the only part of a demonstration that matters. These tests drive the recorder
against a fake bus whose lock the test holds, standing in for a move in flight.
No hardware, no lerobot calls.
"""
import itertools
import threading
import time

import numpy as np
import pytest

import teach
import xlerobot_sidecar as X

_ports = itertools.count()


class _Bus:
    def __init__(self, pose):
        self.pose = dict(pose)
        self.freed = []

    def sync_read(self, register):
        assert register == "Present_Position"
        return dict(self.pose)

    def disable_torque(self, joints):
        self.freed.append(list(joints))


class _Arm:
    def __init__(self, pose):
        self.follower = type("F", (), {})()
        self.follower.config = type("C", (), {"port": f"/dev/fake-driven-{next(_ports)}"})()
        self.follower.bus = _Bus(pose)


class _Cam:
    def capture(self):
        return np.zeros((8, 8, 3), dtype=np.uint8)


POSE = {j: float(i) for i, j in enumerate(X.ARM_JOINTS)}


@pytest.fixture
def rig(monkeypatch, tmp_path):
    monkeypatch.setenv("LEX_XLE_TEACH_DIR", str(tmp_path))
    monkeypatch.setattr(X, "USE_HW", True)
    arm = _Arm(POSE)
    monkeypatch.setattr(X.ROBOT, "_hw_arms", {"left": arm}, raising=False)
    monkeypatch.setattr(X.ROBOT, "_hw_cameras", {"head": _Cam()}, raising=False)
    monkeypatch.setattr(X, "_JOINT_TAP", {})
    return X._TeachRecorder(), arm


def _record(rec, seconds=0.3, **kw):
    res = rec.start("left", kw.pop("name", "d1"), "pick up the object", [], 50.0, 5.0, **kw)
    assert res["ok"], res
    time.sleep(seconds)
    return rec.stop(keep_still=True)


def test_driven_leaves_the_torque_on_and_tags_the_recording(rig):
    rec, arm = rig
    res = rec.start("left", "d1", "t", [], 50.0, 5.0, driven=True)
    assert res["free"] == [] and "torque stays on" in res["detail"]
    time.sleep(0.1)
    rec.stop(keep_still=True)
    assert arm.follower.bus.freed == []
    assert "keyboard" in teach.Trajectory.load(str(teach.library_dir() / "d1.json")).tags


def test_hand_guided_recording_still_frees_the_body_joints(rig):
    rec, arm = rig
    rec.start("left", "h1", "t", [], 50.0, 5.0)
    time.sleep(0.1)
    rec.stop(keep_still=True)
    assert arm.follower.bus.freed == [list(teach.BODY_JOINTS)]


def test_driven_reads_the_bus_when_nothing_is_moving(rig):
    rec, _ = rig
    out = _record(rec, driven=True)
    assert out["frames"] > 3
    traj = teach.Trajectory.load(str(teach.library_dir() / "d1.json"))
    assert all(f == [POSE[j] for j in X.ARM_JOINTS] for f in traj.frames)
    assert not any("move loop" in w for w in out["warnings"])


def test_a_move_in_flight_does_not_stop_the_recording(rig):
    # The test holds the bus lock, as move_to does, and taps the pose the way
    # its loop does. Frames must keep coming, from the tap.
    rec, arm = rig
    moving = {j: 50.0 + i for i, j in enumerate(X.ARM_JOINTS)}
    stop = threading.Event()

    def move():
        with X.hold_port(arm.follower.config.port):
            while not stop.is_set():
                X.tap_joints("left", moving)
                time.sleep(0.02)

    t = threading.Thread(target=move)
    t.start()
    time.sleep(0.05)
    try:
        out = _record(rec, driven=True, seconds=0.4)
    finally:
        stop.set(); t.join()
    traj = teach.Trajectory.load(str(teach.library_dir() / "d1.json"))
    assert out["frames"] > 3
    assert all(f == [moving[j] for j in X.ARM_JOINTS] for f in traj.frames)
    assert any("move loop's last reading" in w for w in out["warnings"])


def test_no_fresh_pose_means_no_frame_rather_than_a_stale_one(rig, monkeypatch):
    rec, arm = rig
    monkeypatch.setattr(X, "DRIVEN_TAP_MAX_AGE_S", 0.05)
    X.tap_joints("left", {j: 99.0 for j in X.ARM_JOINTS})
    time.sleep(0.1)                          # now older than the allowed age
    with X.hold_port(arm.follower.config.port):
        res = rec.start("left", "d1", "t", [], 50.0, 5.0, driven=True)
        assert res["ok"]
        time.sleep(0.3)
        status = rec.status()
        out = rec.stop(keep_still=True)
    assert status["frames"] == 0 and status["skipped"] > 3
    assert out["recorded_frames"] == 0


def test_a_partial_tap_is_not_a_pose(rig):
    rec, arm = rig
    X.tap_joints("left", {"elbow_flex": 12.0})        # one joint only
    with X.hold_port(arm.follower.config.port):
        rec.start("left", "d1", "t", [], 50.0, 5.0, driven=True)
        time.sleep(0.2)
        status = rec.status()
        rec.stop(keep_still=True)
    assert status["frames"] == 0 and status["skipped"] > 0


def test_skipped_ticks_are_reported_as_a_warning(rig):
    rec, arm = rig
    stop = threading.Event()

    def move():                                    # holds the lock, taps late
        with X.hold_port(arm.follower.config.port):
            time.sleep(0.15)
            while not stop.is_set():
                X.tap_joints("left", POSE)
                time.sleep(0.02)

    t = threading.Thread(target=move); t.start()
    time.sleep(0.02)
    try:
        out = _record(rec, driven=True, seconds=0.5)
    finally:
        stop.set(); t.join()
    assert any("ticks had no fresh pose" in w for w in out["warnings"])


def test_every_frame_has_its_image_even_when_ticks_are_skipped(rig):
    # frame i must still mean image i: a skipped tick writes neither.
    rec, arm = rig
    stop = threading.Event()

    def move():
        with X.hold_port(arm.follower.config.port):
            time.sleep(0.15)
            while not stop.is_set():
                X.tap_joints("left", POSE)
                time.sleep(0.02)

    t = threading.Thread(target=move); t.start()
    time.sleep(0.02)
    try:
        out = _record(rec, driven=True, seconds=0.5)
    finally:
        stop.set(); t.join()
    images = sorted((teach.library_dir() / "d1.frames" / "head").glob("*.jpg"))
    assert out["recorded_frames"] > 0
    assert [p.stem for p in images] == [f"{i:06d}" for i in range(out["recorded_frames"])]


def test_the_recorder_does_not_hold_the_bus_while_reading_cameras(rig):
    # A held lock would stall the move that is trying to run. The bus lock is
    # an RLock, so the probe must come from ANOTHER thread -- the recorder's own
    # thread can always re-take it, which would make this pass whatever it does.
    rec, arm = rig
    seen = []
    lock = X.port_lock(arm.follower.config.port)

    def other_thread_can_take_it():
        got = []

        def probe():
            ok = lock.acquire(blocking=False)
            if ok:
                lock.release()        # an RLock must be released by the thread that took it
            got.append(ok)

        t = threading.Thread(target=probe)
        t.start(); t.join()
        return got[0]

    class _ProbeCam:
        def capture(self):
            seen.append(other_thread_can_take_it())
            return np.zeros((8, 8, 3), dtype=np.uint8)

    X.ROBOT._hw_cameras["head"] = _ProbeCam()
    _record(rec, driven=True, seconds=0.2)
    assert seen and all(seen)


# ---- the hooks that feed the tap ---------------------------------------------

def test_go_to_reports_the_pose_after_every_step():
    class _B:
        def __init__(self):
            self.p = {"a": 0.0, "b": 0.0}

        def sync_read(self, reg):
            return dict(self.p)

        def sync_write(self, reg, vals):
            self.p.update(vals)

        def enable_torque(self):
            pass

    seen = []
    out = teach.go_to(_B(), ["a", "b"], [10.0, 0.0], max_step_deg=5.0, period_s=0.0,
                      on_state=seen.append)
    assert out["outcome"] == "reached"
    assert [round(s["a"]) for s in seen] == [5, 10]


def test_go_to_without_on_state_reads_the_bus_no_more_than_before():
    class _B:
        reads = 0

        def sync_read(self, reg):
            _B.reads += 1
            return {"a": 0.0}

        def sync_write(self, reg, vals):
            pass

        def enable_torque(self):
            pass

    teach.go_to(_B(), ["a"], [10.0], max_step_deg=5.0, period_s=0.0)
    assert _B.reads == 1


def test_tap_merges_joints_and_requires_all_of_them(monkeypatch):
    monkeypatch.setattr(X, "_JOINT_TAP", {})
    X.tap_joints("right", {"shoulder_pan.pos": 1.0, "elbow_flex": 2.0, "bogus": 9.0})
    assert X.latest_joints("right", 5.0) is None            # incomplete
    X.tap_joints("right", {j: 3.0 for j in X.ARM_JOINTS if j not in ("shoulder_pan", "elbow_flex")})
    got = X.latest_joints("right", 5.0)
    assert got["shoulder_pan"] == 1.0 and got["elbow_flex"] == 2.0 and "bogus" not in got
    assert X.latest_joints("left", 5.0) is None            # another arm's tap is not ours


def test_tap_expires(monkeypatch):
    monkeypatch.setattr(X, "_JOINT_TAP", {})
    X.tap_joints("left", {j: 1.0 for j in X.ARM_JOINTS})
    time.sleep(0.06)
    assert X.latest_joints("left", 0.03) is None
    assert X.latest_joints("left", 5.0) is not None


def test_teach_start_skill_passes_driven_through(monkeypatch):
    seen = {}
    monkeypatch.setattr(X.TEACH, "start", lambda *a, **k: seen.update(args=a) or {"ok": True})
    X._handle_skill("teach_start", {"arm": "left", "name": "n", "task": "t", "driven": True})
    assert seen["args"][-1] is True
    X._handle_skill("teach_start", {"arm": "left", "name": "n", "task": "t"})
    assert seen["args"][-1] is False
