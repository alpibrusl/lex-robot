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
import time
from dataclasses import dataclass, field
from pathlib import Path

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]


@dataclass
class Trajectory:
    fps: float
    joints: list[str]
    frames: list[list[float]] = field(default_factory=list)   # calibrated degrees
    note: str = ""

    @property
    def duration_s(self) -> float:
        return len(self.frames) / self.fps if self.fps else 0.0

    def to_dict(self) -> dict:
        return {"fps": self.fps, "joints": self.joints, "note": self.note,
                "frames": [[round(v, 3) for v in f] for f in self.frames]}

    def save(self, path: str) -> None:
        Path(path).write_text(json.dumps(self.to_dict(), indent=1) + "\n")

    @staticmethod
    def load(path: str) -> "Trajectory":
        d = json.loads(Path(path).read_text())
        return Trajectory(float(d["fps"]), list(d["joints"]),
                          [list(map(float, f)) for f in d["frames"]], d.get("note", ""))


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


def trim_still(frames: list[list[float]], threshold_deg: float = 0.5) -> list[list[float]]:
    """Drop the motionless head and tail of a recording.

    Every hand-taught demonstration starts with the operator reaching for the
    arm and ends with them letting go. Those frames teach nothing and, replayed,
    are dead time at both ends.
    """
    if not frames:
        return []

    def moving(a, b):
        return any(abs(x - y) > threshold_deg for x, y in zip(a, b))

    start = 0
    while start + 1 < len(frames) and not moving(frames[start], frames[start + 1]):
        start += 1
    end = len(frames) - 1
    while end > start and not moving(frames[end - 1], frames[end]):
        end -= 1
    return frames[start:end + 1]


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


# ── hardware ────────────────────────────────────────────────────────────────

def _robot(port: str, robot_id: str):
    from lerobot.robots.so_follower import SO101Follower, SOFollowerRobotConfig
    r = SO101Follower(SOFollowerRobotConfig(port=port, id=robot_id))
    r.bus.connect(handshake=False)
    return r


def record(port: str, robot_id: str, seconds: float, fps: float = 20.0,
           joints: list[str] | None = None, note: str = "") -> Trajectory:
    """Hold the arm and move it. Torque is off for the whole recording."""
    joints = joints or ARM_JOINTS
    r = _robot(port, robot_id)
    traj = Trajectory(fps=fps, joints=joints, note=note)
    try:
        r.bus.disable_torque()
        print(f"recording {seconds:.0f}s at {fps:.0f} Hz -- the arm is LIMP, support it")
        period, deadline = 1.0 / fps, time.time() + seconds
        while time.time() < deadline:
            t0 = time.time()
            obs = r.bus.sync_read("Present_Position")
            traj.frames.append([float(obs[j]) for j in joints])
            time.sleep(max(0.0, period - (time.time() - t0)))
    finally:
        r.bus.disconnect()
    return traj


def replay(port: str, robot_id: str, traj: Trajectory, *, speed: float = 1.0,
           max_step_deg: float = 6.0, collision_check=None) -> dict:
    """Repeat a taught motion. Refuses rather than lurching."""
    if not traj.frames:
        return {"outcome": "refused", "detail": "trajectory is empty"}
    worst = max_step(traj.frames)
    if worst > max_step_deg:
        return {"outcome": "refused",
                "detail": f"trajectory steps up to {worst:.1f} deg between frames "
                          f"(limit {max_step_deg}) -- a dropped frame or a hand slip; "
                          f"re-record or resample rather than replay this"}
    r = _robot(port, robot_id)
    sent = 0
    try:
        obs = r.bus.sync_read("Present_Position")
        current = [float(obs[j]) for j in traj.joints]
        r.bus.enable_torque()
        for frame in approach_path(current, traj.frames[0], max_step_deg):
            r.bus.sync_write("Goal_Position", dict(zip(traj.joints, frame)))
            time.sleep(1.0 / (traj.fps * max(speed, 0.01)))
        for frame in traj.frames:
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
    rep = sub.add_parser("replay", help="repeat a taught motion")
    rep.add_argument("--port", required=True); rep.add_argument("--id", required=True)
    rep.add_argument("--traj", required=True)
    rep.add_argument("--speed", type=float, default=1.0)
    rep.add_argument("--max-step-deg", type=float, default=6.0)
    a = p.parse_args()
    if a.cmd == "record":
        traj = record(a.port, a.id, a.seconds, a.fps, note=a.note)
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
