#!/usr/bin/env bash
# examples/grant_physics_run.sh — Tier 2: the grant, validated in MuJoCo physics (#66).
#
# Runs the same policy intent twice — raw vs through the Lex grant gate
# (examples/govern_commands.lex) — in MuJoCo rigid-body physics, measures the
# difference in contact force and keep-out penetration, then replays the governed
# trail through lex-games' robot_task verifier. The loop end to end:
#   policy intent → grant gate (Lex) → MuJoCo physics → trail → verify.
#
# Out-of-band: needs Python + mujoco + numpy (NOT a CI dependency, like gym_env).
# Creates a throwaway venv unless one is provided via $VENV.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="${VENV:-/tmp/lex-robot-mjenv}"
OUTDIR="${OUTDIR:-/tmp/mj_physics}"
LEX_BIN="${LEX_BIN:-$(command -v lex)}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "→ creating venv at $VENV (mujoco + numpy)"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet mujoco numpy
fi

echo "→ physics validation (Lex governs, MuJoCo simulates)"
LEX_BIN="$LEX_BIN" OUTDIR="$OUTDIR" "$VENV/bin/python" examples/physics/mujoco_validate.py

echo
echo "→ verifying the governed episode trail through robot_task"
lex run --allow-effects io examples/robot_verify.lex verify "\"$OUTDIR/trail.jsonl\"" | grep '^{'
echo
echo "✓ Tier 2 complete: the grant is physically meaningful, and its episode verifies."
