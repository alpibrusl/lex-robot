#!/usr/bin/env bash
# bazaar_two_sided_run.sh — both sides agents: LLM sellers price, an LLM buyer
# shops, then the session is verified.
#
#   quote  → each seller LLM prices its item by personality vs the revealed ceiling
#   shop   → an LLM buyer reasons over the catalog (value vs the agent-set price)
#            and buys under its capability-bounded budget token
#   verify → replay the trail through gbazaar (compliance recomputed)
#
# Usage:
#   OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) BOT_MODEL=glm-5.1 \
#     LEX=lex ./examples/bazaar_two_sided_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL="${BOT_MODEL:-glm-5.1}"
TRAIL="${BAZAAR_TRAIL:-$(mktemp -d)/bazaar_two_sided.jsonl}"

if [ -z "${OPENCODE_API_KEY:-}" ]; then
  echo "OPENCODE_API_KEY is required (e.g. \$(cat ~/.credentials/opencode/key))" >&2; exit 1
fi

echo "== two-sided: $MODEL sellers price, an $MODEL buyer shops =="
BOT_MODEL="$MODEL" BAZAAR_TRAIL="$TRAIL" OPENCODE_API_KEY="$OPENCODE_API_KEY" \
  $LEX run --allow-effects crypto,env,fs_write,io,llm,net,proc,sql,time "$HERE/bazaar_two_sided.lex" run \
  | grep -vE "seller LLM\]"

echo
echo "== verify: replay the trail, recompute compliance =="
$LEX run --allow-effects io "$HERE/bazaar_verify.lex" verify "\"$TRAIL\"" | head -1

echo
echo "trail at: $TRAIL"
