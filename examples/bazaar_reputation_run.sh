#!/usr/bin/env bash
# bazaar_reputation_run.sh — the full commerce loop into a seller leaderboard:
#
#   transact → run governed shopping sessions (bazaar_market.lex); each emits a
#              hash-chained spend trail
#   verify+rank → replay every session's trail through lex-games' gbazaar verifier
#              and accumulate per-seller revenue/deals from the sessions that
#              verify (a tampered/non-compliant session earns its sellers nothing)
#
# Two sessions are run here so the board shows aggregation; swap in
# bazaar_llm_buyer.lex (with OPENCODE_API_KEY) for live multi-model sessions.
#
# Usage: LEX=lex ./examples/bazaar_reputation_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
MARKET_POLICY="--allow-effects io,sql,time,net,crypto,fs_write,env"

echo "== transact: two governed shopping sessions =="
BAZAAR_TRAIL="$WORK/s1.jsonl" $LEX run $MARKET_POLICY "$HERE/bazaar_market.lex" run >/dev/null && echo "  session 1 → $WORK/s1.jsonl"
BAZAAR_TRAIL="$WORK/s2.jsonl" $LEX run $MARKET_POLICY "$HERE/bazaar_market.lex" run >/dev/null && echo "  session 2 → $WORK/s2.jsonl"

cat > "$WORK/sessions.json" <<JSON
[ { "trail": "$WORK/s1.jsonl" }, { "trail": "$WORK/s2.jsonl" } ]
JSON

echo
echo "== verify + rank: seller reputation across the sessions =="
$LEX run --allow-effects io "$HERE/bazaar_rank.lex" rank "\"$WORK/sessions.json\"" | grep '^{'

echo
echo "(drop this JSON at examples/sellers.json and the lobby's TOP SELLERS board renders it)"
echo "sessions in: $WORK"
