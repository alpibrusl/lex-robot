#!/usr/bin/env python3
"""Write docs/recording_sequence.csv: every episode of docs/RECORDING_PLAN.md,
in the order to record them, with the exact name, task text, tags and setup.

Seeded, so the randomised orders are the same every time it runs. Change SEED
and the order changes; keep it and the sheet you are working from stays valid.

    python3 scripts/make_recording_sequence.py
"""
import csv
import random
import sys
from collections import Counter
from pathlib import Path

SEED = 20261004
rng = random.Random(SEED)

# (reach_cm, across_cm) of each cell relative to P0, the cell you pick in the
# pre-check. +reach = away from the robot, +across = the robot's LEFT.
GRID = {
    "p1": (-6, -8), "p2": (-6, 0), "p3": (-6, 8),
    "p4": (0, -8),  "p5": (0, 0),  "p6": (0, 8),
    "p7": (6, -8),  "p8": (6, 0),  "p9": (6, 8),
}
# Place targets, same convention, relative to P0 (the mark of tape).
TARGETS = {"t0": (0, -16), "t1": (6, -16), "t2": (-6, -16), "t3": (0, -24)}

PICK = "pick up the object"
PLACE = "pick up the object and place it on the mark"

COLUMNS = ["seq", "stage", "name", "prefix", "task", "tags", "object_cell", "object_offset_cm",
           "target", "target_offset_cm", "light", "distractor", "recipe", "what_to_do",
           "result", "discard_reason", "duration_s", "frames", "hz", "max_step_deg", "notes"]

rows = []
counts = Counter()


def off(cell):
    r, a = GRID[cell]
    return f"reach {r:+d}, across {a:+d}"


def toff(t):
    r, a = TARGETS[t]
    return f"reach {r:+d}, across {a:+d}"


def add(stage, prefix, task, tags, recipe, what, cell="p5", target="", light="", distractor=""):
    counts[prefix] += 1
    rows.append({
        "seq": len(rows) + 1, "stage": stage, "name": f"{prefix}_{counts[prefix]:03d}",
        "prefix": prefix, "task": task, "tags": ",".join(tags),
        "object_cell": cell, "object_offset_cm": off(cell),
        "target": target, "target_offset_cm": toff(target) if target else "",
        "light": light, "distractor": distractor, "recipe": recipe, "what_to_do": what,
        "result": "", "discard_reason": "", "duration_s": "", "frames": "", "hz": "",
        "max_step_deg": "", "notes": "",
    })


def shuffled_rounds(items, rounds):
    out = []
    for _ in range(rounds):
        r = list(items)
        rng.shuffle(r)
        out += r
    return out


# 0 -- pipeline check: thrown away.
for _ in range(3):
    add(0, "test", PICK, ["test"], "R-PICK",
        "Pipeline check, not for training. Time it from Space to Space.", cell="p5")

# 1 -- one fixed position.
for _ in range(25):
    add(1, "s1_p5", PICK, ["stage1", "p5"], "R-PICK",
        "Object on the P0 mark. Same start pose, same approach every time.", cell="p5")

# 2 -- 3x3 grid, five shuffled rounds so light/fatigue are not confused with position.
for cell in shuffled_rounds(GRID, 5):
    add(2, f"s2_{cell}", PICK, ["stage2", cell], "R-PICK",
        f"Object on cell {cell} ({off(cell)} from P0).", cell=cell)

# 3 -- variation. Light changes in blocks (it is impractical per episode).
cells = list(GRID)
rng.shuffle(cells)
light_cells = (cells + [rng.choice(cells)])[:10]
for i, cell in enumerate(light_cells):
    cond = "light_A" if i < 5 else "light_B"
    what = ("Light A: blinds open, daylight, no lamp." if cond == "light_A"
            else "Light B: blinds closed, desk lamp on.")
    add(3, f"s3_{cond}", PICK, ["stage3", cond, cell], "R-PICK",
        f"{what} Object on {cell}. Record all five of one light before changing it.",
        cell=cell, light=cond)
rng.shuffle(cells)
for i, cell in enumerate(cells[:9] + [rng.choice(cells)]):
    side = "left" if i % 2 == 0 else "right"
    add(3, "s3_distractor", PICK, ["stage3", "distractor", cell], "R-PICK",
        f"Put a second object (a screwdriver or a cable coil) 10 cm to the {side} of the "
        f"object, in the gripper's path but not touching it. Object on {cell}.",
        cell=cell, distractor=f"10 cm to the {side}")

# 4 -- recovery: fail on purpose, then correct, and END with the object lifted.
variants = [
    ("a", "Grasp too high: close on the top third (the cap). Notice, open (O), lower, regrasp at mid-body, lift."),
    ("b", "Object nudged: while approaching, push it ~3 cm sideways with a finger. Re-centre over it, then pick."),
    ("c", "Missed: close on air a few cm to one side. Open (O), shift across (A/D), lower again, grasp, lift."),
]
order = [v for v in variants for _ in range(4)]
rng.shuffle(order)
rcells = ["p2", "p4", "p5", "p6", "p8"]
for i, (v, text) in enumerate(order):
    cell = rcells[i % len(rcells)]
    add(4, f"s4_{v}", PICK, ["stage4", "recovery", f"recovery_{v}", cell], f"R-RECOVER-{v.upper()}",
        f"{text} Object on {cell}. It MUST end with the object lifted.", cell=cell)

# 5 -- pick and place onto a tape mark.
add_targets = ["t0"] * 25 + rng.sample(["t1", "t2", "t3"] * 5, 15)
for t in add_targets[:25] + sorted(add_targets[25:], key=lambda _: rng.random()):
    add(5, f"s5_{t}", PLACE, ["stage5", "place", t], "R-PLACE",
        f"Object on the P0 mark. Tape mark at {t} ({toff(t)} from P0). Pick, carry, lower, open, retreat.",
        cell="p5", target=t)

# 6 -- for the verifier, never for training. Labelled by the operator at record time.
ok_cells = [rng.choice(cells) for _ in range(6)]
for cell in ok_cells:
    add(6, "s6_ok", PICK, ["verifier", "ok", cell], "R-PICK",
        f"A normal, clean pick. Object on {cell}. Label: OK.", cell=cell)
for t in ["t0", "t1", "t2", "t3"]:
    add(6, "s6_ok_place", PLACE, ["verifier", "ok", t], "R-PLACE",
        f"A normal, clean place on {t}. Label: OK.", cell="p5", target=t)
fails = ([("miss", PICK, "Close the gripper on air beside the object, then lift. Label: FAIL (missed).")] * 3
         + [("drop", PICK, "Grasp properly, lift 5 cm, then open (O) so it falls. Label: FAIL (dropped).")] * 3
         + [("offtarget", PLACE, "Pick fine, place the object 6 cm or more away from the mark. Label: FAIL (off target).")] * 2
         + [("abort", PLACE, "Pick fine, carry it, then stop recording before releasing. Label: FAIL (aborted).")] * 2)
rng.shuffle(fails)
for kind, task, text in fails:
    cell = rng.choice(cells)
    tgt = rng.choice(list(TARGETS)) if task == PLACE else ""
    add(6, f"s6_fail_{kind}", task, ["verifier", "fail", kind], "R-FAIL-" + kind.upper(),
        f"{text} Object on {cell}." + (f" Mark at {tgt}." if tgt else ""), cell=cell, target=tgt)

out = Path(__file__).resolve().parent.parent / "docs" / "recording_sequence.csv"
with out.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=COLUMNS)
    w.writeheader()
    w.writerows(rows)

by_stage = Counter(r["stage"] for r in rows)
print(f"wrote {out.relative_to(out.parent.parent)}: {len(rows)} episodes", dict(sorted(by_stage.items())),
      f"(seed {SEED})", file=sys.stderr)
