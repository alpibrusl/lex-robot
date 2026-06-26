#!/usr/bin/env bash
# Two OpenCode Zen "Go plan" models play a full Tic-Tac-Toe match against each
# other on the live sidecar — gated A2A moves, hash-chained trail, spectatable
# at http://localhost:8900 (the X cell-click UI shows the bots' moves live).
#
#   MODEL_X=glm-5.2 MODEL_O=kimi-k2.7-code \
#   OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) \
#     examples/llm_ttt_party_run.sh
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${LEX_ROBOT_SIDECAR_PORT:-8900}"; URL="http://localhost:${PORT}"
LEX="${LEX:-lex}"
KEY="${OPENCODE_API_KEY:-$(cat "$HOME/.credentials/opencode/key" 2>/dev/null || true)}"
# Defaults are fast models so a match completes promptly. The latest (slower)
# headliners also work: MODEL_X=glm-5.2 MODEL_O=kimi-k2.7-code (each move >45s).
MODEL_X="${MODEL_X:-deepseek-v4-flash}"; MODEL_O="${MODEL_O:-kimi-k2.6}"
EFF="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sense,sql,time"

cleanup(){ kill $(jobs -p) 2>/dev/null || true; }
trap cleanup EXIT INT TERM
pkill -f sim_sidecar.lex 2>/dev/null || true; pkill -f llm_arena_bot.lex 2>/dev/null || true
rm -f "/tmp/lex-sidecar-${PORT}.db"

echo "[party] starting TTT server on :${PORT} …"
LEX_ROBOT_REPO_ROOT="$REPO_DIR" LEX_DASHBOARD_HTML=ttt_web.html LEX_ROBOT_SIDECAR_PORT="$PORT" \
  $LEX run --allow-effects "$EFF" "$REPO_DIR/sidecar/sim_sidecar.lex" run >/tmp/party-server.log 2>&1 &
for i in $(seq 1 40); do curl -sf "$URL/health" >/dev/null 2>&1 && break; sleep 0.5; done

echo "[party] ⚔  X = ${MODEL_X}   vs   O = ${MODEL_O}   (spectate: $URL)"
TTT_SERVER="$URL" SIDE=X OPENCODE_MODEL="$MODEL_X" OPENCODE_API_KEY="$KEY" \
  $LEX run --allow-effects "$EFF" "$REPO_DIR/examples/llm_arena_bot.lex" run &
sleep 1
TTT_SERVER="$URL" SIDE=O OPENCODE_MODEL="$MODEL_O" OPENCODE_API_KEY="$KEY" \
  $LEX run --allow-effects "$EFF" "$REPO_DIR/examples/llm_arena_bot.lex" run &
wait
echo "[party] match complete."
