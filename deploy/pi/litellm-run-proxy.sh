#!/usr/bin/env bash
# Start the LiteLLM proxy on the Pi, loopback only.
#
#   ~/litellm/run-proxy.sh
#
# Env it expects (put these in ~/litellm/.env, mode 600):
#   OPENCODE_API_KEY     OpenCode Go key            -> the `planner*`/`coder` models
#   OLLAMA_BASE_URL      e.g. http://192.168.1.50:11434  -> the `vision`/`local` models
#   LITELLM_MASTER_KEY   any string; callers send it as the bearer token
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }

: "${LITELLM_MASTER_KEY:=sk-local}"
export LITELLM_MASTER_KEY

if [ -z "${OPENCODE_API_KEY:-}" ] && [ -f "$HOME/.credentials/oc.key" ]; then
  OPENCODE_API_KEY="$(tr -d '[:space:]' < "$HOME/.credentials/oc.key")"
  export OPENCODE_API_KEY
fi
[ -z "${OPENCODE_API_KEY:-}" ] && echo "warn: OPENCODE_API_KEY unset — the planner/coder models will 401" >&2
[ -z "${OLLAMA_BASE_URL:-}" ] && echo "warn: OLLAMA_BASE_URL unset — the vision/local models will fail" >&2

# --host 127.0.0.1 deliberately: anything that reaches this port can spend the
# subscription. Reach it from another machine over an SSH tunnel, not by
# binding 0.0.0.0.
exec ./.venv/bin/litellm --config ./config.yaml --host 127.0.0.1 --port "${LITELLM_PORT:-4000}"
