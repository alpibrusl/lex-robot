#!/usr/bin/env bash
# Start physics + dashboard + 3 stall sidecars, then run the autonomous robot.
# Usage: examples/auto_bazaar_run.sh [ITEM] [QTY] [BUDGET]
# Defaults: Bowl / 2 / 50
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PHYSICS_PORT=9000
PHYSICS_URL="http://localhost:${PHYSICS_PORT}"
DASH_PORT=8900
DASH_URL="http://localhost:${DASH_PORT}"
POTTERY_PORT=8901
TEXTILE_PORT=8902
SPICES_PORT=8903

ITEM="${1:-Bowl}"
QTY="${2:-1}"
BUDGET="${3:-50}"

LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time --allow-proc sh"
SIDECAR="${REPO_DIR}/sidecar/sim_sidecar.lex"

cleanup() {
  echo "[auto_bazaar] stopping..."
  kill "$PHYS_PID" "$DASH_PID" "$POT_PID" "$TEX_PID" "$SPI_PID" 2>/dev/null || true
  wait "$PHYS_PID" "$DASH_PID" "$POT_PID" "$TEX_PID" "$SPI_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Kill any stale processes from previous runs ───────────────────────────────
pkill -f "sim_sidecar.lex" 2>/dev/null || true
pkill -f "gym_env/server.py" 2>/dev/null || true

# ── Fresh DB state (stale DBs from prior runs break A2A key registration) ────
echo "[auto_bazaar] clearing stale sidecar DBs ..."
rm -f /tmp/lex-sidecar-${DASH_PORT}.db \
      /tmp/lex-sidecar-${POTTERY_PORT}.db \
      /tmp/lex-sidecar-${TEXTILE_PORT}.db \
      /tmp/lex-sidecar-${SPICES_PORT}.db

# ── Physics server ────────────────────────────────────────────────────────────
echo "[auto_bazaar] starting MuJoCo physics server on :${PHYSICS_PORT} ..."
PHYSICS_PORT=${PHYSICS_PORT} "${REPO_DIR}/.venv/bin/python3" \
  "${REPO_DIR}/gym_env/server.py" &
PHYS_PID=$!

# ── Dashboard sidecar (with physics forwarding) ───────────────────────────────
echo "[auto_bazaar] starting dashboard sidecar on :${DASH_PORT} ..."
PHYSICS_URL=${PHYSICS_URL} \
LEX_ROBOT_SIDECAR_PORT=${DASH_PORT} \
LEX_ROBOT_REPO_ROOT=${REPO_DIR} \
LEX_DASHBOARD_HTML=bazaar_web.html \
  ${LEX_RUN} "${SIDECAR}" run &
DASH_PID=$!

# ── Stall sidecars (autonomous sellers — each runs an LLM to set prices) ─────
# VERTEX_ACCESS_TOKEN / VERTEX_PROJECT / VERTEX_LOCATION are inherited from the
# parent shell.  If not set, sellers fall back to static base prices.
echo "[auto_bazaar] starting pottery stall on :${POTTERY_PORT} (seller=llm) ..."
SELLER_LLM=1 \
LEX_STALL_NAME=pottery \
LEX_ROBOT_SIDECAR_PORT=${POTTERY_PORT} \
LEX_DASHBOARD_URL=${DASH_URL} \
LEX_ROBOT_REPO_ROOT=${REPO_DIR} \
  ${LEX_RUN} "${SIDECAR}" run &
POT_PID=$!

echo "[auto_bazaar] starting textile stall on :${TEXTILE_PORT} (seller=llm) ..."
SELLER_LLM=1 \
LEX_STALL_NAME=textile \
LEX_ROBOT_SIDECAR_PORT=${TEXTILE_PORT} \
LEX_DASHBOARD_URL=${DASH_URL} \
LEX_ROBOT_REPO_ROOT=${REPO_DIR} \
  ${LEX_RUN} "${SIDECAR}" run &
TEX_PID=$!

echo "[auto_bazaar] starting spices stall on :${SPICES_PORT} (seller=llm) ..."
SELLER_LLM=1 \
LEX_STALL_NAME=spices \
LEX_ROBOT_SIDECAR_PORT=${SPICES_PORT} \
LEX_DASHBOARD_URL=${DASH_URL} \
LEX_ROBOT_REPO_ROOT=${REPO_DIR} \
  ${LEX_RUN} "${SIDECAR}" run &
SPI_PID=$!

# ── Wait for all services to be healthy ──────────────────────────────────────
wait_up() {
  local url=$1 label=$2
  for i in $(seq 1 20); do
    if curl -sf "${url}/health" >/dev/null 2>&1; then
      echo "[auto_bazaar] ${label} healthy"
      return 0
    fi
    sleep 0.5
  done
  echo "[auto_bazaar] ERROR: ${label} did not start at ${url}"
  exit 1
}

wait_up "${PHYSICS_URL}"                    "physics"
wait_up "${DASH_URL}"                       "dashboard"
wait_up "http://localhost:${POTTERY_PORT}"  "pottery"
wait_up "http://localhost:${TEXTILE_PORT}"  "textile"
wait_up "http://localhost:${SPICES_PORT}"   "spices"

# ── Run autonomous agent ──────────────────────────────────────────────────────
# NOTE: AUTO_ITEMS is intentionally NOT set — the robot asks the HUMAN for the
# shopping goal via the dashboard and blocks until you answer (open the dashboard
# and type e.g.  "Bowl, Scarf, Saffron; 25"). AUTO_BUDGET is only the default if
# you omit the ";budget" part. To run scripted instead, set AUTO_ITEMS.
echo ""
echo "[auto_bazaar] launching agent — it will ASK YOU for the goal in the dashboard"
echo "[auto_bazaar] dashboard: ${DASH_URL}  (answer the 'What should I shop for?' prompt)"
echo ""
SIDECAR_URL=${DASH_URL} \
AUTO_BUDGET="${BUDGET}" \
  lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
  "${REPO_DIR}/examples/auto_bazaar.lex" run

echo ""
echo "[auto_bazaar] done — dashboard at ${DASH_URL}"
read -rp "Press Enter to stop all services..."
