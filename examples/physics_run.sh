#!/usr/bin/env bash
# Start MuJoCo physics server + dashboard sidecar, then run nav_demo.lex.
# Usage: examples/physics_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PHYSICS_PORT=9000
PHYSICS_URL="http://localhost:${PHYSICS_PORT}"
SIDECAR_PORT=8900
SIDECAR_URL="http://localhost:${SIDECAR_PORT}"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time --allow-proc sh"
SIDECAR="${REPO_DIR}/sidecar/sim_sidecar.lex"

cleanup() {
  echo "[physics_run] stopping..."
  kill "$PHYS_PID" "$SIDE_PID" 2>/dev/null || true
  wait "$PHYS_PID" "$SIDE_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Physics server ────────────────────────────────────────────────────────────
echo "[physics_run] starting MuJoCo physics server on :${PHYSICS_PORT} ..."
PHYSICS_PORT=${PHYSICS_PORT} "${REPO_DIR}/.venv/bin/python3" \
  "${REPO_DIR}/gym_env/server.py" &
PHYS_PID=$!

# ── Dashboard sidecar (with physics forwarding) ───────────────────────────────
echo "[physics_run] starting sidecar on :${SIDECAR_PORT} (PHYSICS_URL=${PHYSICS_URL}) ..."
PHYSICS_URL=${PHYSICS_URL} \
LEX_ROBOT_SIDECAR_PORT=${SIDECAR_PORT} \
LEX_ROBOT_REPO_ROOT=${REPO_DIR} \
LEX_DASHBOARD_HTML=bazaar_web.html \
  ${LEX_RUN} "${SIDECAR}" run &
SIDE_PID=$!

# ── Wait for both to be healthy ───────────────────────────────────────────────
wait_up() {
  local url=$1 label=$2
  for i in $(seq 1 20); do
    if curl -sf "${url}/health" >/dev/null 2>&1; then
      echo "[physics_run] ${label} healthy"
      return 0
    fi
    sleep 0.5
  done
  echo "[physics_run] ERROR: ${label} did not start"
  exit 1
}

wait_up "${PHYSICS_URL}" "physics"
wait_up "${SIDECAR_URL}" "sidecar"

# ── Run nav demo ──────────────────────────────────────────────────────────────
echo "[physics_run] running nav_demo.lex ..."
SIDECAR_URL=${SIDECAR_URL} \
  lex run --allow-effects env,io,net,time \
  "${REPO_DIR}/examples/nav_demo.lex" run

echo "[physics_run] done — dashboard at http://localhost:${SIDECAR_PORT}"
read -rp "Press Enter to stop..."
