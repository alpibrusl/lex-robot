#!/usr/bin/env bash
# Bazaar-visit demo: a robot with no prior key for a stall claims the
# physical approach space (fleet_traffic.lex, no trust needed), then
# verifies the stall's signed identity via the existing PULL handshake
# (examples/peer_meet.lex's own mechanism, reused via examples/peer_provider.lex
# as the stall) and negotiates. See examples/bazaar_visit_demo.lex's module
# comment for what this does and doesn't prove.
#
# Usage: examples/bazaar_visit_demo_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARBITER_PORT=18920
STALL_PORT=9100
ARBITER_URL="http://localhost:${ARBITER_PORT}"
STALL_URL="http://localhost:${STALL_PORT}"
DB="/tmp/lex-bazaar-visit-arbiter.db"

LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup() {
  echo "[bazaar_visit] stopping arbiter + stall..."
  kill "$ARBITER_PID" "$STALL_PID" 2>/dev/null || true
  wait "$ARBITER_PID" "$STALL_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

rm -f "$DB"

echo "[bazaar_visit] starting fleet arbiter on :${ARBITER_PORT} ..."
lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
  "${REPO_DIR}/src/fleet_arbiter_server.lex" run "${ARBITER_PORT}" "\"${DB}\"" &
ARBITER_PID=$!

echo "[bazaar_visit] starting the stall (a stranger's own A2A identity) on :${STALL_PORT} ..."
PEER_B_PORT=${STALL_PORT} \
  ${LEX_RUN} "${REPO_DIR}/examples/peer_provider.lex" run &
STALL_PID=$!

wait_up() {
  local url=$1 label=$2 method=$3
  for i in $(seq 1 20); do
    if [ "$method" = "get" ]; then
      curl -sf "${url}" >/dev/null 2>&1 && { echo "[bazaar_visit] ${label} up"; return 0; }
    else
      curl -s -o /dev/null "${url}" -d '{}' && { echo "[bazaar_visit] ${label} up"; return 0; }
    fi
    sleep 0.3
  done
  echo "[bazaar_visit] ERROR: ${label} did not start"; exit 1
}
wait_up "${ARBITER_URL}/" "arbiter" "post"
wait_up "${STALL_URL}/health" "stall" "get"

echo ""
BAZAAR_ARBITER_URL="${ARBITER_URL}" \
BAZAAR_STALL_URL="${STALL_URL}" \
  lex run --allow-effects env,fs_write,io,net,sense,sql,time \
  "${REPO_DIR}/examples/bazaar_visit_demo.lex" run
