#!/usr/bin/env bash
# robot_reputation_run.sh — robots on the kernel, end to end and hardware-free:
#
#   act    → a robot operator (did:lex) runs a governed episode under its grant
#            (workspace box + ISO/TS-15066 force/grip caps)
#   verify → replay the episode through lex-games' robot_task verifier
#            (intact + linked + grant-legal + goal)
#   earn   → fold {did, score, verified} into the did:lex reputation registry —
#            only verified, in-grant episodes accrue; an over-grant "unauthorized
#            success" earns nothing
#
# No physics, no hardware — this is the authority layer. (MuJoCo/twin tiers add
# physical realism later; see the epic.)
#
# Usage: LEX=lex ./examples/robot_reputation_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
EP="--allow-effects io,sql,time,fs_write,env"

# run one operator's episode, return a reputation batch entry {did,score,verified,won}
episode() { # <did> <mode> <trail>
  OPERATOR_DID="$1" EPISODE="$2" ROBOT_TRAIL="$3" $LEX run $EP "$HERE/robot_operator.lex" run >/dev/null 2>&1
  local out ver sc
  out="$($LEX run --allow-effects io "$HERE/robot_verify.lex" verify "\"$3\"")"
  ver="$(printf '%s' "$out" | grep -o '"verified":[a-z]*' | head -1 | cut -d: -f2)"
  sc="$(printf '%s' "$out" | grep -o '"score":[0-9]*' | head -1 | cut -d: -f2)"
  printf '{"did":"%s","score":%s,"verified":%s,"won":%s}' "$1" "${sc:-0}" "${ver:-false}" "${ver:-false}"
}

echo "== round 1: a compliant arm and an over-grant arm each run an episode =="
a="$(episode did:lex:robot:arm-careful  compliant "$WORK/careful.jsonl")"; echo "  arm-careful  → $a"
b="$(episode did:lex:robot:arm-reckless overgrant "$WORK/reckless.jsonl")"; echo "  arm-reckless → $b (unauthorized success → not verified)"
printf '[%s,%s]' "$a" "$b" > "$WORK/round1.json"
$LEX run --allow-effects io "$HERE/reputation_rank.lex" rank "\"$WORK/none.json\"" "\"$WORK/round1.json\"" | grep '^{' > "$WORK/reg1.json"
echo "  operator reputation after round 1:"; cat "$WORK/reg1.json"

echo
echo "== round 2: the compliant arm runs again → its reputation accumulates =="
a2="$(episode did:lex:robot:arm-careful compliant "$WORK/careful2.jsonl")"; echo "  arm-careful  → $a2"
printf '[%s]' "$a2" > "$WORK/round2.json"
$LEX run --allow-effects io "$HERE/reputation_rank.lex" rank "\"$WORK/reg1.json\"" "\"$WORK/round2.json\"" | grep '^{' > "$WORK/reg2.json"
echo "  operator reputation after round 2:"; cat "$WORK/reg2.json"

echo
echo "files in: $WORK"
