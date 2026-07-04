#!/usr/bin/env python3
"""XLeRobot policy eval — the "train here" side of the safe-RL/eval loop
(lex-robot epic #63 / PR #76's stated next step, closed by this script).

A REACTIVE policy (not the fixed waypoint script in examples/xlerobot_task.lex):
it observes the cup's world position and the base's actual post-drive pose, then
COMPUTES the arm-frame reach target from that observation via the same
base-to-arm-frame transform XLeSim.world_of() uses — it adapts to wherever the
differential-drive base actually lands, rather than replaying hand-tuned
waypoints. This is a scripted geometric controller, not a trained network — a
faithful baseline in the sense the repo's other named "policies" are (see
examples/policy_eval.lex) — but it is a genuine state -> action policy, and the
harness below is agnostic to how the policy was produced: a future RL-trained
policy against gym_env.xlerobot_env's `LexXLeRobotFetch-v0` env plugs into the
exact same rollout format.

It runs entirely against XLeSim (the same physics core the gym env wraps), and
writes its ROLLOUT — the sequence of skill calls it issued, in the exact units
and frame lex-robot's governed skills (skills.move_base / move_arm / grasp_arm)
expect — to a JSON file. examples/xlerobot_policy_rollout.lex then replays that
exact sequence through the GOVERNED skill surface against a live sidecar,
producing a robot_task-format trail: "roll out through the grant gate."

Usage: python3 gym_env/xlerobot_policy_eval.py [out.json]
"""
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import numpy as np
from xlerobot_sim import XLeSim, ARM_MOUNT, GRASP_TOL

ARM = "left"
GRASP_FORCE_N = 15.0     # matches the arm grant's max_grip_force ceiling
HOME_XY = (0.5, 1.5)     # the base's reset position — "carry it home"


def arm_frame_offset(base_xy, heading, mount, world_target):
    """Invert XLeSim.world_of(): world = base + R(heading) @ (mount + offset)."""
    d = np.asarray(world_target[:2]) - np.asarray(base_xy)
    c, s = math.cos(heading), math.sin(heading)
    local_xy = np.array([c * d[0] + s * d[1], -s * d[0] + c * d[1]])
    off_xy = local_xy - mount[:2]
    off_z = world_target[2] - mount[2]
    return float(off_xy[0]), float(off_xy[1]), float(off_z)


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def step(skill, x=0.0, y=0.0, z=0.0, speed=0.0, force=0.0, sim_outcome=""):
    """Uniform step shape (all fields present, unused ones default to 0.0) so
    the Lex-side replay parses every step with a single record type."""
    return {"skill": skill, "x": x, "y": y, "z": z, "speed": speed, "force": force, "sim_outcome": sim_outcome}


def run_policy():
    sim = XLeSim()
    obs = sim.reset()
    rollout = []

    # 1. Stage: drive toward the cup, standing off along the straight-line
    #    approach so the arm's reach box (x in [0.05,0.45]) has room, exactly
    #    as a perception-driven policy would (not a memorized waypoint).
    base0 = np.array([obs["base"]["x"], obs["base"]["y"]])
    cup = np.array(obs["cup"])
    direction = cup[:2] - base0
    direction = direction / max(float(np.linalg.norm(direction)), 1e-9)
    stage_xy = cup[:2] - direction * 0.55
    r1 = sim.drive(float(stage_xy[0]), float(stage_xy[1]), 0.4)
    rollout.append(step("move_base", x=float(stage_xy[0]), y=float(stage_xy[1]), speed=0.4, sim_outcome=r1["outcome"]))

    # 2. Reach: OBSERVE where the base actually ended up (diff-drive settles
    #    heading to wherever it turned last) and compute the arm-frame target
    #    from that real pose — this is the closed-loop, policy part.
    obs = sim.observe()
    ox, oy, oz = arm_frame_offset((obs["base"]["x"], obs["base"]["y"]), obs["base"]["heading"], ARM_MOUNT[ARM], cup)
    ox, oy, oz = clamp(ox, 0.05, 0.45), clamp(oy, -0.35, 0.35), clamp(oz, 0.0, 0.5)
    r2 = sim.reach(ARM, ox, oy, oz)
    rollout.append(step("move_arm", x=ox, y=oy, z=oz, sim_outcome=r2["outcome"]))

    # 3. Grasp at the grant's force ceiling.
    r3 = sim.grasp(ARM)
    rollout.append(step("grasp", force=GRASP_FORCE_N, sim_outcome=r3["outcome"]))
    held = sim.observe()["holding"][ARM]

    # 4. Carry it home.
    r4 = sim.drive(HOME_XY[0], HOME_XY[1], 0.4)
    rollout.append(step("move_base", x=HOME_XY[0], y=HOME_XY[1], speed=0.4, sim_outcome=r4["outcome"]))

    final = sim.observe()
    success = bool(final["holding"][ARM]) and held
    tip = np.array(final["ee"][ARM])
    dist_final = float(np.linalg.norm(tip - np.array(final["cup"])))
    return rollout, success, dist_final


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/xlerobot_rollout.json"
    rollout, success, dist_final = run_policy()
    with open(out_path, "w") as f:
        json.dump({"policy": "did:lex:policy:xlerobot-reach-greedy", "steps": rollout}, f)
    print(f"policy eval: {'SUCCESS' if success else 'FAILED'} — {len(rollout)} skill calls, "
          f"final EE-cup distance {dist_final:.3f}m")
    print(f"rollout written: {out_path}")
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
