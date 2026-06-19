#!/usr/bin/env bash
# lex-games Bazaar Draft — a competitive shopping game.
#   :8900  game server + UI (bazaar_game_web.html)
# You are P1; an A2A agent is P2. Take turns drafting from a shared, limited pool
# under a budget — highest total value wins. Moves are capability-gated (a "cheat"
# drafting as P2 is refused) and hash-chained. Open http://localhost:8900.
#
# Usage: examples/bazaar_game_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup() { echo "[bazaar-game] stopping..."; kill "$SRV_PID" "$BOT_PID" 2>/dev/null || true; wait "$SRV_PID" "$BOT_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
pkill -f "bazaar_bot.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db"

echo "[bazaar-game] starting game server on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=bazaar_game_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${REPO_DIR}/sidecar/sim_sidecar.lex" run &
SRV_PID=$!

for i in $(seq 1 20); do curl -sf "${DASH_URL}/health" >/dev/null 2>&1 && break; sleep 0.5; done

echo "[bazaar-game] starting P2 shopper bot (independent agent over A2A) ..."
SHOP_SERVER="${DASH_URL}" \
  lex run --allow-effects env,io,net,time "${REPO_DIR}/examples/bazaar_bot.lex" run &
BOT_PID=$!

echo ""
echo "[bazaar-game] play at ${DASH_URL}  — you are P1 (click to draft); P2 is an A2A agent"
echo ""
read -rp "Press Enter to stop..."
