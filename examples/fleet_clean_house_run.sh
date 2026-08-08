#!/usr/bin/env bash
# Home-fleet room-claim demo: starts a real fleet_arbiter_server.lex, then
# runs examples/fleet_clean_house_demo.lex against it as a client.
#
# Usage: examples/fleet_clean_house_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARBITER_PORT=18910
ARBITER_URL="http://localhost:${ARBITER_PORT}"
DB="/tmp/lex-fleet-clean-house.db"

cleanup() {
  echo "[fleet_clean_house] stopping arbiter..."
  kill "$ARBITER_PID" 2>/dev/null || true
  wait "$ARBITER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

rm -f "$DB"

echo "[fleet_clean_house] starting fleet arbiter on :${ARBITER_PORT} ..."
lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
  "${REPO_DIR}/src/fleet_arbiter_server.lex" run "${ARBITER_PORT}" "\"${DB}\"" &
ARBITER_PID=$!

for i in $(seq 1 20); do
  if curl -s -o /dev/null "${ARBITER_URL}/" -d '{}'; then
    echo "[fleet_clean_house] arbiter up"
    break
  fi
  sleep 0.3
  if [ "$i" -eq 20 ]; then echo "[fleet_clean_house] ERROR: arbiter did not start"; exit 1; fi
done

echo ""
lex run --allow-effects io,net,time \
  "${REPO_DIR}/examples/fleet_clean_house_demo.lex" run "\"${ARBITER_URL}\""
