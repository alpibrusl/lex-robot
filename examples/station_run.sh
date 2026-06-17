#!/usr/bin/env bash
# examples/station_run.sh — Start the 5-sidecar space station and run the demo.
#
# Sidecar layout:
#   :8900  dashboard         — event hub + web UI (http://localhost:8900)
#   :8901  Life Support      — Alpha robot module
#   :8902  Navigation        — Beta robot module
#   :8903  Communications    — Gamma robot module
#   :8904  Cargo Bay         — Delta robot module (hull breach site)
#
# Usage:
#   VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
#   VERTEX_PROJECT=elusmart-dev \
#   bash examples/station_run.sh
#
#   bash examples/station_run.sh modules   # start all 5 sidecars only (Ctrl-C to stop)
#   bash examples/station_run.sh robots    # run demo only (sidecars must be up)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR="$REPO_DIR/sidecar/sim_sidecar.py"

start_modules() {
  echo "── Starting 5 sidecars ──────────────────────────────────────"
  LEX_ROBOT_SIDECAR_PORT=8900 LEX_DASHBOARD_HTML=station_web.html  python3 "$SIDECAR" &
  PID_DASH=$!
  LEX_STALL_NAME=station_life_support   LEX_ROBOT_SIDECAR_PORT=8901 python3 "$SIDECAR" &
  PID_LIFE=$!
  LEX_STALL_NAME=station_navigation     LEX_ROBOT_SIDECAR_PORT=8902 python3 "$SIDECAR" &
  PID_NAV=$!
  LEX_STALL_NAME=station_comms          LEX_ROBOT_SIDECAR_PORT=8903 python3 "$SIDECAR" &
  PID_COMMS=$!
  LEX_STALL_NAME=station_cargo          LEX_ROBOT_SIDECAR_PORT=8904 python3 "$SIDECAR" &
  PID_CARGO=$!

  for port in 8900 8901 8902 8903 8904; do
    for i in $(seq 1 10); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
      sleep 0.5
    done
    curl -sf "http://127.0.0.1:$port/health" >/dev/null \
      || { echo "ERROR: sidecar on :$port did not start"; exit 1; }
  done
  echo "   dash :8900  life-support :8901  navigation :8902"
  echo "   comms :8903  cargo-bay :8904  — all healthy"
  echo "   Open http://localhost:8900 in your browser."
}

stop_modules() {
  kill "$PID_DASH" "$PID_LIFE" "$PID_NAV" "$PID_COMMS" "$PID_CARGO" 2>/dev/null || true
  wait "$PID_DASH" "$PID_LIFE" "$PID_NAV" "$PID_COMMS" "$PID_CARGO" 2>/dev/null || true
  echo "── All sidecars stopped ──────────────────────────────────────"
}

run_robots() {
  echo "── Running space station emergency demo ──────────────────────"
  lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO_DIR/examples/station_demo.lex" run \
    | grep -v '^null$' || true
}

CMD="${1:-all}"

case "$CMD" in
  modules)
    start_modules
    echo "(modules running — Ctrl-C to stop)"
    trap stop_modules EXIT INT TERM
    wait
    ;;
  robots)
    run_robots
    ;;
  all)
    start_modules
    trap stop_modules EXIT INT TERM
    run_robots
    echo ""
    echo "── Demo complete ─────────────────────────────────────────────"
    echo "   Dashboard still live at http://localhost:8900"
    echo "   Ctrl-C to stop all sidecars."
    wait
    ;;
  *)
    echo "Usage: $0 [modules|robots|all]"
    exit 1
    ;;
esac
