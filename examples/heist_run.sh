#!/usr/bin/env bash
# examples/heist_run.sh — Start the 5-sidecar heist and run the demo.
#
# Sidecar layout:
#   :8900  dashboard     — event hub + web UI (http://localhost:8900)
#                          served from heist_web.html (LEX_DASHBOARD_HTML=heist_web.html)
#   :8901  heist_lobby   — Lobby area (Scout's domain)
#   :8902  heist_security— Security Room (Hacker's domain)
#   :8903  heist_server  — Server Room (Muscle's domain)
#   :8904  heist_vault   — Vault (Extractor's domain)
#
# Usage:
#   VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
#   VERTEX_PROJECT=my-project \
#   bash examples/heist_run.sh
#
#   bash examples/heist_run.sh areas    # start all 5 sidecars only (Ctrl-C to stop)
#   bash examples/heist_run.sh heist    # run demo only (sidecars must be up)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR="$REPO_DIR/sidecar/sim_sidecar.lex"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time --allow-proc sh"

start_areas() {
  echo "── Starting 5 sidecars ──────────────────────────────────────"
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_DASHBOARD_HTML=heist_web.html LEX_ROBOT_SIDECAR_PORT=8900 $LEX_RUN "$SIDECAR" run &
  PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_STALL_NAME=heist_lobby        LEX_ROBOT_SIDECAR_PORT=8901 $LEX_RUN "$SIDECAR" run &
  PID_LOBBY=$!
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_STALL_NAME=heist_security     LEX_ROBOT_SIDECAR_PORT=8902 $LEX_RUN "$SIDECAR" run &
  PID_SECURITY=$!
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_STALL_NAME=heist_server       LEX_ROBOT_SIDECAR_PORT=8903 $LEX_RUN "$SIDECAR" run &
  PID_SERVER=$!
  LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_STALL_NAME=heist_vault        LEX_ROBOT_SIDECAR_PORT=8904 $LEX_RUN "$SIDECAR" run &
  PID_VAULT=$!

  for port in 8900 8901 8902 8903 8904; do
    for i in $(seq 1 10); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
      sleep 0.5
    done
    curl -sf "http://127.0.0.1:$port/health" >/dev/null \
      || { echo "ERROR: sidecar on :$port did not start"; exit 1; }
  done
  echo "   dash :8900  lobby :8901  security :8902  server :8903  vault :8904  — all healthy"
  echo "   Open http://localhost:8900 in your browser."
}

stop_areas() {
  kill "$PID_DASH" "$PID_LOBBY" "$PID_SECURITY" "$PID_SERVER" "$PID_VAULT" 2>/dev/null || true
  wait "$PID_DASH" "$PID_LOBBY" "$PID_SECURITY" "$PID_SERVER" "$PID_VAULT" 2>/dev/null || true
  echo "── All sidecars stopped ──────────────────────────────────────"
}

run_heist() {
  echo "── Running heist demo ────────────────────────────────────────"
  lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO_DIR/examples/heist_demo.lex" run \
    | grep -v '^null$' || true
}

CMD="${1:-all}"

case "$CMD" in
  areas)
    start_areas
    echo "(areas running — Ctrl-C to stop)"
    trap stop_areas EXIT INT TERM
    wait
    ;;
  heist)
    run_heist
    ;;
  all)
    start_areas
    trap stop_areas EXIT INT TERM
    run_heist
    echo ""
    echo "── Demo complete ─────────────────────────────────────────────"
    echo "   Dashboard still live at http://localhost:8900"
    echo "   Ctrl-C to stop all sidecars."
    wait
    ;;
  *)
    echo "Usage: $0 [areas|heist|all]"
    exit 1
    ;;
esac
