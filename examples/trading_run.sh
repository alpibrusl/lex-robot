#!/usr/bin/env bash
# examples/trading_run.sh — Start the 4-sidecar trading floor and run the demo.
#
# Sidecar layout:
#   :8900  dashboard              — event hub + web UI (http://localhost:8900)
#   :8901  Quantum Chips Exchange — quantum computing components
#   :8902  Solar Energy Markets   — renewable energy credits
#   :8903  Water Credits Trading  — water rights and credits
#
# Usage:
#   VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
#   VERTEX_PROJECT=elusmart-dev \
#   bash examples/trading_run.sh
#
#   bash examples/trading_run.sh sellers   # start all 4 sidecars only (Ctrl-C to stop)
#   bash examples/trading_run.sh traders   # run demo only (sidecars must be up)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR="$REPO_DIR/sidecar/sim_sidecar.lex"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time --allow-proc sh"

start_sellers() {
  echo "── Starting 4 sidecars ──────────────────────────────────────"
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_ROBOT_SIDECAR_PORT=8900 LEX_DASHBOARD_HTML=trading_web.html $LEX_RUN "$SIDECAR" run &
  PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_STALL_NAME=trading_quantum  LEX_ROBOT_SIDECAR_PORT=8901 $LEX_RUN "$SIDECAR" run &
  PID_QUANTUM=$!
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_STALL_NAME=trading_solar    LEX_ROBOT_SIDECAR_PORT=8902 $LEX_RUN "$SIDECAR" run &
  PID_SOLAR=$!
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_STALL_NAME=trading_water    LEX_ROBOT_SIDECAR_PORT=8903 $LEX_RUN "$SIDECAR" run &
  PID_WATER=$!

  for port in 8900 8901 8902 8903; do
    for i in $(seq 1 10); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
      sleep 0.5
    done
    curl -sf "http://127.0.0.1:$port/health" >/dev/null \
      || { echo "ERROR: sidecar on :$port did not start"; exit 1; }
  done
  echo "   dash :8900  quantum :8901  solar :8902  water :8903  — all healthy"
  echo "   Open http://localhost:8900 in your browser."
}

stop_sellers() {
  kill "$PID_DASH" "$PID_QUANTUM" "$PID_SOLAR" "$PID_WATER" 2>/dev/null || true
  wait "$PID_DASH" "$PID_QUANTUM" "$PID_SOLAR" "$PID_WATER" 2>/dev/null || true
  echo "── All sidecars stopped ──────────────────────────────────────"
}

run_traders() {
  echo "── Running trading floor demo ────────────────────────────────"
  lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO_DIR/examples/trading_demo.lex" run \
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
  traders)
    run_traders
    ;;
  all)
    start_sellers
    trap stop_sellers EXIT INT TERM
    run_traders
    echo ""
    echo "── Demo complete ─────────────────────────────────────────────"
    echo "   Dashboard still live at http://localhost:8900"
    echo "   Ctrl-C to stop all sidecars."
    wait
    ;;
  *)
    echo "Usage: $0 [sellers|traders|all]"
    exit 1
    ;;
esac
