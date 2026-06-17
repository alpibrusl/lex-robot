#!/usr/bin/env bash
# examples/bazaar_run.sh — Start the robot bazaar and run the customer demo.
#
# 4-process layout:
#
#   :8900  dashboard sidecar  — event hub + web UI (http://localhost:8900)
#   :8901  POTTERY Palace     — sim sidecar (LEX_STALL_NAME=pottery)
#   :8902  TEXTILE Traders    — sim sidecar (LEX_STALL_NAME=textile)
#   :8903  SPICE Garden       — sim sidecar (LEX_STALL_NAME=spices)
#
# Usage:
#   bash examples/bazaar_run.sh          # start all 4 + run customer; sidecars stay
#                                        # alive until Ctrl-C so dashboard can be viewed
#   bash examples/bazaar_run.sh sellers  # start all 4 in background (Ctrl-C stops)
#   bash examples/bazaar_run.sh customer # run customer only (sidecars must be up)
#   bash examples/bazaar_run.sh unit     # offline unit test (no network)
#
# Requirements:
#   python3 (stdlib only — no pip install needed)
#   lex     (lex-robot interpreter)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR="$REPO_DIR/sidecar/sim_sidecar.py"

start_sellers() {
  echo "── Starting sidecars ─────────────────────────────────────────"
  # Dashboard / event hub (no stall — serves http://localhost:8900)
  LEX_ROBOT_SIDECAR_PORT=8900 python3 "$SIDECAR" &
  PID_DASH=$!
  LEX_STALL_NAME=pottery LEX_ROBOT_SIDECAR_PORT=8901 python3 "$SIDECAR" &
  PID_POTTERY=$!
  LEX_STALL_NAME=textile LEX_ROBOT_SIDECAR_PORT=8902 python3 "$SIDECAR" &
  PID_TEXTILE=$!
  LEX_STALL_NAME=spices  LEX_ROBOT_SIDECAR_PORT=8903 python3 "$SIDECAR" &
  PID_SPICES=$!

  # Wait until all four are healthy (up to 5 s each).
  for port in 8900 8901 8902 8903; do
    for i in $(seq 1 10); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
      sleep 0.5
    done
    curl -sf "http://127.0.0.1:$port/health" >/dev/null \
      || { echo "ERROR: sidecar on :$port did not start"; exit 1; }
  done
  echo "   dashboard :8900  pottery :8901  textile :8902  spices :8903  — all healthy"
  echo "   Open http://localhost:8900 in your browser, then run the customer."
}

stop_sellers() {
  kill "$PID_DASH" "$PID_POTTERY" "$PID_TEXTILE" "$PID_SPICES" 2>/dev/null || true
  wait "$PID_DASH" "$PID_POTTERY" "$PID_TEXTILE" "$PID_SPICES" 2>/dev/null || true
  echo "── All sidecars stopped ──────────────────────────────────────"
}

run_customer() {
  echo "── Running customer ──────────────────────────────────────────"
  # Filter the trailing "null" that lex run prints for Unit-returning functions.
  lex run --allow-effects fs_write,io,net,sense,sql,time \
      "$REPO_DIR/examples/bazaar_demo.lex" run \
    | grep -v '^null$' || true
}

run_unit() {
  echo "── Offline unit test (no network needed) ─────────────────────"
  lex run "$REPO_DIR/src/bazaar.lex" item_matches_test
}

CMD="${1:-all}"

case "$CMD" in
  sellers)
    start_sellers
    echo "(sellers running — Ctrl-C to stop)"
    trap stop_sellers EXIT INT TERM
    wait
    ;;
  customer)
    run_customer
    ;;
  unit)
    run_unit
    ;;
  all)
    start_sellers
    trap stop_sellers EXIT INT TERM
    run_customer
    echo ""
    echo "── Customer done ─────────────────────────────────────────────"
    echo "   Dashboard still live at http://localhost:8900"
    echo "   Ctrl-C to stop all sidecars."
    wait
    ;;
  *)
    echo "Usage: $0 [sellers|customer|unit|all]"
    exit 1
    ;;
esac
