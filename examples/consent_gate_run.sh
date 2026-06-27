#!/usr/bin/env bash
# consent_gate_run.sh — the consent loop, end to end:
#
#   gate   → an agent (did:lex:agent:…) requests scopes of a user's profile; the
#            consent gate grants the permitted subset or denies, attesting each
#            receipt to a hash-chained lex-trail
#   verify → replay the trail through lex-games' consent verifier — recompute
#            that no grant leaked a deny-listed scope (compliance, not trust)
#
# The data-side analog of bazaar_market_run.sh: capability gating over what an
# agent may KNOW, with provable receipts. Ports the a2p model, no dependency.
#
# Usage: LEX=lex ./examples/consent_gate_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TRAIL="${CONSENT_TRAIL:-$(mktemp -d)/consent_trail.jsonl}"

echo "== gate: did:lex agents request profile scopes under a consent policy =="
CONSENT_TRAIL="$TRAIL" $LEX run --allow-effects io,sql,time,fs_write,env "$HERE/consent_gate.lex" run

echo
echo "== verify: replay the trail, recompute that no grant leaked a forbidden scope =="
$LEX run --allow-effects io "$HERE/consent_verify.lex" verify "\"$TRAIL\"" | head -1

echo
echo "trail at: $TRAIL"
