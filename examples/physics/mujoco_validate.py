#!/usr/bin/env python3
"""Tier 2 — make the grant PHYSICALLY meaningful (lex-robot epic #63, issue #66).

Tiers 0/1 prove governance *symbolically*: the grant clamps a force and blocks an
out-of-workspace move, and a robot_task trail replays to a clean verdict. But a
clamp only matters if less force actually reaches the world, and a keep-out bound
only matters if the end-effector actually stays out. This harness closes that gap
in real rigid-body physics (MuJoCo): it runs the SAME policy intent twice — once
raw (ungoverned), once through the Lex grant gate (examples/govern_commands.lex) —
and measures the difference in contact force and in how far the end-effector
penetrates the keep-out region.

Lex governs, MuJoCo simulates: the Python side never decides what is allowed. It
hands the raw command to `lex run examples/govern_commands.lex`, which applies the
grant (same semantics as src/grant.lex: clamp_grip + in_workspace) and returns the
governed command plus a robot_task trail. Python only executes whichever command
it is given and reads the resulting physics.

Out-of-band (needs a venv with mujoco+numpy — see examples/physics_run.sh); not run
in CI, which stays ML-dep-free. Exits nonzero if the governed run fails its safety
property, so it is a real check, not a demo.
"""
import json
import os
import subprocess
import sys

import mujoco
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
GOVERN_LEX = os.path.join(REPO, "examples", "govern_commands.lex")

# The grant's physical envelope (must match examples/govern_commands.lex).
WS_MAX_X_M = 1.0       # workspace edge; x > 1.0 m is the keep-out region
GRIP_CAP_N = 20.0      # grip ceiling

# ── two minimal scenes ───────────────────────────────────────────────────────
# Keep-out: a 1-DOF end-effector driven to a commanded x by a position servo.
SCENE_KEEPOUT = """
<mujoco>
  <option gravity="0 0 0" timestep="0.002"/>
  <worldbody>
    <body name="ee" pos="0 0 0">
      <joint name="ee_x" type="slide" axis="1 0 0" range="-0.2 2.0" damping="60"/>
      <geom type="sphere" size="0.04" rgba="0.2 0.6 1 1"/>
    </body>
  </worldbody>
  <actuator><position name="servo" joint="ee_x" kp="200" ctrlrange="-0.2 2.0"/></actuator>
</mujoco>
"""

# Force: the end-effector is pushed by a force actuator into a fixed wall; the
# contact normal force actually transmitted is summed from the solver's contacts.
SCENE_FORCE = """
<mujoco>
  <option gravity="0 0 0" timestep="0.002"/>
  <worldbody>
    <body name="ee" pos="0 0 0">
      <joint name="ee_x" type="slide" axis="1 0 0" range="-0.2 0.5" damping="20"/>
      <geom type="box" size="0.05 0.05 0.05" rgba="0.2 0.6 1 1"/>
    </body>
    <body name="wall" pos="0.22 0 0">
      <geom type="box" size="0.02 0.2 0.2" rgba="0.6 0.6 0.6 1"/>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="ee_x" gear="1" ctrlrange="0 400"/></actuator>
</mujoco>
"""

SETTLE_STEPS = 3000


def run_keepout(target_m: float) -> float:
    """Command the servo to target_m; return the deepest x the EE reaches."""
    model = mujoco.MjModel.from_xml_string(SCENE_KEEPOUT)
    data = mujoco.MjData(model)
    data.ctrl[0] = target_m
    peak = 0.0
    for _ in range(SETTLE_STEPS):
        mujoco.mj_step(model, data)
        peak = max(peak, float(data.qpos[0]))
    return peak


def run_force(force_n: float) -> float:
    """Push the EE into the wall with force_n; return the measured contact force."""
    model = mujoco.MjModel.from_xml_string(SCENE_FORCE)
    data = mujoco.MjData(model)
    data.ctrl[0] = force_n
    for _ in range(SETTLE_STEPS):
        mujoco.mj_step(model, data)
    # Sum the normal component of every solver contact actually transmitted.
    total = 0.0
    buf = np.zeros(6)
    for c in range(data.ncon):
        mujoco.mj_contactForce(model, data, c, buf)
        total += abs(float(buf[0]))
    return total


def govern(raw: dict, outdir: str) -> dict:
    """Hand the raw command to the Lex grant gate; return the governed command.

    The trail it also emits (trail.jsonl) is verified separately by the run script.
    """
    raw_path = os.path.join(outdir, "raw.json")
    gov_path = os.path.join(outdir, "governed.json")
    trail_path = os.path.join(outdir, "trail.jsonl")
    with open(raw_path, "w") as f:
        json.dump(raw, f)
    lex = os.environ.get("LEX_BIN", "lex")
    proc = subprocess.run(
        [lex, "run", "--allow-effects", "io,sql,time,fs_write", GOVERN_LEX,
         "govern", f'"{raw_path}"', f'"{gov_path}"', f'"{trail_path}"'],
        cwd=REPO, capture_output=True, text=True,
    )
    if proc.returncode != 0 or not os.path.exists(gov_path):
        sys.exit(f"govern_commands.lex failed:\n{proc.stdout}\n{proc.stderr}")
    with open(gov_path) as f:
        gov = json.load(f)
    gov["_trail"] = trail_path
    return gov


def main() -> int:
    outdir = os.environ.get("OUTDIR", "/tmp/mj_physics")
    os.makedirs(outdir, exist_ok=True)

    # The policy intent: reach 1.5 m (0.5 m into the keep-out) and grasp at 250 N.
    raw = {"target_x_mm": 1500, "grasp_force_mn": 250000}
    intent_x = raw["target_x_mm"] / 1000.0
    intent_f = raw["grasp_force_mn"] / 1000.0

    gov = govern(raw, outdir)
    gov_x = gov["target_x_mm"] / 1000.0
    gov_f = gov["grasp_force_mn"] / 1000.0

    # Same intent, two regimes, measured in physics.
    ung_reach = run_keepout(intent_x)
    gov_reach = run_keepout(gov_x)
    ung_force = run_force(intent_f)
    gov_force = run_force(gov_f)

    def depth(x):  # penetration into the keep-out region (x > WS_MAX_X_M)
        return max(0.0, x - WS_MAX_X_M)

    print("=== Tier 2: the grant, measured in MuJoCo rigid-body physics ===")
    print(f"policy intent: move to x={intent_x:.2f} m, grasp at {intent_f:.0f} N")
    print(f"grant gate (Lex): move→x={gov_x:.2f} m (blocked={gov['blocked']}), grasp→{gov_f:.0f} N\n")
    print(f"{'property':<26}{'UNGOVERNED':>14}{'GOVERNED':>12}")
    print(f"{'-'*52}")
    print(f"{'end-effector reach (m)':<26}{ung_reach:>14.3f}{gov_reach:>12.3f}")
    print(f"{'keep-out penetration (m)':<26}{depth(ung_reach):>14.3f}{depth(gov_reach):>12.3f}")
    print(f"{'contact force (N)':<26}{ung_force:>14.1f}{gov_force:>12.1f}\n")

    ok = True
    if depth(gov_reach) > 1e-3:
        print(f"FAIL: governed EE entered keep-out by {depth(gov_reach):.3f} m"); ok = False
    if depth(ung_reach) <= 1e-3:
        print("FAIL: ungoverned EE did not enter keep-out — scene not exercising the bound"); ok = False
    if gov_force > GRIP_CAP_N * 1.25:
        print(f"FAIL: governed contact force {gov_force:.1f} N exceeds the {GRIP_CAP_N} N ceiling"); ok = False
    if ung_force <= gov_force * 2:
        print("FAIL: ungoverned force not materially higher — clamp not demonstrated"); ok = False

    if ok:
        print(f"PASS: grant kept the EE out of the keep-out (penetration {depth(ung_reach):.2f} m → "
              f"{depth(gov_reach):.2f} m) and cut contact force {ung_force:.0f} N → {gov_force:.0f} N.")
        print(f"governed trail: {gov['_trail']}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
