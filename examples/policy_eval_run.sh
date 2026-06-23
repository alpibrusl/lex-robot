#!/usr/bin/env bash
# Live policy-eval leaderboard: boot the sim sidecar, then run several real
# rollouts under different ISO-derived grants + one forged submission, and rank
# them through the lex-games robot_task referee. Needs only `lex` + python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PORT="${LEX_ROBOT_SIDECAR_PORT:-8900}"
PY="${PYTHON:-python3}"
EFF="actuate,fs_write,io,net,sense,sql,time"

command -v lex >/dev/null || { echo "error: 'lex' not on PATH — see README Install" >&2; exit 1; }

# Start from fresh trail stores — tlog.open APPENDS, so a stale .db from a prior
# run would accumulate events and break the per-run hash chain.
rm -f /tmp/pe_compliant.db /tmp/pe_narrow.db /tmp/pe_starved.db

LOG="$(mktemp)"
"$PY" "sidecar/sim_sidecar.py" >"$LOG" 2>&1 &
SID=$!
cleanup() { kill "$SID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

echo "▶ examples/policy_eval.lex  (sidecar: sim_sidecar, effects: $EFF)"
lex run --allow-effects "$EFF" examples/policy_eval.lex run
