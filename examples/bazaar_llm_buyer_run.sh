#!/usr/bin/env bash
# bazaar_llm_buyer_run.sh — an LLM buyer agent shops under governance, then the
# session trail is independently verified for compliance.
#
#   shop   → an open-weights model (OpenCode Go) picks purchases; lex-guard's
#            spend gate + x402 (mock) allow or DENY each one (it isn't told its
#            own allow-list, so the wall catches overreach and it self-corrects)
#   verify → replay the trail through lex-games' gbazaar verifier
#
# Usage:
#   OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) BOT_MODEL=glm-5.1 \
#     LEX=lex ./examples/bazaar_llm_buyer_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL="${BOT_MODEL:-glm-5.1}"
TRAIL="${BAZAAR_TRAIL:-$(mktemp -d)/bazaar_llm_trail.jsonl}"

if [ -z "${OPENCODE_API_KEY:-}" ]; then
  echo "OPENCODE_API_KEY is required (e.g. \$(cat ~/.credentials/opencode/key))" >&2; exit 1
fi

echo "== shop: $MODEL buys under a capability-bounded budget =="
BOT_MODEL="$MODEL" BAZAAR_TRAIL="$TRAIL" OPENCODE_API_KEY="$OPENCODE_API_KEY" \
  $LEX run --allow-effects crypto,env,fs_write,io,llm,net,proc,sql,time "$HERE/bazaar_llm_buyer.lex" run

echo
echo "== verify: replay the trail, recompute compliance =="
$LEX run --allow-effects io "$HERE/bazaar_verify.lex" verify "\"$TRAIL\"" | head -1

echo
echo "trail at: $TRAIL"
