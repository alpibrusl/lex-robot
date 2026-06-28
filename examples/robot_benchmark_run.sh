#!/usr/bin/env bash
# robot_benchmark_run.sh — a cheat-resistant robot-policy benchmark (#65, hardware-free).
#
# A field of robot policies (each a did:lex) runs the same task; every episode is
# replay-verified by lex-games' robot_task (intact + linked + grant-legal + goal)
# and scored, and the recomputed scores accumulate into a persistent did:lex
# reputation leaderboard. Because the score is recomputed from the trail:
#   - an EFFICIENT policy (fewer actuations) outranks a WASTEFUL one,
#   - a policy that honestly hits a grant wall scores low but still counts,
#   - a RECKLESS policy that records an out-of-grant move as "reached" (an
#     unauthorized success) is DQ'd (verified:false) and earns NOTHING.
#
# The verifiable-eval app, applied to robot policies — same did:lex reputation
# registry as the bazaar/arena, so a policy's standing is portable. No hardware;
# MuJoCo rollouts (#66) would feed the same board with real-dynamics episodes.
#
# Usage: LEX=lex ./examples/robot_benchmark_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
EP="--allow-effects io,sql,time,fs_write,env"

# the field: policy did → behaviour mode
POLICIES=(
  "did:lex:policy:diffusion=efficient"
  "did:lex:policy:bc-retry=compliant"
  "did:lex:policy:waypoint=wasteful"
  "did:lex:policy:narrow-grant=denied"
  "did:lex:policy:reckless=overgrant"
)

entry() { # <did> <mode> <trail>  → {did,score,verified,won}
  OPERATOR_DID="$1" EPISODE="$2" ROBOT_TRAIL="$3" $LEX run $EP "$HERE/robot_operator.lex" run >/dev/null 2>&1
  local out ver sc
  out="$($LEX run --allow-effects io "$HERE/robot_verify.lex" verify "\"$3\"")"
  ver="$(printf '%s' "$out" | grep -o '"verified":[a-z]*' | head -1 | cut -d: -f2)"
  sc="$(printf '%s' "$out" | grep -o '"score":[0-9]*' | head -1 | cut -d: -f2)"
  printf '{"did":"%s","score":%s,"verified":%s,"won":%s}' "$1" "${sc:-0}" "${ver:-false}" "${ver:-false}"
}

run_round() { # <round-tag>  → writes a batch json, echoes path
  local tag="$1" first=1
  printf '[' > "$WORK/$tag.json"
  for p in "${POLICIES[@]}"; do
    local did="${p%%=*}" mode="${p##*=}"
    local e; e="$(entry "$did" "$mode" "$WORK/$tag-${did##*:}.jsonl")"
    [ $first = 1 ] || printf ',' >> "$WORK/$tag.json"; printf '%s' "$e" >> "$WORK/$tag.json"; first=0
    echo "  $did ($mode) → $e"
  done
  printf ']' >> "$WORK/$tag.json"
}

echo "== round 1: the field runs the task =="
run_round round1
$LEX run --allow-effects io "$HERE/reputation_rank.lex" rank "\"$WORK/none.json\"" "\"$WORK/round1.json\"" | grep '^{' > "$WORK/board1.json"
echo; echo "  leaderboard after round 1 (reckless is absent — unauthorized success earns nothing):"
$LEX run --allow-effects io "$HERE/reputation_rank.lex" rank "\"$WORK/none.json\"" "\"$WORK/round1.json\"" | grep '^{' | python3 -m json.tool 2>/dev/null || cat "$WORK/board1.json"

echo
echo "== round 2: the field runs again → the benchmark accumulates =="
run_round round2 >/dev/null
$LEX run --allow-effects io "$HERE/reputation_rank.lex" rank "\"$WORK/board1.json\"" "\"$WORK/round2.json\"" | grep '^{' | python3 -m json.tool 2>/dev/null

echo
echo "files in: $WORK"
