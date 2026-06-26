#!/usr/bin/env bash
# bazaar_llm_sellers_run.sh — both sides agents: LLM-priced sellers vs a governed
# buyer, then verify the session.
#
#   quote  → three seller LLMs price the same kind of item by personality (fair /
#            max-profit / premium) against the buyer's revealed budget ceiling
#   gate   → the buyer pays only what its signed token allows; a quote above its
#            per-transaction cap is DENIED — governance, not trust, stops the gouge
#   verify → replay the trail through gbazaar (compliance recomputed)
#
# Usage:
#   OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) BOT_MODEL=glm-5.1 \
#     LEX=lex ./examples/bazaar_llm_sellers_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL="${BOT_MODEL:-glm-5.1}"
TRAIL="${BAZAAR_TRAIL:-$(mktemp -d)/bazaar_llm_sellers.jsonl}"

if [ -z "${OPENCODE_API_KEY:-}" ]; then
  echo "OPENCODE_API_KEY is required (e.g. \$(cat ~/.credentials/opencode/key))" >&2; exit 1
fi

echo "== quote + gate: $MODEL sellers price; the buyer's token decides =="
BOT_MODEL="$MODEL" BAZAAR_TRAIL="$TRAIL" OPENCODE_API_KEY="$OPENCODE_API_KEY" \
  $LEX run --allow-effects crypto,env,fs_write,io,llm,net,proc,sql,time "$HERE/bazaar_llm_sellers.lex" run \
  | grep -vE "seller LLM\]"

echo
echo "== verify: replay the trail, recompute compliance =="
$LEX run --allow-effects io "$HERE/bazaar_verify.lex" verify "\"$TRAIL\"" | head -1

echo
echo "trail at: $TRAIL"
