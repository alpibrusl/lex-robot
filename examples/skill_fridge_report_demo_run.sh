#!/usr/bin/env bash
# Fridge-report demo: starts the XLeRobot stub sidecar + the skills API
# stub, runs examples/skill_fridge_report_demo.lex against both, then
# curls the sidecar's own /display/state so you can see exactly what the
# kiosk page would render. See that file's module comment for why
# navigation is hardcoded and the photo is a bundled placeholder.
#
# Usage: examples/skill_fridge_report_demo_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR_PORT=8900
VISION_PORT=8930
SIDECAR_URL="http://localhost:${SIDECAR_PORT}"
VISION_URL="http://localhost:${VISION_PORT}"

cleanup() {
  echo "[fridge_report] stopping sidecar + vision stub..."
  kill "$SIDECAR_PID" "$VISION_PID" 2>/dev/null || true
  wait "$SIDECAR_PID" "$VISION_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[fridge_report] starting the XLeRobot stub sidecar on :${SIDECAR_PORT} ..."
python3 "${REPO_DIR}/sidecar/xlerobot_sidecar.py" &
SIDECAR_PID=$!

echo "[fridge_report] starting the skills API stub (vision endpoint) on :${VISION_PORT} ..."
python3 "${REPO_DIR}/examples/skills_api_stub.py" "${VISION_PORT}" &
VISION_PID=$!

for i in $(seq 1 20); do
  curl -sf "${SIDECAR_URL}/health" >/dev/null 2>&1 && curl -sf "${VISION_URL}/health" >/dev/null 2>&1 && break
  sleep 0.3
  if [ "$i" -eq 20 ]; then echo "[fridge_report] ERROR: sidecar or vision stub did not start"; exit 1; fi
done
echo "[fridge_report] both up"

echo ""
cd "${REPO_DIR}"
XLE_SIDECAR_URL="${SIDECAR_URL}" \
VISION_STUB_URL="${VISION_URL}" \
  lex run --allow-effects env,net,sense,actuate,io \
  "${REPO_DIR}/examples/skill_fridge_report_demo.lex" run

echo ""
echo "[fridge_report] the kiosk page's /display/state right now:"
curl -s "${SIDECAR_URL}/display/state"
echo ""
