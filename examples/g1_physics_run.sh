#!/usr/bin/env bash
# examples/g1_physics_run.sh — Tier 3: the grant on the real Unitree G1 (#67).
#
# Runs the same policy intent twice — raw vs through the Lex grant gate
# (examples/govern_commands.lex) — on the REAL Unitree G1 humanoid (MuJoCo
# Menagerie URDF): the G1 right arm reaches a truck charge port and seats a
# connector (contact-rich insertion + rigid weld). The governed seat succeeds and
# its robot_task trail verifies; the ungoverned over-force stalls on the firmware
# floor. The loop end to end:
#   policy intent → grant gate (Lex) → real G1 kinematics → trail → verify.
#
# Out-of-band: needs Python + mujoco + numpy + the G1 model (NOT a CI dependency).
# Creates a throwaway venv ($VENV) and sparse-checks-out the G1 model ($LEX_G1_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="${VENV:-/tmp/lex-robot-mjenv}"
OUTDIR="${OUTDIR:-/tmp/g1_physics}"
LEX_BIN="${LEX_BIN:-$(command -v lex)}"
LEX_G1_DIR="${LEX_G1_DIR:-/tmp/menagerie/unitree_g1}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "→ creating venv at $VENV (mujoco + numpy)"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet mujoco numpy
fi

if [ ! -f "$LEX_G1_DIR/g1_with_hands.xml" ]; then
  echo "→ sparse-checking-out the Unitree G1 model into $LEX_G1_DIR"
  men="$(dirname "$LEX_G1_DIR")"
  git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/google-deepmind/mujoco_menagerie.git "$men"
  git -C "$men" sparse-checkout set unitree_g1
fi

echo "→ contact-rich validation on the real G1 (Lex governs, MuJoCo simulates)"
LEX_BIN="$LEX_BIN" LEX_G1_DIR="$LEX_G1_DIR" OUTDIR="$OUTDIR" \
  "$VENV/bin/python" examples/physics/g1_validate.py

echo
echo "→ verifying the governed episode trail through robot_task"
lex run --allow-effects io examples/robot_verify.lex verify "\"$OUTDIR/trail.jsonl\"" | grep '^{'
echo
echo "✓ Tier 3 complete: the grant holds on the real G1 kinematics, and its episode verifies."
