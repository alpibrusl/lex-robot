#!/usr/bin/env bash
# Consent-matching demo: agents match only by MUTUAL consent (A2A double opt-in);
# private cards are revealed only after a match (selective disclosure).
#   :8900  dashboard — event hub + web UI (tinder_web.html)
#
# Usage: examples/tinder_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"
SIDECAR="${REPO_DIR}/sidecar/sim_sidecar.lex"

cleanup() {
  echo "[tinder] stopping..."
  kill "$DASH_PID" 2>/dev/null || true
  wait "$DASH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db"

echo "[tinder] starting dashboard on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=tinder_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${SIDECAR}" run &
DASH_PID=$!

for i in $(seq 1 20); do curl -sf "${DASH_URL}/health" >/dev/null 2>&1 && break; sleep 0.5; done
echo "[tinder] dashboard: ${DASH_URL}"
echo ""
TINDER_DASH_URL="${DASH_URL}" \
  lex run --allow-effects crypto,env,io,net,time \
  "${REPO_DIR}/examples/tinder.lex" run

echo ""
echo "[tinder] done — dashboard at ${DASH_URL}"
read -rp "Press Enter to stop all services..."
