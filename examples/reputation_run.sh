#!/usr/bin/env bash
# reputation_run.sh — agent reputation, end to end and DID-anchored:
#
#   act    → each agent (did:lex:agent:…) runs a governed capability session
#   verify → replay its trail (lex-games capability verifier) → a verdict
#   earn   → fold {did, score, verified} batches into a persistent, DID-keyed
#            reputation registry — only VERIFIED sessions accrue, accumulating
#            across rounds
#
# Shows: two agents earn reputation from real sessions; a tampered session earns
# nothing; an agent that acts again accumulates and climbs.
#
# Usage: LEX=lex ./examples/reputation_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
GATE="--allow-effects io,sql,time,net,crypto,fs_write,env"

# run one governed session as <did>, return a batch entry {did,score,verified,won}
session() { # <did> <trail>
  AGENT_DID="$1" CAP_TRAIL="$2" $LEX run $GATE "$HERE/capability_gate.lex" run >/dev/null 2>&1
  local out ver set
  out="$($LEX run --allow-effects io "$HERE/capability_verify.lex" verify "\"$2\"")"
  ver="$(printf '%s' "$out" | grep -o '"verified":[a-z]*' | head -1 | cut -d: -f2)"
  set="$(printf '%s' "$out" | grep -o '"settled":[0-9]*' | head -1 | cut -d: -f2)"
  printf '{"did":"%s","score":%s,"verified":%s,"won":%s}' "$1" "${set:-0}" "${ver:-false}" "${ver:-false}"
}

echo "== round 1: alice and bob each run a governed session; one is tampered =="
a="$(session did:lex:agent:alice "$WORK/alice.jsonl")"; echo "  alice  → $a"
b="$(session did:lex:agent:bob   "$WORK/bob.jsonl")";   echo "  bob    → $b"
# a tampered session must earn nothing: flip a settled amount in bob's trail, re-verify as 'carol'
sed 's/\\"amount\\":1200/\\"amount\\":9000/' "$WORK/bob.jsonl" > "$WORK/carol.jsonl"
cout="$($LEX run --allow-effects io "$HERE/capability_verify.lex" verify "\"$WORK/carol.jsonl\"")"
cver="$(printf '%s' "$cout" | grep -o '"verified":[a-z]*' | head -1 | cut -d: -f2)"
c="$(printf '{"did":"did:lex:agent:carol","score":9000,"verified":%s,"won":false}' "${cver:-false}")"; echo "  carol  → $c (tampered)"
printf '[%s,%s,%s]' "$a" "$b" "$c" > "$WORK/round1.json"

$LEX run --allow-effects io "$HERE/reputation_rank.lex" rank "\"$WORK/none.json\"" "\"$WORK/round1.json\"" | grep '^{' > "$WORK/reg1.json"
echo "  registry after round 1:"; cat "$WORK/reg1.json"

echo
echo "== round 2: bob acts again → his reputation accumulates and he climbs =="
b2="$(session did:lex:agent:bob "$WORK/bob2.jsonl")"; echo "  bob    → $b2"
printf '[%s]' "$b2" > "$WORK/round2.json"
$LEX run --allow-effects io "$HERE/reputation_rank.lex" rank "\"$WORK/reg1.json\"" "\"$WORK/round2.json\"" | grep '^{' > "$WORK/reg2.json"
echo "  registry after round 2:"; cat "$WORK/reg2.json"

echo
echo "registry files in: $WORK"
