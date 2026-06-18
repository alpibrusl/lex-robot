#!/usr/bin/env bash
# End-to-end on the SIMULATED perimeter (no KVM, no GPU): proves the robot
# agent proposes skills, the supervisor mediates + audits, the guest executes
# against the sidecar, and the two audit chains corroborate.
#
# NOT a security boundary — see box/README.md §4 for the real Firecracker run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEXOS="$ROOT/../lex-os"
M="$ROOT/manifests/pick_place.capsule.json"
AUDIT=/tmp/robot-audit.json
TRAIL=/tmp/robot-trail.json

# Uses the dependency-free sim_sidecar (stdlib only) so the wiring gate runs
# anywhere — no gym/torch/KVM/GPU. gym_sidecar.py is the real-physics backend
# for the hardware run (box/run_in_vm.sh) and Issue #2's policy work.
cd "$ROOT"
LEX_ROBOT_TRAIL="$TRAIL" python3 sidecar/sim_sidecar.py & SIDECAR=$!
trap 'kill $SIDECAR 2>/dev/null || true' EXIT
sleep 2

cd "$LEXOS"
LEX_ROBOT_SIDECAR=http://127.0.0.1:8900 \
  GIT_CONFIG_NOSYSTEM=1 cargo run -q -p lex-os -- run \
  --manifest "$M" --agent robot --simulated --audit-out "$AUDIT"

echo "== reconcile =="
python3 "$ROOT/scripts/reconcile_audit.py" "$AUDIT" "$TRAIL"
