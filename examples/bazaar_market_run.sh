#!/usr/bin/env bash
# bazaar_market_run.sh — the Magentic Bazaar loop, end to end:
#
#   transact → a buyer agent shops across stalls; each purchase is gated by a
#              signed budget policy and (if allowed) settled over x402 (mock)
#   trail    → every step is attested to a hash-chained lex-trail, written as JSONL
#   verify   → replay the trail through lex-games' gbazaar verifier to recompute
#              whether every settlement respected the budget (compliance, not trust)
#
# Usage: LEX=lex ./examples/bazaar_market_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TRAIL="${BAZAAR_TRAIL:-$(mktemp -d)/bazaar_trail.jsonl}"

echo "== transact: governed shopping session =="
BAZAAR_TRAIL="$TRAIL" $LEX run --allow-effects io,sql,time,net,crypto,fs_write,env "$HERE/bazaar_market.lex" run

echo
echo "== verify: replay the trail, recompute compliance =="
$LEX run --allow-effects io "$HERE/bazaar_verify.lex" verify "\"$TRAIL\"" | head -1

echo
echo "trail at: $TRAIL"
