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

# A verdict that decides whether an episode gets deleted must be repeatable.
# Measured: the same question on the same frame answered differently across
# two runs, because the model samples. Temperature 0 pins it down.
DETERMINISTIC = {"temperature": 0}

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


def frame_at(root: Path, meta_ep, camera: str, offset_s: float | None = None):
    """Pull one frame of the episode. One mp4 per camera, with timestamps.

    `offset_s` is measured from the start of the EPISODE, not of the file; all
    episodes share one mp4 per camera. None means the final frame.
    """
    import cv2

    path = root / "videos" / f"observation.images.{camera}" / f"chunk-{int(meta_ep[f'videos/observation.images.{camera}/chunk_index']):03d}" / f"file-{int(meta_ep[f'videos/observation.images.{camera}/file_index']):03d}.mp4"
    if not path.is_file():
        return None
    start = float(meta_ep[f"videos/observation.images.{camera}/from_timestamp"])
    end = float(meta_ep[f"videos/observation.images.{camera}/to_timestamp"])
    # Half a second before the end: the exact last frame sometimes cannot be
    # decoded after a seek.
    when = end - 0.5 if offset_s is None else min(start + offset_s, end - 0.1)
    cap = cv2.VideoCapture(str(path))
    try:
        cap.set(cv2.CAP_PROP_POS_MSEC, max(0.0, when) * 1000)
        ok, frame = cap.read()
        return frame if ok else None
    finally:
        cap.release()


def grasp_offset(states: np.ndarray, fps: int) -> float:
    """Seconds from the episode start to the moment the gripper is most closed.

    That instant is the one worth looking at: it is where precision is decided,
    and where the arm is most likely to be standing between the tower camera
    and the object.
    """
    return float(int(np.argmin(states[:, 5])) / fps)


def head_is_blocked(root: Path, meta_ep, offset_s: float, task: str):
    """Ask whether the tower camera can still see the object at the grasp.

    Worth measuring rather than guessing: a top-down grasp puts the arm between
    the tower and the table exactly when it matters. That is not fatal by
    itself -- the wrist camera covers precisely that phase, and it sees detail
    the fixed camera cannot replicate -- but if the tower view is already gone
    during the APPROACH, both cameras are blind at once and there is nothing
    left to locate the object with.
    """
    import vision

    frame = frame_at(root, meta_ep, "head", offset_s)
    if frame is None:
        return None, "no head video"
    brightness, contrast, usable = vision.calidad(frame)
    if not usable:
        return None, f"unusable frame (brightness {brightness:.0f})"

    # Two phrasings, and only an agreement counts. Measured: the SAME prompt on
    # the SAME frame answered differently on two runs, so one reading is noise,
    # not a measurement.
    questions = (
        f"This is a fixed overhead camera watching a robot arm perform: {task}. "
        f"Answer with ONE word only: BLOCKED if the robot arm is covering the object "
        f"so you cannot see it, VISIBLE if the object can still be seen.",
        f"In this overhead photo, is the robot arm standing between the camera and "
        f"the object it is picking up? Answer with ONE word only: BLOCKED if the arm "
        f"hides the object, VISIBLE if the object is in plain sight.",
    )
    answers = []
    for q in questions:
        try:
            a = vision.pregunta_al_modelo(frame, q, timeout=120, opciones=DETERMINISTIC).strip().upper()
        except Exception as e:
            return None, f"the model did not answer ({type(e).__name__})"
        if a.startswith("BLOCKED"):
            answers.append(True)
        elif a.startswith("VISIBLE"):
            answers.append(False)
        else:
            return None, f"ambiguous answer: {a[:40]}"

    if answers[0] != answers[1]:
        return None, "the two phrasings disagree"
    return answers[0], "both phrasings agree"


def judge_with_model(root: Path, meta_ep, task: str):
    """Ask the local model whether the episode ended well."""
    import vision

    frame = frame_at(root, meta_ep, "wrist")
    if frame is None:
        return None, "no wrist video"

    # Do not ask about a frame you cannot see. The model does NOT say "I see
    # nothing": it once described a pitch-black image in full detail. An
    # invented verdict is worse than no verdict.
    brightness, contrast, usable = vision.calidad(frame)
    if not usable:
        return None, f"unusable frame (brightness {brightness:.0f}, contrast {contrast:.0f})"

    # Ask TWICE, worded differently, and only believe an agreement. Measured:
    # the same frame flipped verdict when the prompt was translated, so a
    # single reading is not evidence. Same reasoning as the median-of-three on
    # temperature: a verdict that decides whether an episode gets deleted
    # cannot rest on one sample.
    questions = (
        f"This is the view from a robot arm's gripper at the end of an attempt to: "
        f"{task}. Answer with ONE word only: YES if the gripper is holding the "
        f"object, NO if it is not holding it or it cannot be seen.",
        f"Look at this robot gripper. Is it gripping an object right now, or are its "
        f"fingers empty? Answer with ONE word only: YES if it grips something, NO if "
        f"the fingers are empty.",
    )
    answers = []
    for q in questions:
        try:
            a = vision.pregunta_al_modelo(frame, q, timeout=120, opciones=DETERMINISTIC).strip().upper()
        except Exception as e:
            return None, f"the model did not answer ({type(e).__name__})"
        if a.startswith("YES") or a.startswith("SI") or a.startswith("SÍ"):
            answers.append(True)
        elif a.startswith("NO"):
            answers.append(False)
        else:
            return None, f"ambiguous answer: {a[:40]}"

    if answers[0] != answers[1]:
        return None, "the two phrasings disagree -- look at this one yourself"
    return answers[0], "both phrasings agree"


def object_visibility(root: Path, metas) -> None:
    """How often each camera can actually SEE the object.

    Deterministic and free: it is the colour detector already used by the
    visual servo, not a model. Worth knowing before anything else, because a
    camera that never resolves the object contributes nothing about WHERE it
    is -- and no detector rescues an object that is only a few pixels across.
    ACT feeds the frame straight into its backbone without resizing, so the
    pixels the object occupies are exactly the detail the policy gets.
    """
    try:
        from wrist_servo import encuentra_rosa
    except Exception as e:
        print(f"\nObject visibility: colour detector unavailable ({type(e).__name__})")
        return

    hits = {"head": 0, "wrist": 0}
    total = {"head": 0, "wrist": 0}
    sizes = {"head": [], "wrist": []}
    for _, m in metas.iterrows():
        for camera in ("head", "wrist"):
            for offset in (0.5, None):  # early in the episode, and at the end
                frame = frame_at(root, m, camera, offset)
                if frame is None:
                    continue
                total[camera] += 1
                found, _ = encuentra_rosa(frame)
                if found is not None:
                    hits[camera] += 1
                    sizes[camera].append(found[1])

    print("\nObject visibility (pink marker, colour detector):")
    for camera in ("head", "wrist"):
        if not total[camera]:
            continue
        area = f", median {int(np.median(sizes[camera]))} px" if sizes[camera] else ""
        print(f"  {camera:6s}: found in {hits[camera]}/{total[camera]} frames{area}")

    if total["head"] and hits["head"] == 0:
        print(
            "\n  The tower NEVER resolves the object. That view still carries useful\n"
            "  context -- where the arm is over the table -- but it contributes almost\n"
            "  nothing about WHERE the object is, so the wrist camera is carrying the\n"
            "  task alone. This is a framing problem, not a detector problem: nothing\n"
            "  recovers an object a couple of dozen pixels across. Either aim the tower\n"
            "  so the workspace fills the frame, or record that camera at a higher\n"
            "  resolution -- ACT feeds frames to its backbone WITHOUT resizing, so the\n"
            "  pixels on the object are the detail the policy gets."
        )


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

    verdicts, occlusion = {}, {}
    if look:
        task = str(metas.iloc[0]["tasks"][0]) if len(metas) else "pick up the object"
        print(f"Asking the local model about the end of each episode ({task})...\n")
        for _, m in metas.iterrows():
            ep = int(m["episode_index"])
            ok, detail = judge_with_model(root, m, task)
            verdicts[ep] = (ok, detail)
            if ok is False:
                note(ep, f"the model does not see the object held: {detail}")

            states = np.stack(data[data["episode_index"] == ep]["observation.state"].values)
            blocked, why = head_is_blocked(root, m, grasp_offset(states, fps), task)
            if blocked is not None:
                occlusion[ep] = blocked

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

    if occlusion:
        blocked = sum(occlusion.values())
        print(
            f"\nTower view at the moment of the grasp: blocked in {blocked} of "
            f"{len(occlusion)} episodes where both phrasings agreed."
        )
        if blocked and blocked < len(occlusion):
            print(
                "  Blocked in SOME but not all. That inconsistency is the awkward case:\n"
                "  the policy cannot settle on which camera carries the information at\n"
                "  that phase. Grasp the object the same way every time."
            )
        elif blocked == len(occlusion):
            print(
                "  Blocked every time, which is consistent and workable: the policy will\n"
                "  lean on the wrist camera for the final approach, which is exactly what\n"
                "  that camera is for. Just make sure the tower still sees the object\n"
                "  EARLIER, during the approach -- if both views lose it at once there is\n"
                "  nothing left to locate it with."
            )

    object_visibility(root, metas)
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
