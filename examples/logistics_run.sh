#!/usr/bin/env bash
# Logistics demo: supplier agents restock the bazaar over A2A, with the
# delivery history written as a hash-chained lex-trail provenance log.
#   :8900  dashboard   — event hub + web UI (logistics_web.html)
#   :8901  pottery     :8902  textile     :8903  spices   (bazaar stalls / retailers)
#
# Usage: examples/logistics_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"
SIDECAR="${REPO_DIR}/sidecar/sim_sidecar.lex"

cleanup() {
  echo "[logistics] stopping..."
  kill "$DASH_PID" "$POT_PID" "$TEX_PID" "$SPI_PID" 2>/dev/null || true
  wait "$DASH_PID" "$POT_PID" "$TEX_PID" "$SPI_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${DASH_PORT}.db" /tmp/lex-sidecar-8901.db /tmp/lex-sidecar-8902.db /tmp/lex-sidecar-8903.db /tmp/lex-logistics.db

echo "[logistics] starting dashboard on :${DASH_PORT} ..."
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" LEX_DASHBOARD_HTML=logistics_web.html LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
  ${LEX_RUN} "${SIDECAR}" run &
DASH_PID=$!

echo "[logistics] starting stalls (pottery/textile/spices) ..."
LEX_STALL_NAME=pottery LEX_ROBOT_SIDECAR_PORT=8901 LEX_DASHBOARD_URL=${DASH_URL} LEX_ROBOT_REPO_ROOT="${REPO_DIR}" ${LEX_RUN} "${SIDECAR}" run & POT_PID=$!
LEX_STALL_NAME=textile LEX_ROBOT_SIDECAR_PORT=8902 LEX_DASHBOARD_URL=${DASH_URL} LEX_ROBOT_REPO_ROOT="${REPO_DIR}" ${LEX_RUN} "${SIDECAR}" run & TEX_PID=$!
LEX_STALL_NAME=spices  LEX_ROBOT_SIDECAR_PORT=8903 LEX_DASHBOARD_URL=${DASH_URL} LEX_ROBOT_REPO_ROOT="${REPO_DIR}" ${LEX_RUN} "${SIDECAR}" run & SPI_PID=$!

wait_up() {
  local url=$1 label=$2
  for i in $(seq 1 20); do
    if curl -sf "${url}/health" >/dev/null 2>&1; then echo "[logistics] ${label} healthy"; return 0; fi
    sleep 0.5
  done
  echo "[logistics] ERROR: ${label} did not start at ${url}"; exit 1
}
wait_up "${DASH_URL}"                 "dashboard"
wait_up "http://localhost:8901"       "pottery"
wait_up "http://localhost:8902"       "textile"
wait_up "http://localhost:8903"       "spices"

echo ""
echo "[logistics] dashboard: ${DASH_URL}"
echo "[logistics] launching suppliers — restock the bazaar over A2A"
echo ""
LOG_DASH_URL="${DASH_URL}" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,net,proc,sense,sql,time \
  "${REPO_DIR}/examples/logistics.lex" run

echo ""
echo "[logistics] done — provenance chain at /tmp/lex-logistics.db · dashboard at ${DASH_URL}"
read -rp "Press Enter to stop all services..."
