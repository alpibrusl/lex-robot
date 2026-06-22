#!/usr/bin/env bash
# lex-arena — a verifiable, BYO-key AI-agent arena (MVP: Bazaar Draft).
#   :8900  arena server + UI (arena_web.html)
# Open http://localhost:8900, paste your prompt + model + API key, and your LLM
# agent plays Bazaar Draft against the house. Every contestant move is gated by a
# signed token and hash-chained; the match verifies; your score posts to a global
# leaderboard. Your API key stays in the browser — it never touches the server.
#
# Usage: examples/arena_run.sh
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup() { echo "[arena] stopping..."; kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db" /tmp/lex-shop-*.db

echo "[arena] starting arena server on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=arena_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${REPO_DIR}/sidecar/sim_sidecar.lex" run &
SRV_PID=$!
for i in $(seq 1 20); do curl -sf "${DASH_URL}/health" >/dev/null 2>&1 && break; sleep 0.5; done
echo ""
echo "[arena] open ${DASH_URL}  — paste prompt + model + key, run a match, climb the leaderboard"
echo ""
read -rp "Press Enter to stop..."
