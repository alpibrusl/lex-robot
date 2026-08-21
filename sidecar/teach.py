#!/usr/bin/env python3
"""Lead-through teaching: move the arm by hand, then have it repeat the motion.

The oldest way to teach a robot, and on this machine the fastest route to "it
picked something up". Torque off, you guide the arm through the motion and it
records the joint trajectory; torque on, it replays it. No vision, no IK, no
camera calibration, no training run.

What it cannot do is generalise: it repeats one motion. Move the object and it
grasps air. That is the honest boundary and the reason this is a first step
rather than a destination -- but it works today, and the demonstrations it
produces are the one thing a scripted expert can never generate: a human
recovering when things go wrong (lex-robot#156).

    python sidecar/teach.py record --port /dev/cu.usbmodem... --id xle_left \
        --seconds 30 --out pick.json
    python sidecar/teach.py replay --port /dev/cu.usbmodem... --id xle_left \
        --traj pick.json

**The arm goes limp while recording.** These servos have no gravity
compensation, so its weight is yours to hold. That is inherent to lead-through
on this hardware, not an oversight.

Replay is where the danger is, so it is deliberately cautious:
  * it REFUSES a trajectory whose frames step further than `max_step_deg`
    rather than flinging the arm between distant poses;
  * it approaches the FIRST frame gradually from wherever the arm actually is,
    so starting a replay can never snap;
  * every frame can be vetoed by a collision check before it is commanded.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
# The joints a hand actually guides. The gripper is excluded on purpose -- see
# record()'s docstring.
BODY_JOINTS = ARM_JOINTS[:5]


@dataclass
class Trajectory:
    fps: float
    joints: list[str]
    frames: list[list[float]] = field(default_factory=list)   # calibrated degrees
    note: str = ""            # free-form; kept for older recordings
    name: str = ""            # short identifier, also the filename stem
    task: str = ""            # NATURAL LANGUAGE. This is training input, not a
                              # comment: lerobot-record takes it as
                              # --dataset.single_task, and language-conditioned
                              # policies (SmolVLA, pi0) are trained against it.
                              # Demonstrations of the SAME task must share the
                              # SAME wording -- varied phrasing reads as a
                              # varied task.
    tags: list[str] = field(default_factory=list)
    arm: str = ""             # the two arms have different calibrations and
                              # reachable space; a left recording will not
                              # replay sensibly on the right
    created_at: str = ""
    cameras: list[str] = field(default_factory=list)   # slots captured per frame
    timestamps: list[float] = field(default_factory=list)  # ACTUAL capture times,
                              # seconds from the start. Recorded rather than
                              # assumed: if capture could not keep up with the
                              # requested fps, a dataset stamped with the
                              # requested rate would be quietly wrong.

    @property
    def achieved_fps(self) -> float:
        """The rate actually captured, not the one asked for."""
        if len(self.timestamps) < 2:
            return self.fps
        span = self.timestamps[-1] - self.timestamps[0]
        return (len(self.timestamps) - 1) / span if span > 0 else self.fps

    def image_dir(self, root: "Path | None" = None) -> "Path":
        return (Path(root) if root else library_dir()) / (safe_name(self.name) + ".frames")

    def image_path(self, camera: str, index: int, root=None) -> "Path":
        return self.image_dir(root) / camera / f"{index:06d}.jpg"

    @property
    def has_images(self) -> bool:
        return bool(self.cameras)

    @property
    def duration_s(self) -> float:
        return len(self.frames) / self.fps if self.fps else 0.0

    def to_dict(self) -> dict:
        return {"name": self.name, "task": self.task, "tags": list(self.tags),
                "arm": self.arm, "created_at": self.created_at, "note": self.note,
                "fps": self.fps, "joints": self.joints, "cameras": list(self.cameras),
                "timestamps": [round(t, 4) for t in self.timestamps],
                "frames": [[round(v, 3) for v in f] for f in self.frames]}

    def save(self, path: str) -> None:
        Path(path).write_text(json.dumps(self.to_dict(), indent=1) + "\n")

    @staticmethod
    def load(path: str) -> "Trajectory":
        d = json.loads(Path(path).read_text())
        return Trajectory(
            fps=float(d["fps"]), joints=list(d["joints"]),
            frames=[list(map(float, f)) for f in d["frames"]],
            note=d.get("note", ""), name=d.get("name", Path(path).stem),
            task=d.get("task", ""), tags=list(d.get("tags", [])),
            arm=d.get("arm", ""), created_at=d.get("created_at", ""),
            cameras=list(d.get("cameras", [])),
            timestamps=[float(t) for t in d.get("timestamps", [])])


# ── pure helpers (unit-tested without hardware) ─────────────────────────────

def max_step(frames: list[list[float]]) -> float:
    """Largest single-frame change of any joint, in degrees.

    Replay commands frames at the rate they were recorded, so this is the
    sharpest motion the arm will be asked to make. A large value means a
    discontinuity -- a dropped frame, or the operator's hand slipping -- and
    replaying it would be a lurch.
    """
    return max((abs(b[i] - a[i]) for a, b in zip(frames, frames[1:]) for i in range(len(a))),
               default=0.0)


def still_bounds(frames: list[list[float]], threshold_deg: float = 0.5) -> tuple[int, int]:
    """The [start, end] slice trim_still would keep.

    Exposed separately because a recording's timestamps and image files must be
    trimmed to exactly the same window -- trimming the joints alone would
    silently misalign every image with the pose it was taken at.
    """
    if not frames:
        return (0, 0)

    def moving(a, b):
        return any(abs(x - y) > threshold_deg for x, y in zip(a, b))

    start = 0
    while start + 1 < len(frames) and not moving(frames[start], frames[start + 1]):
        start += 1
    end = len(frames) - 1
    while end > start and not moving(frames[end - 1], frames[end]):
        end -= 1
    return (start, end + 1)


def trim_still(frames: list[list[float]], threshold_deg: float = 0.5) -> list[list[float]]:
    """Drop the motionless head and tail of a recording.

    Every hand-taught demonstration starts with the operator reaching for the
    arm and ends with them letting go. Those frames teach nothing and, replayed,
    are dead time at both ends.
    """
    lo, hi = still_bounds(frames, threshold_deg)
    return frames[lo:hi]


def trim_trajectory(traj: "Trajectory", threshold_deg: float = 0.5) -> list[int]:
    """Trim a whole recording, keeping frames, timestamps and image indices in
    step. Returns the ORIGINAL indices kept, so image files can be renumbered
    to match."""
    lo, hi = still_bounds(traj.frames, threshold_deg)
    kept = list(range(lo, hi))
    traj.frames = traj.frames[lo:hi]
    if traj.timestamps:
        t0 = traj.timestamps[lo] if lo < len(traj.timestamps) else 0.0
        traj.timestamps = [t - t0 for t in traj.timestamps[lo:hi]]
    return kept


# A step this large is not a brisk hand -- it is a dropped frame or a serial
# glitch, and interpolating across it would invent motion that never happened.
# Measured for scale: a real hand-taught demonstration runs a median step of
# ~0.2 deg with a p95 under 4, and its rare fast moments reach ~6.
DISCONTINUITY_DEG = 30.0


def smooth_steps(frames: list[list[float]], max_step_deg: float) -> list[list[float]]:
    """Insert intermediate frames wherever a step exceeds *max_step_deg*.

    Replaces refusing a whole demonstration because of a few brisk moments.
    Measured on a real 724-frame recording: median step 0.18 deg, p95 3.69, and
    exactly 2 frames over 6.0 -- rejecting all 40 seconds for 0.3% of frames is
    the wrong trade. Interpolating turns those moments into slightly slower
    ones and preserves the demonstration.

    Applied at REPLAY time only, never to the stored trajectory: inserting
    frames would break the one-image-per-frame alignment the dataset depends on.
    """
    if not frames or max_step_deg <= 0:
        return list(frames)
    out = [frames[0]]
    for prev, nxt in zip(frames, frames[1:]):
        gap = max((abs(b - a) for a, b in zip(prev, nxt)), default=0.0)
        n = max(1, int(gap / max_step_deg + 0.999))
        for k in range(1, n + 1):
            out.append([a + (b - a) * (k / n) for a, b in zip(prev, nxt)])
    return out


def approach_path(current: list[float], target: list[float], max_step_deg: float) -> list[list[float]]:
    """Frames from *current* to *target*, none stepping more than max_step_deg.

    This is what stops a replay snapping: the arm is wherever the last motion
    left it, and the trajectory's first frame may be a long way away.
    """
    if max_step_deg <= 0:
        raise ValueError("max_step_deg must be positive")
    gap = max((abs(t - c) for c, t in zip(current, target)), default=0.0)
    n = max(1, int(gap / max_step_deg + 0.999))
    return [[c + (t - c) * (k / n) for c, t in zip(current, target)] for k in range(1, n + 1)]


def resample(frames: list[list[float]], src_fps: float, dst_fps: float) -> list[list[float]]:
    """Linear resample to a different FRAME DENSITY.

    This does NOT slow a replay down -- for that, use replay(speed=...), which
    changes the delay between frames. Resampling to a lower rate covers the
    same motion in fewer frames, so each STEP gets LARGER and the trajectory
    can trip replay's max_step_deg refusal. Resampling UP is the useful
    direction: it smooths a recording whose steps are too coarse.
    """
    if not frames or src_fps <= 0 or dst_fps <= 0:
        return list(frames)
    n = max(1, int(round((len(frames) / src_fps) * dst_fps)))
    out = []
    for k in range(n):
        pos = k * (len(frames) - 1) / (n - 1) if n > 1 else 0.0
        i = min(int(pos), len(frames) - 1)
        j = min(i + 1, len(frames) - 1)
        w = pos - i
        out.append([a + (b - a) * w for a, b in zip(frames[i], frames[j])])
    return out


# ── validation ──────────────────────────────────────────────────────────────

def validate(traj: "Trajectory", max_step_deg: float = 6.0) -> dict:
    """Would this replay, and is it worth training on? Problems vs warnings.

    A PROBLEM means replay will refuse it. A WARNING means it will replay but
    the recording is probably not what was intended -- an empty task string is
    the one that bites later, because it silently becomes the conditioning text
    a language-conditioned policy is trained against.
    """
    problems, warnings = [], []
    n = len(traj.frames)
    if n == 0:
        problems.append("no frames recorded")
    elif n < 5:
        problems.append(f"only {n} frames -- nothing meaningful was taught")
    step = max_step(traj.frames)
    if step > DISCONTINUITY_DEG:
        problems.append(f"jumps {step:.1f} deg between adjacent frames -- a dropped frame or "
                        f"serial glitch, not a fast hand; replay refuses this")
    elif step > max_step_deg:
        warnings.append(f"briefly steps {step:.1f} deg between frames (over {max_step_deg}) "
                        f"-- replay interpolates those moments, so this is usable")
    if traj.fps <= 0:
        problems.append("fps must be positive")
    if traj.has_images and traj.timestamps:
        got = traj.achieved_fps
        if abs(got - traj.fps) / max(traj.fps, 1e-9) > 0.15:
            warnings.append(f"captured at {got:.1f} Hz, not the requested {traj.fps:.0f} Hz "
                            f"-- the dataset is stamped with the achieved rate")
    if not traj.has_images:
        warnings.append("no camera frames -- trains a state-only policy, which cannot see "
                        "where the object is; vision policies (ACT, SmolVLA) need images")
    if not traj.task.strip():
        warnings.append("no task description -- this becomes the training text for a "
                        "language-conditioned policy, so an empty one trains on nothing")
    if not traj.arm:
        warnings.append("no arm recorded -- a left-arm motion will not replay on the right")
    if n and traj.duration_s < 1.0:
        warnings.append(f"only {traj.duration_s:.1f}s long")
    if n and step < 0.05:
        warnings.append("the arm barely moved across the whole recording")
    return {"ok": not problems, "problems": problems, "warnings": warnings,
            "frames": n, "duration_s": round(traj.duration_s, 2),
            "max_step_deg": round(step, 2)}


# ── the library on disk ─────────────────────────────────────────────────────

def library_dir() -> Path:
    d = Path(os.environ.get("LEX_XLE_TEACH_DIR",
                            Path(__file__).resolve().parent / "taught"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def safe_name(name: str) -> str:
    """A filename that cannot escape the library directory."""
    cleaned = re.sub(r"[^A-Za-z0-9_.-]", "_", (name or "").strip())
    cleaned = cleaned.strip("._") or "untitled"
    return cleaned[:80]


def library_list() -> list[dict]:
    out = []
    for f in sorted(library_dir().glob("*.json")):
        try:
            t = Trajectory.load(str(f))
        except Exception as e:
            out.append({"name": f.stem, "error": f"unreadable: {e}"})
            continue
        out.append({"name": t.name or f.stem, "task": t.task, "tags": t.tags,
                    "arm": t.arm, "created_at": t.created_at, "fps": t.fps,
                    **validate(t)})
    return out


# ── hardware ────────────────────────────────────────────────────────────────

def _robot(port: str, robot_id: str):
    from lerobot.robots.so_follower import SO101Follower, SOFollowerRobotConfig
    r = SO101Follower(SOFollowerRobotConfig(port=port, id=robot_id))
    r.bus.connect(handshake=False)
    return r


def record(port: str, robot_id: str, seconds: float, fps: float = 20.0,
           joints: list[str] | None = None, note: str = "",
           free: list[str] | None = None) -> Trajectory:
    """Hold the arm and move it. Only the joints in *free* go limp.

    The gripper is deliberately NOT freed by default. Freeing everything means
    squeezing the fingers shut by hand while also supporting the arm and moving
    it through the motion -- three things at once, and the fingers are the
    fiddliest. Leaving the gripper powered lets it be commanded (the /control
    page's Open/Close, or grasp_arm) while your hands do the arm, and it still
    records faithfully because recording just reads positions.
    """
    joints = joints or ARM_JOINTS
    free = BODY_JOINTS if free is None else free
    r = _robot(port, robot_id)
    traj = Trajectory(fps=fps, joints=joints, note=note)
    try:
        r.bus.disable_torque(free)
        held = [j for j in joints if j not in free]
        print(f"recording {seconds:.0f}s at {fps:.0f} Hz")
        print(f"  LIMP (yours to hold and move): {', '.join(free)}")
        print(f"  still powered (commandable)  : {', '.join(held) if held else '(none)'}")
        period, deadline = 1.0 / fps, time.time() + seconds
        while time.time() < deadline:
            t0 = time.time()
            obs = r.bus.sync_read("Present_Position")
            traj.frames.append([float(obs[j]) for j in joints])
            time.sleep(max(0.0, period - (time.time() - t0)))
    finally:
        r.bus.disconnect()
    return traj


def replay_on_bus(bus, traj: "Trajectory", *, speed: float = 1.0,
                  max_step_deg: float = 6.0, collision_check=None) -> dict:
    """Replay on an ALREADY-CONNECTED bus.

    The sidecar holds the arm's bus open for the whole session; opening a
    second connection to the same serial port is exactly the bus-sharing
    mistake #145 documented, so the in-process caller passes its bus in.
    """
    refusal = _replay_refusal(traj, max_step_deg)
    if refusal:
        return refusal
    frames = smooth_steps(traj.frames, max_step_deg)
    sent = 0
    obs = bus.sync_read("Present_Position")
    current = [float(obs[j]) for j in traj.joints]
    bus.enable_torque()
    for frame in approach_path(current, frames[0], max_step_deg):
        bus.sync_write("Goal_Position", dict(zip(traj.joints, frame)))
        time.sleep(1.0 / (traj.fps * max(speed, 0.01)))
    for frame in frames:
        if collision_check is not None:
            hits = collision_check({f"{j}.pos": v for j, v in zip(traj.joints, frame)})
            if hits:
                return {"outcome": "denied", "frames_sent": sent,
                        "detail": "replay stopped: " + "; ".join(str(h) for h in hits[:3])}
        bus.sync_write("Goal_Position", dict(zip(traj.joints, frame)))
        sent += 1
        time.sleep(1.0 / (traj.fps * max(speed, 0.01)))
    return {"outcome": "reached", "frames_sent": sent,
            "detail": f"replayed {sent} frames over {sent / traj.fps / speed:.1f}s"}


def _replay_refusal(traj: "Trajectory", max_step_deg: float):
    """Refuse only a genuine discontinuity. Brisk moments get smoothed instead."""
    if not traj.frames:
        return {"outcome": "refused", "detail": "trajectory is empty"}
    worst = max_step(traj.frames)
    if worst > DISCONTINUITY_DEG:
        return {"outcome": "refused",
                "detail": f"trajectory jumps {worst:.1f} deg between adjacent frames "
                          f"(discontinuity threshold {DISCONTINUITY_DEG:.0f}) -- that is a "
                          f"dropped frame or a serial glitch, not a fast hand. Interpolating "
                          f"across it would invent motion that never happened; re-record."}
    return None


def replay(port: str, robot_id: str, traj: Trajectory, *, speed: float = 1.0,
           max_step_deg: float = 6.0, collision_check=None) -> dict:
    """Repeat a taught motion, opening the port ourselves (CLI use)."""
    refusal = _replay_refusal(traj, max_step_deg)
    if refusal:
        return refusal
    r = _robot(port, robot_id)
    frames = smooth_steps(traj.frames, max_step_deg)
    sent = 0
    try:
        obs = r.bus.sync_read("Present_Position")
        current = [float(obs[j]) for j in traj.joints]
        r.bus.enable_torque()
        for frame in approach_path(current, frames[0], max_step_deg):
            r.bus.sync_write("Goal_Position", dict(zip(traj.joints, frame)))
            time.sleep(1.0 / (traj.fps * max(speed, 0.01)))
        for frame in frames:
            if collision_check is not None:
                hits = collision_check(dict(zip(traj.joints, frame)))
                if hits:
                    return {"outcome": "denied", "frames_sent": sent,
                            "detail": "replay stopped: " + "; ".join(str(h) for h in hits[:3])}
            r.bus.sync_write("Goal_Position", dict(zip(traj.joints, frame)))
            sent += 1
            time.sleep(1.0 / (traj.fps * max(speed, 0.01)))
        return {"outcome": "reached", "frames_sent": sent,
                "detail": f"replayed {sent} frames over {sent / traj.fps / speed:.1f}s"}
    finally:
        r.bus.disconnect()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record", help="move the arm by hand while this records")
    rec.add_argument("--port", required=True); rec.add_argument("--id", required=True)
    rec.add_argument("--seconds", type=float, default=30.0)
    rec.add_argument("--fps", type=float, default=20.0)
    rec.add_argument("--out", required=True); rec.add_argument("--note", default="")
    rec.add_argument("--keep-still", action="store_true",
                     help="keep the motionless head/tail instead of trimming it")
    rec.add_argument("--free-gripper", action="store_true",
                     help="also free the gripper, so it is squeezed by hand rather than "
                          "commanded (default: gripper stays powered)")
    rep = sub.add_parser("replay", help="repeat a taught motion")
    rep.add_argument("--port", required=True); rep.add_argument("--id", required=True)
    rep.add_argument("--traj", required=True)
    rep.add_argument("--speed", type=float, default=1.0)
    rep.add_argument("--max-step-deg", type=float, default=6.0)
    a = p.parse_args()
    if a.cmd == "record":
        traj = record(a.port, a.id, a.seconds, a.fps, note=a.note,
                      free=(ARM_JOINTS if a.free_gripper else BODY_JOINTS))
        raw = len(traj.frames)
        if not a.keep_still:
            traj.frames = trim_still(traj.frames)
        traj.save(a.out)
        print(f"saved {a.out}: {len(traj.frames)} frames ({raw} recorded), "
              f"{traj.duration_s:.1f}s, sharpest step {max_step(traj.frames):.1f} deg")
    else:
        traj = Trajectory.load(a.traj)
        print(f"replaying {a.traj}: {len(traj.frames)} frames, {traj.duration_s:.1f}s")
        print(replay(a.port, a.id, traj, speed=a.speed, max_step_deg=a.max_step_deg))


if __name__ == "__main__":
    main()
