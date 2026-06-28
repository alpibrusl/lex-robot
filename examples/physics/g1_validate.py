#!/usr/bin/env python3
"""Tier 3 — the grant on a real robot's kinematics (lex-robot epic #63, issue #67).

Tier 2 (examples/physics/mujoco_validate.py) proved the grant is physically
meaningful on toy scenes. This tier runs the same governed loop against the
**real Unitree G1 humanoid** (MuJoCo Menagerie URDF): the G1's right arm reaches
across to a truck charge port and seats a connector — a contact-rich insertion
ending in a rigid weld — under the Lex grant. Same machinery as everywhere else
in the kernel; what changes is the fidelity: real humanoid kinematics, real
contact, a real mechanical join.

The claim it validates: governance survives contact with a real robot model. The
SAME policy intent (seat the connector at 99 N) is run twice —

  * ungoverned: 99 N reaches the actuator → trips the arm's firmware force floor
    → the seat STALLS (on hardware, an unsafe slam the backstop has to catch);
  * governed: the Lex grant gate (examples/govern_commands.lex) clamps 99 N to
    the grip ceiling BEFORE it is ever sent → the connector seats cleanly and a
    rigid weld locks it in the inlet.

— and the governed episode's robot_task trail replays to a clean verdict. Lex
governs, MuJoCo simulates: the harness reuses the production G1 sidecar
(sidecar/depot_g1_sidecar.py) for the physics and never decides the force itself.

Out-of-band (needs mujoco+numpy AND the G1 model via LEX_G1_DIR — see
examples/g1_physics_run.sh); not run in CI, which stays ML-dep-free.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
GOVERN_LEX = os.path.join(REPO, "examples", "govern_commands.lex")
sys.path.insert(0, os.path.join(REPO, "sidecar"))

# Reach the connector slightly past the inlet face, into the bore, so the tip
# seats inside the alignment tolerance (insertion, not just touching the face).
PRESS = 0.05


def govern(raw: dict, outdir: str) -> dict:
    """Hand the raw command to the Lex grant gate; return the governed command.

    The trail it also emits (trail.jsonl) — move into the workspace + a clamped
    grasp — is the governed episode, verified separately by the run script.
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


def seat(depot, force_n: float) -> dict:
    """Reset the G1, reach to the inlet, and try to seat the connector at force_n."""
    depot.reset()
    inlet = depot._inlet()
    depot.move_to(inlet["x"] - PRESS, inlet["y"], inlet["z"])
    r = depot.connect(force_n)
    return {"outcome": r["outcome"], "connected": bool(depot.connected),
            "dist": depot.dist(), "detail": r["detail"]}


def main() -> int:
    if not os.environ.get("LEX_G1_DIR") and not os.path.exists("/tmp/menagerie/unitree_g1"):
        sys.exit("set LEX_G1_DIR to a mujoco_menagerie/unitree_g1 checkout "
                 "(see examples/g1_physics_run.sh)")
    outdir = os.environ.get("OUTDIR", "/tmp/g1_physics")
    os.makedirs(outdir, exist_ok=True)

    import depot_g1_sidecar as g1

    # The policy intent: seat the connector at 99 N (over the firmware floor).
    raw = {"target_x_mm": 570, "grasp_force_mn": 99000}
    intent_f = raw["grasp_force_mn"] / 1000.0

    gov = govern(raw, outdir)
    gov_f = gov["grasp_force_mn"] / 1000.0

    print(f"=== Tier 3: the grant on the real Unitree G1 (MuJoCo, {g1.HARD_FORCE_N:.0f} N firmware floor) ===")
    print("loading the real G1 humanoid + truck charge port ...")
    depot = g1.DepotG1()

    ung = seat(depot, intent_f)              # ungoverned: 99 N as the policy asked
    gov_res = seat(depot, gov_f)             # governed: the grant-clamped force

    print(f"\npolicy intent: seat connector at {intent_f:.0f} N")
    print(f"grant gate (Lex): seat→{gov_f:.0f} N (blocked={gov['blocked']})\n")
    print(f"{'episode':<22}{'force (N)':>11}{'outcome':>11}{'seated':>9}{'tip-inlet (m)':>15}")
    print(f"{'-'*68}")
    print(f"{'ungoverned (99 N)':<22}{intent_f:>11.0f}{ung['outcome']:>11}{str(ung['connected']):>9}{ung['dist']:>15.3f}")
    print(f"{'governed (clamped)':<22}{gov_f:>11.0f}{gov_res['outcome']:>11}{str(gov_res['connected']):>9}{gov_res['dist']:>15.3f}\n")

    ok = True
    if gov_res["outcome"] != "reached" or not gov_res["connected"]:
        print(f"FAIL: governed seat did not complete on the G1 ({gov_res['detail']})"); ok = False
    if ung["connected"]:
        print("FAIL: ungoverned over-force seated anyway — firmware floor not exercised"); ok = False

    if ok:
        print(f"PASS: the grant clamped {intent_f:.0f} N → {gov_f:.0f} N, and the G1 seated + welded the "
              f"connector (tip-inlet {gov_res['dist']:.3f} m); the ungoverned {intent_f:.0f} N stalled on "
              f"the firmware floor.")
        print(f"governed trail: {gov['_trail']}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
