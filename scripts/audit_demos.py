"""Audit a set of demonstrations before training.

Why bother: ACT does not tell a good take from a bad one. It treats EVERYTHING
you give it as expert example to imitate, so an episode where the star slipped
away is not ignored -- it learns to let it slip. Removing the failures is the
first quality lever, ahead of recording more.

Two layers, cheap to expensive:

1. Mechanical checks, over numbers already in the dataset. These are the ones
   the lerobot guides recommend: similar episode durations, no dropped frames,
   joints within range, and the arm actually following the commands.

2. The local model looking at the last frame (--look). Detecting success with a
   vision model is a known pattern, framed as a question about the image rather
   than as detection: our qwen describes well but does not localize, so it is
   asked about STATE ("is the gripper holding the object?"), never about
   coordinates.

Usage:
    python scripts/audit_demos.py [dataset] [--look]
"""

import glob
import json
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent.parent / "sidecar"))

JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]

# Thresholds. The first three come from the lerobot guides; the rest from what
# physically makes a take useless.
DURATION_RATIO = 2.0   # the longest episode must not double the shortest
LIMIT_MARGIN = 1.0     # normalized units of clearance from the stop
MIN_MOVEMENT = 40.0    # below this the arm barely moved
MIN_GRIPPER = 5.0      # gripper travel: without it there was no grasp attempt
MAX_DRIFT = 0.45       # how far the arm may lag behind what was commanded

# Coverage. Clean is not the same as good: a set of identical perfect takes
# teaches the policy one narrow band of states, and at run time it WILL drift
# slightly off that band. Once there it is in a state it never saw, acts badly,
# drifts further, and the error compounds. So the end poses are expected to
# spread out -- that spread is where you put the object.
MIN_EPISODES_FOR_COVERAGE = 5   # below this the spread means nothing
MIN_END_SPREAD = 3.0            # normalized units of std across episodes


def load(root: Path):
    data = pd.concat(
        [pd.read_parquet(f) for f in sorted(glob.glob(str(root / "data" / "**" / "*.parquet"), recursive=True))]
    )
    metas = pd.concat(
        [pd.read_parquet(f) for f in sorted(glob.glob(str(root / "meta" / "episodes" / "**" / "*.parquet"), recursive=True))]
    )
    info = json.load(open(root / "meta" / "info.json"))
    return data, metas, info


def last_frame(root: Path, meta_ep, camera: str):
    """Pull the episode's final frame. One mp4 per camera, with timestamps."""
    import cv2

    path = root / "videos" / f"observation.images.{camera}" / f"chunk-{int(meta_ep[f'videos/observation.images.{camera}/chunk_index']):03d}" / f"file-{int(meta_ep[f'videos/observation.images.{camera}/file_index']):03d}.mp4"
    if not path.is_file():
        return None
    end = float(meta_ep[f"videos/observation.images.{camera}/to_timestamp"])
    cap = cv2.VideoCapture(str(path))
    try:
        # Half a second before the end: the exact last frame sometimes cannot
        # be decoded after a seek.
        cap.set(cv2.CAP_PROP_POS_MSEC, max(0.0, end - 0.5) * 1000)
        ok, frame = cap.read()
        return frame if ok else None
    finally:
        cap.release()


def judge_with_model(root: Path, meta_ep, task: str):
    """Ask the local model whether the episode ended well."""
    import vision

    frame = last_frame(root, meta_ep, "wrist")
    if frame is None:
        return None, "no wrist video"

    # Do not ask about a frame you cannot see. The model does NOT say "I see
    # nothing": it once described a pitch-black image in full detail. An
    # invented verdict is worse than no verdict.
    brightness, contrast, usable = vision.calidad(frame)
    if not usable:
        return None, f"unusable frame (brightness {brightness:.0f}, contrast {contrast:.0f})"

    question = (
        f"This is the view from a robot arm's gripper at the end of an attempt "
        f"to: {task}. Answer with ONE word only: YES if the gripper is holding "
        f"the object, NO if it is not holding it or it cannot be seen."
    )
    try:
        answer = vision.pregunta_al_modelo(frame, question, timeout=120).strip().upper()
    except Exception as e:
        return None, f"the model did not answer ({type(e).__name__})"
    if answer.startswith("YES") or answer.startswith("SI") or answer.startswith("SÍ"):
        return True, answer[:40]
    if answer.startswith("NO"):
        return False, answer[:40]
    return None, f"ambiguous answer: {answer[:40]}"


def coverage(data, metas) -> None:
    """Report how varied the takes are, not just how clean.

    The spread that matters is the one at the END of the episode: that is where
    the object was, so it stands in for how much you moved it around between
    takes. The spread at the start says little -- everyone resets the arm to
    roughly the same rest pose, and that is fine.
    """
    if len(metas) < MIN_EPISODES_FOR_COVERAGE:
        print(
            f"\nCoverage: {len(metas)} episodes is too few to judge the spread."
            f" Ask again past {MIN_EPISODES_FOR_COVERAGE}."
        )
        return

    starts, ends = [], []
    for _, g in data.groupby("episode_index"):
        s = np.stack(g["observation.state"].values)
        starts.append(s[0])
        ends.append(s[-1])
    starts, ends = np.stack(starts), np.stack(ends)

    print("\nCoverage (std across episodes, normalized units):")
    print(f"  {'joint':14s} {'at start':>9s} {'at end':>9s}")
    for i, joint in enumerate(JOINTS):
        print(f"  {joint:14s} {starts[:, i].std():9.1f} {ends[:, i].std():9.1f}")

    # The base and the shoulder are what move to reach a different spot on the
    # table, so they are the ones that should differ between takes.
    reach = float(np.mean([ends[:, 0].std(), ends[:, 1].std()]))
    if reach < MIN_END_SPREAD:
        print(
            f"\n  TOO UNIFORM (base/shoulder spread {reach:.1f} at the end).\n"
            "  Every take ends in nearly the same pose, so the object barely moved\n"
            "  between them. Clean takes are not enough: a policy that only ever saw\n"
            "  one narrow band of states has no idea what to do once it drifts off it,\n"
            "  and it will drift. Move the object around between episodes -- nearer,\n"
            "  further, off to the sides, turned differently."
        )
    else:
        print(f"\n  Varied enough (base/shoulder spread {reach:.1f} at the end).")


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    look = "--look" in sys.argv
    name = args[0] if args else "xle_estrella"
    root = Path(os.path.expanduser(f"~/lex-robot-datasets/{name}"))
    if not root.is_dir():
        print(f"Cannot find {root}", file=sys.stderr)
        return 1

    data, metas, info = load(root)
    fps = info.get("fps", 30)
    print(f"{name}: {len(metas)} episodes, {len(data)} frames, {fps} fps\n")

    durations = metas["length"].to_numpy()
    issues = {}

    def note(ep, text):
        issues.setdefault(int(ep), []).append(text)

    # Uneven durations: if one episode doubles another, either there is trailing
    # dead time or the task was cut short.
    if len(durations) > 1 and durations.max() > DURATION_RATIO * durations.min():
        for _, m in metas.iterrows():
            if m["length"] > DURATION_RATIO * durations.min():
                note(m["episode_index"], f"lasts {m['length']} vs {durations.min()} for the shortest")

    for ep, g in data.groupby("episode_index"):
        a = np.stack(g["action"].values)
        s = np.stack(g["observation.state"].values)

        moved = float(np.abs(np.diff(s, axis=0)).sum())
        if moved < MIN_MOVEMENT:
            note(ep, f"barely moved (total travel {moved:.0f})")

        gripper = float(s[:, 5].max() - s[:, 5].min())
        if gripper < MIN_GRIPPER:
            note(ep, f"the gripper was never used (travel {gripper:.1f})")

        # Did the arm follow the commands? If not, what was recorded is not
        # what happened.
        drift = float(np.abs(a - s).mean())
        if drift > MAX_DRIFT * 10:
            note(ep, f"the arm did not follow the commands (mean drift {drift:.1f})")

        # Stops: the gripper runs 0..100, everything else -100..100.
        for i, joint in enumerate(JOINTS):
            low, high = (0.0, 100.0) if joint == "gripper" else (-100.0, 100.0)
            if s[:, i].min() < low + LIMIT_MARGIN or s[:, i].max() > high - LIMIT_MARGIN:
                note(ep, f"{joint} hit its stop")

        # Dropped frames: timestamp gaps should be 1/fps.
        t = g["timestamp"].to_numpy()
        gaps = np.diff(t)
        dropped = int((gaps > 1.8 / fps).sum())
        if dropped:
            note(ep, f"{dropped} timestamp gaps (dropped frames)")

    verdicts = {}
    if look:
        task = str(metas.iloc[0]["tasks"][0]) if len(metas) else "pick up the object"
        print(f"Asking the local model about the end of each episode ({task})...\n")
        for _, m in metas.iterrows():
            ok, detail = judge_with_model(root, m, task)
            verdicts[int(m["episode_index"])] = (ok, detail)
            if ok is False:
                note(m["episode_index"], f"the model does not see the object held: {detail}")

    for _, m in metas.iterrows():
        ep = int(m["episode_index"])
        failures = issues.get(ep, [])
        mark = "CHECK" if failures else "ok   "
        extra = ""
        if ep in verdicts:
            ok, detail = verdicts[ep]
            extra = {True: "  model: holding", False: "  model: NOT holding", None: f"  model: {detail}"}[ok]
        print(f"  episode {ep:3d}  {m['length']:4d} frames  {mark}{extra}")
        for f in failures:
            print(f"                - {f}")

    coverage(data, metas)

    suspect = sorted(issues)
    print(f"\n{len(metas) - len(suspect)} of {len(metas)} episodes clean.")
    if suspect:
        print(f"To check: {suspect}")
        print(
            "\nLook at them before training. ACT imitates everything you give it, so\n"
            "a failed take is not ignored: it learns to fail the same way."
        )
        print(
            "Remove the FAILURES, not the imperfections: a take where you overshot and\n"
            "corrected is good data, because it is the only place the policy ever sees\n"
            "how to get back on track."
        )
    if not look:
        print("\nWith --look, the local model also judges whether the object ended up held.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
