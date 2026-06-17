#!/usr/bin/env bash
# examples/triage_run.sh — Start the 5-sidecar disaster triage demo and run the scenario.
#
# Sidecar layout:
#   :8900  dashboard      — event hub + web UI  (http://localhost:8900)
#   :8901  Zone Alpha     — sensor zone A
#   :8902  Zone Beta      — sensor zone B
#   :8903  Zone Gamma     — sensor zone G
#   :8904  Hospital HQ    — coordinator / dispatch hub
#
# Usage:
#   VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
#   VERTEX_PROJECT=elusmart-dev \
#   bash examples/triage_run.sh
#
#   bash examples/triage_run.sh sidecars  # start all 5 only (Ctrl-C to stop)
#   bash examples/triage_run.sh demo      # run demo only (sidecars must be up)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR="$REPO_DIR/sidecar/sim_sidecar.py"

start_sidecars() {
  echo "── Starting 5 sidecars ──────────────────────────────────────"
  LEX_DASHBOARD_HTML=triage_web.html  LEX_ROBOT_SIDECAR_PORT=8900               python3 "$SIDECAR" &
  PID_DASH=$!
  LEX_STALL_NAME=triage_zone_alpha    LEX_ROBOT_SIDECAR_PORT=8901               python3 "$SIDECAR" &
  PID_ALPHA=$!
  LEX_STALL_NAME=triage_zone_beta     LEX_ROBOT_SIDECAR_PORT=8902               python3 "$SIDECAR" &
  PID_BETA=$!
  LEX_STALL_NAME=triage_zone_gamma    LEX_ROBOT_SIDECAR_PORT=8903               python3 "$SIDECAR" &
  PID_GAMMA=$!
  LEX_STALL_NAME=triage_hospital_hq   LEX_ROBOT_SIDECAR_PORT=8904               python3 "$SIDECAR" &
  PID_HQ=$!

  for port in 8900 8901 8902 8903 8904; do
    for i in $(seq 1 10); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
      sleep 0.5
    done
    curl -sf "http://127.0.0.1:$port/health" >/dev/null \
      || { echo "ERROR: sidecar on :$port did not start"; exit 1; }
  done
  echo "   dash :8900  alpha :8901  beta :8902  gamma :8903  hq :8904  — all healthy"
  echo "   Open http://localhost:8900 in your browser."
}

stop_sidecars() {
  kill "$PID_DASH" "$PID_ALPHA" "$PID_BETA" "$PID_GAMMA" "$PID_HQ" 2>/dev/null || true
  wait "$PID_DASH" "$PID_ALPHA" "$PID_BETA" "$PID_GAMMA" "$PID_HQ" 2>/dev/null || true
  echo "── All sidecars stopped ──────────────────────────────────────"
}

run_demo() {
  echo "── Running disaster triage demo ──────────────────────────────"
  lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO_DIR/examples/triage_demo.lex" run \
    | grep -v '^null$' || true
}

CMD="${1:-all}"

case "$CMD" in
  sidecars)
    start_sidecars
    echo "(sidecars running — Ctrl-C to stop)"
    trap stop_sidecars EXIT INT TERM
    wait
    ;;
  demo)
    run_demo
    ;;
  all)
    start_sidecars
    trap stop_sidecars EXIT INT TERM
    run_demo
    echo ""
    echo "── Demo complete ─────────────────────────────────────────────"
    echo "   Dashboard still live at http://localhost:8900"
    echo "   Ctrl-C to stop all sidecars."
    wait
    ;;
  *)
    echo "Usage: $0 [sidecars|demo|all]"
    exit 1
    ;;
esac
