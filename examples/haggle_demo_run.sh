#!/usr/bin/env bash
# Run a multi-round buyer↔seller haggle on a LOCAL model (via the LiteLLM proxy).
# Needs a running LiteLLM proxy (default :4000) in front of Ollama:
#   litellm --config litellm_config.yaml --port 4000   # then:
#   examples/haggle_demo_run.sh [model]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${LITELLM_BASE_URL:-http://localhost:4000}"
MODEL="${1:-${LITELLM_MODEL:-mistral-small:latest}}"

curl -sf "${BASE}/health/readiness" >/dev/null 2>&1 || curl -sf "${BASE}/v1/models" >/dev/null 2>&1 || {
  echo "error: no LiteLLM proxy at ${BASE} — start one with:" >&2
  echo "  litellm --config litellm_config.yaml --port 4000" >&2
  exit 1
}

cd "${REPO_DIR}"
LITELLM_BASE_URL="${BASE}" LITELLM_MODEL="${MODEL}" \
  lex run --allow-effects env,fs_write,io,llm,net,proc,sql,time \
  examples/haggle_demo.lex run
