#!/usr/bin/env bash
# lex-games Co-op Infiltration — a cooperative heist.
#   :8900  game server + UI (heist_game_web.html)
# You are the Hacker (P1); an A2A agent is the Muscle (P2). Clear a 6-stage path
# to the vault IN ORDER — but each of you can only defeat the stages your role
# holds the capability for (electronic → Hacker, physical → Muscle). Forcing a
# stage you can't trips a shared alarm; three trips and you're busted. Clear all
# six together to secure the loot. Every clear is hash-chained. Open
# http://localhost:8900.
#
# Usage: examples/heist_coop_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup() { echo "[coop-heist] stopping..."; kill "$SRV_PID" "$BOT_PID" 2>/dev/null || true; wait "$SRV_PID" "$BOT_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
pkill -f "heist_bot.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db"

echo "[coop-heist] starting game server on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=heist_game_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${REPO_DIR}/sidecar/sim_sidecar.lex" run &
SRV_PID=$!

for i in $(seq 1 20); do curl -sf "${DASH_URL}/health" >/dev/null 2>&1 && break; sleep 0.5; done

echo "[coop-heist] starting Muscle bot (independent co-op partner over A2A) ..."
HEIST_SERVER="${DASH_URL}" \
  lex run --allow-effects env,io,net,time "${REPO_DIR}/examples/heist_bot.lex" run &
BOT_PID=$!

echo ""
echo "[coop-heist] play at ${DASH_URL}  — you are P1/Hacker (click your stages); P2/Muscle is an A2A agent"
echo ""
read -rp "Press Enter to stop..."
