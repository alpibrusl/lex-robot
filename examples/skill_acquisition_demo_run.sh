#!/usr/bin/env bash
# Skill-acquisition demo: starts the lex-lang tool registry + a local
# geocoding stub, then registers and calls a new INFORMATIONAL skill at
# runtime — no skills.lex edit, no redeploy. See
# examples/skill_acquisition_demo.lex's module comment for the full
# reasoning and why this stays informational-only (not a route to
# self-service physical/actuating skills).
#
# Usage: examples/skill_acquisition_demo_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY_PORT=8300
STUB_PORT=8930
REGISTRY_URL="http://localhost:${REGISTRY_PORT}"
STUB_URL="http://localhost:${STUB_PORT}"

cleanup() {
  echo "[skill_acquisition] stopping tool registry + geocode stub..."
  kill "$REGISTRY_PID" "$STUB_PID" 2>/dev/null || true
  wait "$REGISTRY_PID" "$STUB_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[skill_acquisition] starting lex tool-registry on :${REGISTRY_PORT} ..."
lex tool-registry serve --port "${REGISTRY_PORT}" &
REGISTRY_PID=$!

echo "[skill_acquisition] starting the geocoding stub on :${STUB_PORT} ..."
python3 "${REPO_DIR}/examples/geocode_stub.py" "${STUB_PORT}" &
STUB_PID=$!

for i in $(seq 1 20); do
  curl -sf "${REGISTRY_URL}/tools" >/dev/null 2>&1 && curl -sf "${STUB_URL}/health" >/dev/null 2>&1 && break
  sleep 0.3
  if [ "$i" -eq 20 ]; then echo "[skill_acquisition] ERROR: registry or stub did not start"; exit 1; fi
done
echo "[skill_acquisition] both up"

echo ""
TOOL_REGISTRY_URL="${REGISTRY_URL}" \
GEOCODE_STUB_URL="${STUB_URL}" \
  lex run --allow-effects env,net,io \
  "${REPO_DIR}/examples/skill_acquisition_demo.lex" run
