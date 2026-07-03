#!/usr/bin/env bash
# Run one lex-robot demo end to end: start the right stub sidecar, wait for it,
# run the Lex program with the effects it needs, then stop the sidecar.
#
# Usage: scripts/demo.sh [grant|llm|task|budget|depot]   (default: llm)
# Needs only: the `lex` toolchain + python3 (no pip installs for these five).
set -euo pipefail

DEMO="${1:-llm}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PORT="${LEX_ROBOT_SIDECAR_PORT:-8900}"
PY="${PYTHON:-python3}"

NO_SIDECAR=0
case "$DEMO" in
  grant)       SIDECAR=sim_sidecar;   FILE=examples/demo.lex;                EFF="net,sense,actuate,io" ;;
  llm)         SIDECAR=sim_sidecar;   FILE=examples/llm_planner_demo.lex;    EFF="fs_write,io,net,sense,actuate,sql,time" ;;
  task)        SIDECAR=sim_sidecar;   FILE=examples/task_demo.lex;           EFF="net,sense,actuate,io,sql,fs_write,time" ;;
  budget)      SIDECAR=sim_sidecar;   FILE=examples/budget_demo.lex;         EFF="net,sense,actuate,io,sql,fs_write,time" ;;
  depot)       SIDECAR=depot_sidecar; FILE=examples/depot_demo.lex;          EFF="env,net,sense,actuate,io" ;;
  dynamic_keepout) SIDECAR=sim_sidecar; FILE=examples/dynamic_keepout.lex;   EFF="net,sense,actuate,io,sql,fs_write,time" ;;
  tool_fire)       SIDECAR=sim_sidecar; FILE=examples/tool_fire_demo.lex;    EFF="net,sense,actuate,io,sql,fs_write,time" ;;
  xlerobot)    SIDECAR=xlerobot_sidecar; FILE=examples/xlerobot_demo.lex;    EFF="net,sense,actuate,io" ;;
  mcp_grant)   NO_SIDECAR=1;          FILE=tests/test_mcp_grant.lex;         EFF="io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate" ;;
  *) echo "unknown demo '$DEMO' (use: grant | llm | task | budget | depot | xlerobot | dynamic_keepout | tool_fire | mcp_grant)" >&2; exit 2 ;;
esac

command -v lex >/dev/null || { echo "error: 'lex' not on PATH — see README Install" >&2; exit 1; }

if [ "$NO_SIDECAR" -eq 1 ]; then
  echo "▶ $FILE  (no sidecar, effects: $EFF)"
  lex run --allow-effects "$EFF" "$FILE" main
else
  LOG="$(mktemp)"
  "$PY" "sidecar/$SIDECAR.py" >"$LOG" 2>&1 &
  SID=$!
  cleanup() { kill "$SID" 2>/dev/null || true; }
  trap cleanup EXIT

  # Wait for the sidecar's /health (both stubs expose it).
  for _ in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done

  echo "▶ $FILE  (sidecar: $SIDECAR, effects: $EFF)"
  lex run --allow-effects "$EFF" "$FILE" run
fi
