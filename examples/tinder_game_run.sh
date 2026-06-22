#!/usr/bin/env bash
# lex-games Consent Match — a matchmaking game by mutual consent.
#   :8900  game server + UI (tinder_game_web.html)
# You are P1; an A2A agent is P2. Take turns swiping right on a shared deck of
# candidates. A match needs double opt-in (the candidate must seek what you
# offer); only then is the signed private card revealed. Highest matched charm
# wins. Swipes are capability-gated (a "swipe as P2" cheat is refused) and
# hash-chained. Open http://localhost:8900.
#
# Usage: examples/tinder_game_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup() { echo "[consent-match] stopping..."; kill "$SRV_PID" "$BOT_PID" 2>/dev/null || true; wait "$SRV_PID" "$BOT_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
pkill -f "tinder_bot.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db"

echo "[consent-match] starting game server on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=tinder_game_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${REPO_DIR}/sidecar/sim_sidecar.lex" run &
SRV_PID=$!

for i in $(seq 1 20); do curl -sf "${DASH_URL}/health" >/dev/null 2>&1 && break; sleep 0.5; done

echo "[consent-match] starting P2 dater bot (independent agent over A2A) ..."
LOVE_SERVER="${DASH_URL}" \
  lex run --allow-effects env,io,net,time "${REPO_DIR}/examples/tinder_bot.lex" run &
BOT_PID=$!

echo ""
echo "[consent-match] play at ${DASH_URL}  — you are P1 (click to swipe right); P2 is an A2A agent"
echo ""
read -rp "Press Enter to stop..."
