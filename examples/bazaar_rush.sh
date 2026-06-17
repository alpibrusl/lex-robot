#!/usr/bin/env bash
# examples/bazaar_rush.sh — Start the 7-sidecar bazaar rush hour and run the demo.
#
# Sidecar layout:
#   :8900  dashboard         — event hub + web UI (http://localhost:8900)
#   :8901  Pottery Palace    — pottery stall
#   :8902  Textile Traders   — textile stall
#   :8903  Spice Garden      — spices stall
#   :8904  Clay Corner       — clay stall   (competing pottery)
#   :8905  Fabric House      — fabric stall (competing textile)
#   :8906  Herb Garden       — herb stall   (competing spices)
#
# Usage:
#   VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
#   VERTEX_PROJECT=elusmart-dev \
#   bash examples/bazaar_rush.sh
#
#   bash examples/bazaar_rush.sh sellers   # start all 7 only (Ctrl-C to stop)
#   bash examples/bazaar_rush.sh customer  # run demo only (sidecars must be up)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR="$REPO_DIR/sidecar/sim_sidecar.py"

start_sellers() {
  echo "── Starting 7 sidecars ──────────────────────────────────────"
  LEX_ROBOT_SIDECAR_PORT=8900                                python3 "$SIDECAR" &
  PID_DASH=$!
  LEX_STALL_NAME=pottery  LEX_ROBOT_SIDECAR_PORT=8901        python3 "$SIDECAR" &
  PID_POTTERY=$!
  LEX_STALL_NAME=textile  LEX_ROBOT_SIDECAR_PORT=8902        python3 "$SIDECAR" &
  PID_TEXTILE=$!
  LEX_STALL_NAME=spices   LEX_ROBOT_SIDECAR_PORT=8903        python3 "$SIDECAR" &
  PID_SPICES=$!
  LEX_STALL_NAME=clay     LEX_ROBOT_SIDECAR_PORT=8904        python3 "$SIDECAR" &
  PID_CLAY=$!
  LEX_STALL_NAME=fabric   LEX_ROBOT_SIDECAR_PORT=8905        python3 "$SIDECAR" &
  PID_FABRIC=$!
  LEX_STALL_NAME=herb     LEX_ROBOT_SIDECAR_PORT=8906        python3 "$SIDECAR" &
  PID_HERB=$!

  for port in 8900 8901 8902 8903 8904 8905 8906; do
    for i in $(seq 1 10); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
      sleep 0.5
    done
    curl -sf "http://127.0.0.1:$port/health" >/dev/null \
      || { echo "ERROR: sidecar on :$port did not start"; exit 1; }
  done
  echo "   dash :8900  pottery :8901  textile :8902  spices :8903"
  echo "   clay :8904  fabric  :8905  herb    :8906  — all healthy"
  echo "   Open http://localhost:8900 in your browser."
}

stop_sellers() {
  kill "$PID_DASH" "$PID_POTTERY" "$PID_TEXTILE" "$PID_SPICES" \
       "$PID_CLAY" "$PID_FABRIC" "$PID_HERB" 2>/dev/null || true
  wait "$PID_DASH" "$PID_POTTERY" "$PID_TEXTILE" "$PID_SPICES" \
       "$PID_CLAY" "$PID_FABRIC" "$PID_HERB" 2>/dev/null || true
  echo "── All sidecars stopped ──────────────────────────────────────"
}

run_customer() {
  echo "── Running rush hour demo ────────────────────────────────────"
  lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO_DIR/examples/bazaar_rush.lex" run \
    | grep -v '^null$' || true
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
  all)
    start_sellers
    trap stop_sellers EXIT INT TERM
    run_customer
    echo ""
    echo "── Demo complete ─────────────────────────────────────────────"
    echo "   Dashboard still live at http://localhost:8900"
    echo "   Ctrl-C to stop all sidecars."
    wait
    ;;
  *)
    echo "Usage: $0 [sellers|customer|all]"
    exit 1
    ;;
esac
