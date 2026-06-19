#!/usr/bin/env bash
# EV-fleet demo: vehicles charge under a shared fleet budget.
#   :8900  dashboard          — event hub + web UI (ev_web.html)
#   :9201  Standard charger   — 2 cr/kWh   (own A2A identity)
#   :9202  Fast charger       — 5 cr/kWh
#   :9203  Premium charger    — 9 cr/kWh
# The fleet (examples/ev_fleet.lex) meets each charger via its bootstrap QR,
# negotiates a price, and pays under one lex-guard fleet budget token.
#
# Usage: examples/ev_fleet_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
STD_PORT=9201; FAST_PORT=9202; PREM_PORT=9203

LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"
SIDECAR="${REPO_DIR}/sidecar/sim_sidecar.lex"
CHARGER="${REPO_DIR}/examples/ev_charger.lex"

cleanup() {
  echo "[ev_fleet] stopping..."
  kill "$DASH_PID" "$STD_PID" "$FAST_PID" "$PREM_PID" 2>/dev/null || true
  wait "$DASH_PID" "$STD_PID" "$FAST_PID" "$PREM_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
pkill -f "ev_charger.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db" /tmp/lex-ev-fleet.db

echo "[ev_fleet] starting dashboard on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=ev_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${SIDECAR}" run &
DASH_PID=$!

echo "[ev_fleet] starting chargers (Standard/Fast/Premium) ..."
CHARGER_PORT=${STD_PORT}  CHARGER_NAME=Standard CHARGER_RATE=2 ${LEX_RUN} "${CHARGER}" run & STD_PID=$!
CHARGER_PORT=${FAST_PORT} CHARGER_NAME=Fast     CHARGER_RATE=5 ${LEX_RUN} "${CHARGER}" run & FAST_PID=$!
CHARGER_PORT=${PREM_PORT} CHARGER_NAME=Premium  CHARGER_RATE=9 ${LEX_RUN} "${CHARGER}" run & PREM_PID=$!

wait_up() {
  local url=$1 label=$2
  for i in $(seq 1 20); do
    if curl -sf "${url}/health" >/dev/null 2>&1; then echo "[ev_fleet] ${label} healthy"; return 0; fi
    sleep 0.5
  done
  echo "[ev_fleet] ERROR: ${label} did not start at ${url}"; exit 1
}
wait_up "${DASH_URL}"                    "dashboard"
wait_up "http://localhost:${STD_PORT}"   "standard"
wait_up "http://localhost:${FAST_PORT}"  "fast"
wait_up "http://localhost:${PREM_PORT}"  "premium"

echo ""
echo "[ev_fleet] dashboard: ${DASH_URL}"
echo "[ev_fleet] launching fleet — meet chargers via QR, charge under the fleet budget"
echo ""
EV_DASH_URL="${DASH_URL}" \
EV_STD_URL="http://localhost:${STD_PORT}" \
EV_FAST_URL="http://localhost:${FAST_PORT}" \
EV_PREM_URL="http://localhost:${PREM_PORT}" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,net,proc,sense,sql,time \
  "${REPO_DIR}/examples/ev_fleet.lex" run

echo ""
echo "[ev_fleet] done — dashboard at ${DASH_URL}"
read -rp "Press Enter to stop all services..."
