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
  xlerobot_task) SIDECAR=xlerobot_sidecar; FILE=examples/xlerobot_task.lex;  EFF="actuate,fs_write,io,net,sense,time" ;;
  xlerobot_voice) SIDECAR=xlerobot_sidecar; FILE=examples/xlerobot_voice_demo.lex; EFF="net,sense,io" ;;
  xlerobot_touch) SIDECAR=xlerobot_sidecar; FILE=examples/xlerobot_touch_demo.lex; EFF="net,sense,actuate,io" ;;
  xlerobot_vision) SIDECAR=xlerobot_sidecar; FILE=examples/vision_split_demo.lex; EFF="net,sense,actuate,io,env"; VISION=1 ;;
  vision_pose) SIDECAR=xlerobot_sidecar; FILE=examples/vision_pose_demo.lex;   EFF="net,sense,actuate,io"; VISION=1 ;;
  stream)      SIDECAR=xlerobot_sidecar; FILE=examples/stream_demo.lex;        EFF="io,net"; export LEX_STREAM_MAX_FRAMES="${LEX_STREAM_MAX_FRAMES:-3}" ;;
  home_wash)   SIDECAR=ha_sidecar;    FILE=examples/home_wash_demo.lex;      EFF="net,sense,actuate,io"; SIDECAR_EFF="env,fs_write,io,net,sql,time" ;;
  ap2)         SIDECAR=sim_sidecar;   FILE=examples/ap2_bazaar_demo.lex;     EFF="env,io,net,time"; AP2=1 ;;
  dispense)    SIDECAR=sim_sidecar;   FILE=examples/dispense_demo.lex;       EFF="actuate,fs_write,io,net,sense,sql,time" ;;
  xlerobot_find) SIDECAR=xlerobot_sidecar; FILE=examples/find_and_fetch_demo.lex; EFF="net,sense,actuate,io" ;;
  mcp_grant)   NO_SIDECAR=1;          FILE=tests/test_mcp_grant.lex;         EFF="io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate,approval" ;;
  a2a_grant)   NO_SIDECAR=1;          FILE=tests/test_a2a_robot_grant.lex;   EFF="io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate,stream,approval" ;;
  *) echo "unknown demo '$DEMO' (use: grant | llm | task | budget | depot | xlerobot | xlerobot_task | xlerobot_voice | xlerobot_touch | xlerobot_vision | vision_pose | stream | xlerobot_find | home_wash | ap2 | dispense | dynamic_keepout | tool_fire | mcp_grant | a2a_grant)" >&2; exit 2 ;;
esac

command -v lex >/dev/null || { echo "error: 'lex' not on PATH — see README Install" >&2; exit 1; }

if [ "$NO_SIDECAR" -eq 1 ]; then
  echo "▶ $FILE  (no sidecar, effects: $EFF)"
  lex run --allow-effects "$EFF" "$FILE" main
else
  # Split-compute vision demo: bring up the vision service FIRST (mock mode —
  # canned, labeled answers, no model) so the sidecar starts with
  # LEX_XLE_VISION_URL already pointing at it. Real deployments run the same
  # two processes on two machines — see deploy/VISION_SPLIT.md.
  VIS_PID=""
  if [ -n "${VISION:-}" ]; then
    VPORT="${LEX_VISION_PORT:-8901}"
    VLOG="$(mktemp)"
    LEX_VISION_MOCK="${LEX_VISION_MOCK:-1}" LEX_VISION_HOST=127.0.0.1 \
      "$PY" sidecar/vision_service.py >"$VLOG" 2>&1 &
    VIS_PID=$!
    for _ in $(seq 1 50); do
      if curl -sf "http://127.0.0.1:$VPORT/health" >/dev/null 2>&1; then break; fi
      sleep 0.1
    done
    export LEX_XLE_VISION_URL="http://127.0.0.1:$VPORT"
    export LEX_VISION_URL="http://127.0.0.1:$VPORT"
  fi

  # AP2 demo: the stall runs AS the pottery stall with the mandate wall up,
  # and a SECOND sim_sidecar instance plays the credential provider on :8910.
  CP_PID=""
  if [ -n "${AP2:-}" ]; then
    CPPORT="${LEX_AP2_CP_PORT:-8910}"
    CPLOG="$(mktemp)"
    LEX_ROLE=credential_provider LEX_ROBOT_SIDECAR_PORT="$CPPORT" \
      "$PY" sidecar/sim_sidecar.py >"$CPLOG" 2>&1 &
    CP_PID=$!
    for _ in $(seq 1 50); do
      if curl -sf "http://127.0.0.1:$CPPORT/health" >/dev/null 2>&1; then break; fi
      sleep 0.1
    done
    export LEX_AP2_CP_URL="http://127.0.0.1:$CPPORT"
    export LEX_STALL_NAME=pottery LEX_AP2=1
  fi

  LOG="$(mktemp)"
  # A sidecar that has a proven-identical Lex twin runs as Lex by default.
  # scripts/ha_parity.py asserts the two answer the same 28 requests
  # byte-for-byte, and scripts/smoke.sh runs it -- so this is a switch backed
  # by a test, not a hope. LEX_SIDECAR=0 falls back to the Python.
  if [ "${LEX_SIDECAR:-1}" = "1" ] && [ -f "sidecar/$SIDECAR.lex" ] && [ -n "${SIDECAR_EFF:-}" ]; then
    lex run --allow-effects "$SIDECAR_EFF" "sidecar/$SIDECAR.lex" run >"$LOG" 2>&1 &
  else
    "$PY" "sidecar/$SIDECAR.py" >"$LOG" 2>&1 &
  fi
  SID=$!
  cleanup() { kill "$SID" 2>/dev/null || true; [ -n "$VIS_PID" ] && kill "$VIS_PID" 2>/dev/null || true; [ -n "$CP_PID" ] && kill "$CP_PID" 2>/dev/null || true; }
  trap cleanup EXIT

  # Wait for the sidecar's /health (both stubs expose it).
  for _ in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done

  echo "▶ $FILE  (sidecar: $SIDECAR, effects: $EFF)"
  lex run --allow-effects "$EFF" "$FILE" run
fi
