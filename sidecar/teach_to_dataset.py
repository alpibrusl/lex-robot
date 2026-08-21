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

  observation.images.<slot>  the camera frames captured alongside each pose,
                     when the recording has them. A state-only dataset trains
                     a policy that cannot SEE where the object is, so it can
                     only replay a motion from a given arm pose -- which is
                     not the task. Recordings without images still convert,
                     and say so, rather than being silently accepted as
                     equivalent.

Mixed libraries are refused: a dataset whose episodes disagree about which
cameras exist is not trainable, and finding that out during a long training run
is expensive.
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


def camera_sets(recordings) -> set:
    return {tuple(t.cameras) for t in recordings}


def convert(recordings, repo_id: str, root=None, fps=None, robot_type="so101_follower",
            library_root=None):
    import cv2
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

    sets = camera_sets(usable)
    if len(sets) > 1:
        return {"ok": False, "episodes": 0, "skipped": skipped,
                "detail": f"episodes disagree about cameras {sorted(sets)} -- a dataset "
                          f"cannot mix them; filter with --tag or --arm"}
    cameras = list(sets.pop())

    dim = len(joints)
    features = {
        "observation.state": {"dtype": "float32", "shape": (dim,), "names": joints},
        "action": {"dtype": "float32", "shape": (dim,), "names": joints},
    }
    shape = None
    if cameras:
        probe = cv2.imread(str(usable[0].image_path(cameras[0], 0, library_root)))
        if probe is None:
            return {"ok": False, "episodes": 0, "skipped": skipped,
                    "detail": f"{usable[0].name} lists cameras {cameras} but its image "
                              f"files are missing"}
        shape = (probe.shape[0], probe.shape[1], 3)
        for c in cameras:
            features[f"observation.images.{c}"] = {
                "dtype": "video", "shape": shape, "names": ["height", "width", "channels"]}

    # Stamp the dataset with the rate actually ACHIEVED, not the one requested:
    # a policy trained against a wrong dt learns wrong dynamics.
    achieved = fps or round(sum(t.achieved_fps for t in usable) / len(usable))
    ds = LeRobotDataset.create(repo_id=repo_id, fps=int(achieved), features=features,
                               root=root, robot_type=robot_type, use_videos=bool(cameras))
    missing = 0
    for t in usable:
        for i, (state, action) in enumerate(frames_to_pairs(t.frames)):
            # lerobot validates dtype strictly: float32 ndarrays, not lists.
            frame = {"observation.state": np.asarray(state, dtype=np.float32),
                     "action": np.asarray(action, dtype=np.float32), "task": t.task}
            skip = False
            for c in cameras:
                img = cv2.imread(str(t.image_path(c, i, library_root)))
                if img is None:
                    missing += 1
                    skip = True
                    break
                frame[f"observation.images.{c}"] = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            if not skip:
                ds.add_frame(frame)
        ds.save_episode()
    out = {"ok": True, "episodes": len(usable), "skipped": skipped, "cameras": cameras,
           "fps": int(achieved), "root": str(ds.root),
           "detail": f"wrote {len(usable)} episode(s) to {ds.root} at {int(achieved)} fps"
                     + (f" with cameras {', '.join(cameras)}" if cameras
                        else " -- STATE ONLY, no images: this cannot train a vision policy")}
    if missing:
        out["detail"] += f" ({missing} frame(s) dropped for missing images)"
    return out


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
    res = convert(recordings, a.repo_id, root=a.root, fps=a.fps, library_root=directory)
    for name, why in res["skipped"]:
        print(f"  SKIPPED {name}: {why}")
    print(res["detail"])


if __name__ == "__main__":
    main()
