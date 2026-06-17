#!/usr/bin/env bash
# demos/record.sh — Record all lex-robot demos to demos/*.log
#
# Usage:
#   VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
#   VERTEX_PROJECT=elusmart-dev \
#   bash demos/record.sh [bazaar|bazaar_rush|heist|station|trading|triage|all]
#
# Output: demos/<name>.log  (plain text with ANSI stripped via `col -b`)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SIDECAR="$REPO/sidecar/sim_sidecar.lex"
LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time --allow-proc sh"

: "${VERTEX_ACCESS_TOKEN:?Set VERTEX_ACCESS_TOKEN}"
: "${VERTEX_PROJECT:=elusmart-dev}"
: "${VERTEX_LOCATION:=eu}"

log() { echo "[record] $*"; }

wait_healthy() {
  local port=$1
  for i in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  echo "ERROR: sidecar on :$port did not start" >&2; return 1
}

run_and_record() {
  local name=$1; shift
  local logfile="$SCRIPT_DIR/${name}.log"
  log "Recording $name → $logfile"
  "$@" 2>&1 | col -b > "$logfile"
  log "$name done  ($(wc -l < "$logfile") lines)"
}

# ── Each demo function starts sidecars, runs agent, stops sidecars ─────────────

record_bazaar() {
  log "=== BAZAAR DEMO ==="
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_ROBOT_SIDECAR_PORT=8900 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-dash.log 2>&1 &   PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=pottery LEX_ROBOT_SIDECAR_PORT=8901 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s1.log 2>&1 &     PID_S1=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=textile LEX_ROBOT_SIDECAR_PORT=8902 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s2.log 2>&1 &     PID_S2=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=spices  LEX_ROBOT_SIDECAR_PORT=8903 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s3.log 2>&1 &     PID_S3=$!
  for p in 8900 8901 8902 8903; do wait_healthy $p; done
  log "All 4 sidecars healthy"

  run_and_record bazaar \
    lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO/examples/bazaar_demo.lex" run

  kill $PID_DASH $PID_S1 $PID_S2 $PID_S3 2>/dev/null || true
  wait $PID_DASH $PID_S1 $PID_S2 $PID_S3 2>/dev/null || true
}

record_bazaar_rush() {
  log "=== BAZAAR RUSH DEMO ==="
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_ROBOT_SIDECAR_PORT=8900 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-dash.log 2>&1 &     PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=pottery  LEX_ROBOT_SIDECAR_PORT=8901 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s1.log 2>&1 &       PID_S1=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=textile  LEX_ROBOT_SIDECAR_PORT=8902 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s2.log 2>&1 &       PID_S2=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=spices   LEX_ROBOT_SIDECAR_PORT=8903 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s3.log 2>&1 &       PID_S3=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=clay     LEX_ROBOT_SIDECAR_PORT=8904 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s4.log 2>&1 &       PID_S4=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=fabric   LEX_ROBOT_SIDECAR_PORT=8905 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s5.log 2>&1 &       PID_S5=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=herb     LEX_ROBOT_SIDECAR_PORT=8906 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s6.log 2>&1 &       PID_S6=$!
  for p in 8900 8901 8902 8903 8904 8905 8906; do wait_healthy $p; done
  log "All 7 sidecars healthy"

  run_and_record bazaar_rush \
    lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO/examples/bazaar_rush.lex" run

  kill $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 $PID_S5 $PID_S6 2>/dev/null || true
  wait $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 $PID_S5 $PID_S6 2>/dev/null || true
}

record_heist() {
  log "=== HEIST DEMO ==="
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_DASHBOARD_HTML=heist_web.html LEX_ROBOT_SIDECAR_PORT=8900 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-dash.log 2>&1 &       PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=heist_lobby    LEX_ROBOT_SIDECAR_PORT=8901 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s1.log 2>&1 &         PID_S1=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=heist_security LEX_ROBOT_SIDECAR_PORT=8902 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s2.log 2>&1 &         PID_S2=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=heist_server   LEX_ROBOT_SIDECAR_PORT=8903 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s3.log 2>&1 &         PID_S3=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=heist_vault    LEX_ROBOT_SIDECAR_PORT=8904 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s4.log 2>&1 &         PID_S4=$!
  for p in 8900 8901 8902 8903 8904; do wait_healthy $p; done
  log "All 5 sidecars healthy"

  run_and_record heist \
    lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO/examples/heist_demo.lex" run

  kill $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 2>/dev/null || true
  wait $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 2>/dev/null || true
}

record_station() {
  log "=== SPACE STATION DEMO ==="
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_DASHBOARD_HTML=station_web.html LEX_ROBOT_SIDECAR_PORT=8900 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-dash.log 2>&1 &         PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=station_life_support LEX_ROBOT_SIDECAR_PORT=8901 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s1.log 2>&1 &           PID_S1=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=station_navigation  LEX_ROBOT_SIDECAR_PORT=8902 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s2.log 2>&1 &           PID_S2=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=station_comms       LEX_ROBOT_SIDECAR_PORT=8903 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s3.log 2>&1 &           PID_S3=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=station_cargo       LEX_ROBOT_SIDECAR_PORT=8904 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s4.log 2>&1 &           PID_S4=$!
  for p in 8900 8901 8902 8903 8904; do wait_healthy $p; done
  log "All 5 sidecars healthy"

  run_and_record station \
    lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO/examples/station_demo.lex" run

  kill $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 2>/dev/null || true
  wait $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 2>/dev/null || true
}

record_trading() {
  log "=== TRADING FLOOR DEMO ==="
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_DASHBOARD_HTML=trading_web.html LEX_ROBOT_SIDECAR_PORT=8900 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-dash.log 2>&1 &         PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=trading_quantum  LEX_ROBOT_SIDECAR_PORT=8901 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s1.log 2>&1 &           PID_S1=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=trading_solar    LEX_ROBOT_SIDECAR_PORT=8902 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s2.log 2>&1 &           PID_S2=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=trading_water    LEX_ROBOT_SIDECAR_PORT=8903 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s3.log 2>&1 &           PID_S3=$!
  for p in 8900 8901 8902 8903; do wait_healthy $p; done
  log "All 4 sidecars healthy"

  run_and_record trading \
    lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO/examples/trading_demo.lex" run

  kill $PID_DASH $PID_S1 $PID_S2 $PID_S3 2>/dev/null || true
  wait $PID_DASH $PID_S1 $PID_S2 $PID_S3 2>/dev/null || true
}

record_triage() {
  log "=== DISASTER TRIAGE DEMO ==="
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_DASHBOARD_HTML=triage_web.html  LEX_ROBOT_SIDECAR_PORT=8900 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-dash.log 2>&1 &           PID_DASH=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=triage_zone_alpha   LEX_ROBOT_SIDECAR_PORT=8901 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s1.log 2>&1 &             PID_S1=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=triage_zone_beta    LEX_ROBOT_SIDECAR_PORT=8902 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s2.log 2>&1 &             PID_S2=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=triage_zone_gamma   LEX_ROBOT_SIDECAR_PORT=8903 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s3.log 2>&1 &             PID_S3=$!
  LEX_ROBOT_REPO_ROOT="$REPO" LEX_STALL_NAME=triage_hospital_hq  LEX_ROBOT_SIDECAR_PORT=8904 \
    $LEX_RUN "$SIDECAR" run > /tmp/lex-s4.log 2>&1 &             PID_S4=$!
  for p in 8900 8901 8902 8903 8904; do wait_healthy $p; done
  log "All 5 sidecars healthy"

  run_and_record triage \
    lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time \
      "$REPO/examples/triage_demo.lex" run

  kill $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 2>/dev/null || true
  wait $PID_DASH $PID_S1 $PID_S2 $PID_S3 $PID_S4 2>/dev/null || true
}

# ── Dispatch ────────────────────────────────────────────────────────────────────

CMD="${1:-all}"
case "$CMD" in
  bazaar)       record_bazaar ;;
  bazaar_rush)  record_bazaar_rush ;;
  heist)        record_heist ;;
  station)      record_station ;;
  trading)      record_trading ;;
  triage)       record_triage ;;
  all)
    record_bazaar
    sleep 2
    record_bazaar_rush
    sleep 2
    record_heist
    sleep 2
    record_station
    sleep 2
    record_trading
    sleep 2
    record_triage
    ;;
  *)
    echo "Usage: $0 [bazaar|bazaar_rush|heist|station|trading|triage|all]"
    exit 1
    ;;
esac

log "All done. Files:"
ls -lh "$SCRIPT_DIR"/*.log 2>/dev/null || true
