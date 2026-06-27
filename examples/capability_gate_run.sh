#!/usr/bin/env bash
# capability_gate_run.sh — one capability token, governing data AND money, then
# the whole session verified by one replay.
#
#   gate   → a did:lex agent reads profile scopes AND spends credits under ONE
#            signed capability; over-scope reads and over-cap spends are refused,
#            all attested to ONE hash-chained trail
#   verify → replay the mixed trail through lex-games' capability verifier —
#            recompute that the one token was respected on both halves
#
# The platform kernel's control plane: one token for everything an agent may do
# or know, made verifiable.
#
# Usage: LEX=lex ./examples/capability_gate_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TRAIL="${CAP_TRAIL:-$(mktemp -d)/capability_trail.jsonl}"

echo "== gate: one did:lex token bounds data reads AND purchases =="
CAP_TRAIL="$TRAIL" $LEX run --allow-effects io,sql,time,net,crypto,fs_write,env "$HERE/capability_gate.lex" run

echo
echo "== verify: replay the mixed trail, recompute both halves of the token =="
$LEX run --allow-effects io "$HERE/capability_verify.lex" verify "\"$TRAIL\"" | head -1

echo
echo "trail at: $TRAIL"
