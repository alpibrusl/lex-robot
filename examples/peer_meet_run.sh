#!/usr/bin/env bash
# Peer-meet demo: two robots that never met.
#   :8900  dashboard   — event hub + web UI (peer_web.html)
#   :9100  Robot B     — a charging peer (own A2A identity, charge_battery skill)
# Robot A (examples/peer_meet.lex) meets B only by scanning B's bootstrap-blob QR,
# runs the A2A handshake, and buys charge — every payment gated by lex-guard.
#
# Usage: examples/peer_meet_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
B_PORT=9100
DASH_URL="http://localhost:${DASH_PORT}"
B_URL="http://localhost:${B_PORT}"

LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"
SIDECAR="${REPO_DIR}/sidecar/sim_sidecar.lex"

cleanup() {
  echo "[peer_meet] stopping..."
  kill "$DASH_PID" "$B_PID" 2>/dev/null || true
  wait "$DASH_PID" "$B_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db" "/tmp/lex-sidecar-${B_PORT}.db" /tmp/lex-peer-guard.db

# ── Dashboard ─────────────────────────────────────────────────────────────────
echo "[peer_meet] starting dashboard on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" \
LEX_DASHBOARD_HTML=peer_web.html \
LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${SIDECAR}" run &
DASH_PID=$!

# ── Robot B (charging peer) — a standalone program, NOT the bazaar sidecar ────
echo "[peer_meet] starting Robot B (standalone peer) on :${B_PORT} ..."
PEER_B_PORT=${B_PORT} \
  ${LEX_RUN} "${REPO_DIR}/examples/peer_provider.lex" run &
B_PID=$!

wait_up() {
  local url=$1 label=$2
  for i in $(seq 1 20); do
    if curl -sf "${url}/health" >/dev/null 2>&1; then echo "[peer_meet] ${label} healthy"; return 0; fi
    sleep 0.5
  done
  echo "[peer_meet] ERROR: ${label} did not start at ${url}"; exit 1
}
wait_up "${DASH_URL}" "dashboard"
wait_up "${B_URL}"    "robot-b"

echo ""
echo "[peer_meet] dashboard: ${DASH_URL}"
echo "[peer_meet] launching Robot A — meets B via QR, buys charge (lex-guard gated)"
echo ""
PEER_DASH_URL="${DASH_URL}" \
PEER_B_URL="${B_URL}" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,net,proc,sense,sql,time \
  "${REPO_DIR}/examples/peer_meet.lex" run

echo ""
echo "[peer_meet] done — dashboard at ${DASH_URL}"
read -rp "Press Enter to stop all services..."
