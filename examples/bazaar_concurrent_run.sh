#!/usr/bin/env bash
# bazaar_concurrent_run.sh — the chaotic multi-party Magentic Bazaar, end to end:
#
#   contend → several buyer agents compete for a scarce inventory arbitrated by a
#             shared market actor; each winning purchase is governed (lex-guard +
#             x402 mock) and written to that buyer's own hash-chained trail
#   verify  → replay each buyer's trail through gbazaar (compliance, per buyer)
#   rank    → aggregate seller reputation across all buyers (bazaar_season)
#
# Usage: LEX=lex ./examples/bazaar_concurrent_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$(mktemp -d)"

echo "== contend: concurrent governed bazaar =="
BAZAAR_DIR="$DIR" $LEX run --allow-effects concurrent,crypto,env,fs_write,io,net,sql,time "$HERE/bazaar_concurrent.lex" run

echo
echo "== verify: each buyer's governed trail (compliance recomputed) =="
for f in "$DIR"/bazaar_*.jsonl; do
  printf "  %s: " "$(basename "$f" .jsonl)"
  $LEX run --allow-effects io "$HERE/bazaar_verify.lex" verify "\"$f\"" | grep -o '"verified":[a-z]*,"intact":[a-z]*,"compliant":[a-z]*'
done

echo
echo "== rank: seller reputation across all buyers =="
$LEX run --allow-effects io "$HERE/bazaar_rank.lex" rank "\"$DIR/bazaar_sessions.json\"" | grep '^{'

echo
echo "trails in: $DIR"
