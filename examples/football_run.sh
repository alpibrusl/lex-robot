#!/usr/bin/env bash
# lex-games Strategy Football — a human strategy, a squad of A2A agents.
#   :8900  game server + UI (football_web.html)
# YOU set the team strategy in the browser (possession / direct). A two-agent
# HOME squad (H0 + H1) then coordinates over A2A to break a presser and score on
# a 5-zone lane. Every action is gated by a hardened, match-bound Ed25519 token
# and recorded into a hash-chained lex-trail log — hit "Verify chain" to replay
# it and confirm it's tamper-evident. Open http://localhost:8900.
#
# Usage: examples/football_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup() { echo "[football] stopping..."; kill "$SRV_PID" "$H0_PID" "$H1_PID" 2>/dev/null || true; wait "$SRV_PID" "$H0_PID" "$H1_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
pkill -f "fb_bot.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db" /tmp/lex-fb-*.db

echo "[football] starting game server on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=football_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${REPO_DIR}/sidecar/sim_sidecar.lex" run &
SRV_PID=$!

for i in $(seq 1 20); do curl -sf "${DASH_URL}/health" >/dev/null 2>&1 && break; sleep 0.5; done

# Kick a match off with a default strategy (you can change it live in the UI).
curl -s -X POST "${DASH_URL}/skill/fb_reset" -H 'Content-Type: application/json' -d '{}' >/dev/null
curl -s -X POST "${DASH_URL}/skill/fb_strategy" -H 'Content-Type: application/json' -d '{"strategy":"possession"}' >/dev/null

echo "[football] starting HOME squad: H0 + H1 (independent agents over A2A) ..."
FB_SERVER="${DASH_URL}" FB_ROLE=H0 lex run --allow-effects env,io,net,time "${REPO_DIR}/examples/fb_bot.lex" run &
H0_PID=$!
FB_SERVER="${DASH_URL}" FB_ROLE=H1 lex run --allow-effects env,io,net,time "${REPO_DIR}/examples/fb_bot.lex" run &
H1_PID=$!

echo ""
echo "[football] watch at ${DASH_URL}  — set the strategy, then watch the squad execute it; hit Verify chain"
echo ""
read -rp "Press Enter to stop..."
