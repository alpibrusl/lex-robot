#!/usr/bin/env bash
# Skill-catalog demo: starts the lex-lang tool registry + the consolidated
# skills API stub, then registers and calls all 10 informational
# skills from examples/skill_library.lex. See that file's module comment
# for the tier breakdown and examples/skill_acquisition_demo.lex's for the
# single-skill mechanism this scales up.
#
# Usage: examples/skill_catalog_demo_run.sh
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY_PORT=8300
STUB_PORT=8930
REGISTRY_URL="http://localhost:${REGISTRY_PORT}"
STUB_URL="http://localhost:${STUB_PORT}"

cleanup() {
  echo "[skill_catalog] stopping tool registry + skills API stub..."
  kill "$REGISTRY_PID" "$STUB_PID" 2>/dev/null || true
  wait "$REGISTRY_PID" "$STUB_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[skill_catalog] starting lex tool-registry on :${REGISTRY_PORT} ..."
lex tool-registry serve --port "${REGISTRY_PORT}" &
REGISTRY_PID=$!

echo "[skill_catalog] starting the skills API stub on :${STUB_PORT} ..."
python3 "${REPO_DIR}/examples/skills_api_stub.py" "${STUB_PORT}" &
STUB_PID=$!

for i in $(seq 1 20); do
  curl -sf "${REGISTRY_URL}/tools" >/dev/null 2>&1 && curl -sf "${STUB_URL}/health" >/dev/null 2>&1 && break
  sleep 0.3
  if [ "$i" -eq 20 ]; then echo "[skill_catalog] ERROR: registry or stub did not start"; exit 1; fi
done
echo "[skill_catalog] both up"

echo ""
TOOL_REGISTRY_URL="${REGISTRY_URL}" \
SKILLS_API_STUB_URL="${STUB_URL}" \
  lex run --allow-effects env,net,io \
  "${REPO_DIR}/examples/skill_catalog_demo.lex" run
