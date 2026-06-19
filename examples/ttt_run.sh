#!/usr/bin/env bash
# lex-games tic-tac-toe — play it in the browser.
#   :8900  game server + board UI (ttt_web.html)
# You play X by clicking; a bot plays O. Moves are gated server-side
# (a "cheat" — claiming O — is refused by the capability layer) and every legal
# move is hash-chained. Open http://localhost:8900 and click.
#
# Usage: examples/ttt_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup() { echo "[ttt] stopping..."; kill "$SRV_PID" "$BOT_PID" 2>/dev/null || true; wait "$SRV_PID" "$BOT_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
pkill -f "ttt_bot.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db" /tmp/lex-ttt.db

echo "[ttt] starting game server on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=ttt_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${REPO_DIR}/sidecar/sim_sidecar.lex" run &
SRV_PID=$!

for i in $(seq 1 20); do curl -sf "${DASH_URL}/health" >/dev/null 2>&1 && break; sleep 0.5; done

echo "[ttt] starting O-bot (independent agent, plays O over A2A) ..."
TTT_SERVER="${DASH_URL}" \
  lex run --allow-effects env,io,net,time "${REPO_DIR}/examples/ttt_bot.lex" run &
BOT_PID=$!

echo ""
echo "[ttt] play at ${DASH_URL}  — you are X (click); O is an independent A2A agent"
echo ""
read -rp "Press Enter to stop..."
