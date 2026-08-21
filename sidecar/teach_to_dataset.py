#!/usr/bin/env python3
"""Convert taught demonstrations into a LeRobotDataset that lerobot-train reads.

sidecar/teach.py records hand-guided motions in its own small JSON format,
which is right for recording and browsing but is not what training consumes.
This converts a folder of them into a real `LeRobotDataset`.

Written the same way as record_scripted.py, and for the same reason: the
dataset is created and written by **lerobot's own API**, never by hand. Every
field, index and metadata file is lerobot's, so the schema is whatever
lerobot-train expects rather than whatever we guessed it expects.

    python sidecar/teach_to_dataset.py --repo-id local/xle_taught_picks
    python sidecar/teach_to_dataset.py --repo-id local/picks --tag nominal --arm left

What each demonstration becomes:
  observation.state  the joint positions at frame i
  action             the joint positions at frame i+1 -- what the arm was
                     asked to do next. A taught trajectory has no separate
                     command channel: the operator's hand WAS the command, so
                     the next recorded pose is the best available action label.
                     The final frame is dropped, having no successor.
  task               the demonstration's `task` string, verbatim

NO CAMERA FRAMES. teach.py records joints only, so this produces a state-only
dataset. That trains a state-conditioned policy; a vision policy (ACT, SmolVLA)
needs images recorded in step with the joints, which is a change to the
recorder, not to this converter. Stated plainly because a dataset that trains
without error but has no images is an easy thing to discover far too late.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import teach


def frames_to_pairs(frames: list[list[float]]) -> list[tuple[list[float], list[float]]]:
    """(state, action) pairs: each frame paired with the one that followed it.

    Pure, so the pairing rule is testable without writing a dataset.
    """
    return [(frames[i], frames[i + 1]) for i in range(len(frames) - 1)]


def select(recordings, arm=None, tag=None, task=None):
    out = []
    for t in recordings:
        if arm and t.arm != arm:
            continue
        if tag and tag not in t.tags:
            continue
        if task and t.task != task:
            continue
        out.append(t)
    return out


def load_library(directory: Path) -> list[teach.Trajectory]:
    return [teach.Trajectory.load(str(f)) for f in sorted(directory.glob("*.json"))]


def convert(recordings, repo_id: str, root=None, fps=None, robot_type="so101_follower"):
    from lerobot.datasets.lerobot_dataset import LeRobotDataset

    usable, skipped = [], []
    for t in recordings:
        report = teach.validate(t)
        if not report["ok"]:
            skipped.append((t.name, "; ".join(report["problems"])))
        elif not t.task.strip():
            # Refused, not defaulted. An empty task silently becomes the text a
            # language-conditioned policy trains against, and a made-up
            # placeholder would be worse than a missing episode.
            skipped.append((t.name, "no task description -- would train on an empty string"))
        else:
            usable.append(t)
    if not usable:
        return {"ok": False, "episodes": 0, "skipped": skipped,
                "detail": "nothing usable to convert"}

    joints = usable[0].joints
    for t in usable:
        if t.joints != joints:
            return {"ok": False, "episodes": 0, "skipped": skipped,
                    "detail": f"{t.name} has different joints {t.joints} than {joints}"}

    dim = len(joints)
    features = {
        "observation.state": {"dtype": "float32", "shape": (dim,), "names": joints},
        "action": {"dtype": "float32", "shape": (dim,), "names": joints},
    }
    ds = LeRobotDataset.create(repo_id=repo_id, fps=int(fps or round(usable[0].fps)),
                               features=features, root=root, robot_type=robot_type,
                               use_videos=False)
    for t in usable:
        for state, action in frames_to_pairs(t.frames):
            # lerobot validates dtype strictly: float32 ndarrays, not lists.
            ds.add_frame({"observation.state": np.asarray(state, dtype=np.float32),
                          "action": np.asarray(action, dtype=np.float32),
                          "task": t.task})
        ds.save_episode()
    return {"ok": True, "episodes": len(usable), "skipped": skipped,
            "root": str(ds.root),
            "detail": f"wrote {len(usable)} episode(s) to {ds.root}"}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--repo-id", required=True)
    p.add_argument("--dir", default=None, help="taught library (default LEX_XLE_TEACH_DIR)")
    p.add_argument("--root", default=None, help="where to write the dataset")
    p.add_argument("--arm", default=None); p.add_argument("--tag", default=None)
    p.add_argument("--task", default=None, help="only demonstrations with this exact task text")
    p.add_argument("--fps", type=int, default=None)
    a = p.parse_args()

    directory = Path(a.dir) if a.dir else teach.library_dir()
    recordings = select(load_library(directory), a.arm, a.tag, a.task)
    print(f"{len(recordings)} demonstration(s) selected from {directory}")
    res = convert(recordings, a.repo_id, root=a.root, fps=a.fps)
    for name, why in res["skipped"]:
        print(f"  SKIPPED {name}: {why}")
    print(res["detail"])


if __name__ == "__main__":
    main()
