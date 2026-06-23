#!/usr/bin/env bash
# Distributed haggle over the wire: boot ONE pottery stall sidecar whose seller
# runs on a LOCAL model, then run the buyer driver (also local) against it.
# No physics, no full marketplace — just the two negotiating processes.
#
# Needs: a running LiteLLM proxy (default :4000) in front of Ollama.
#   litellm --config litellm_config.yaml --port 4000   # then:
#   examples/haggle_a2a_demo_run.sh [model]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STALL_PORT="${STALL_PORT:-8901}"
STALL_URL="http://localhost:${STALL_PORT}"
BASE="${LITELLM_BASE_URL:-http://localhost:4000}"
MODEL="${1:-${LITELLM_MODEL:-mistral-small:latest}}"

curl -sf "${BASE}/health/readiness" >/dev/null 2>&1 || curl -sf "${BASE}/v1/models" >/dev/null 2>&1 || {
  echo "error: no LiteLLM proxy at ${BASE} — start one with:" >&2
  echo "  litellm --config litellm_config.yaml --port 4000" >&2
  exit 1
}

LEX_RUN="lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time --allow-proc sh"

cleanup() { kill "$STALL_PID" 2>/dev/null || true; wait "$STALL_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

pkill -f "sim_sidecar.lex" 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${STALL_PORT}.db"

echo "[haggle] starting pottery stall (seller=llm, local) on :${STALL_PORT} ..."
SELLER_LLM=1 \
LITELLM_BASE_URL="${BASE}" LITELLM_MODEL="${MODEL}" \
LEX_STALL_NAME=pottery \
LEX_ROBOT_SIDECAR_PORT="${STALL_PORT}" \
LEX_ROBOT_REPO_ROOT="${REPO_DIR}" \
  ${LEX_RUN} "${REPO_DIR}/sidecar/sim_sidecar.lex" run &
STALL_PID=$!

for _ in $(seq 1 50); do
  curl -sf "${STALL_URL}/health" >/dev/null 2>&1 && break
  sleep 0.2
done

echo "[haggle] running buyer driver against ${STALL_URL} ..."
cd "${REPO_DIR}"
STALL_URL="${STALL_URL}" LITELLM_BASE_URL="${BASE}" LITELLM_MODEL="${MODEL}" \
  lex run --allow-effects env,fs_write,io,llm,net,proc,sql,time \
  examples/haggle_a2a_demo.lex run
