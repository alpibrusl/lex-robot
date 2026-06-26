#!/usr/bin/env bash
# nplayer_bazaar_loop_run.sh — the full closed loop, end to end:
#
#   play  → the N-player Bazaar referee records a hash-chained trail per match
#   trail → it writes that trail as JSONL when the match ends
#   verify→ replay the trail through lex-games' nbazaar referee (recompute scores)
#   rank  → fold both matches into an ELO leaderboard
#
# Two matches are played (a 3-seat then a 2-seat rematch) with heuristic bots, so
# the run is self-contained and deterministic-ish; swap in nplayer_bazaar_llm_bot
# for a live multi-model league.
#
# Usage: LEX=lex ./examples/nplayer_bazaar_loop_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REF_POLICY="--allow-effects env,net,concurrent,io,fs_write"
BOT_POLICY="--allow-effects env,net,concurrent,io"
IO="--allow-effects io"
WORK="$(mktemp -d)"

play() {                       # play <port> <nseats> <trail_path> <strat...>
  local port="$1" seats="$2" trail="$3"; shift 3
  pkill -f nplayer_bazaar 2>/dev/null; sleep 1
  if lsof -i ":$port" >/dev/null 2>&1; then echo "port $port busy" >&2; return 1; fi
  NB_SEATS="$seats" NB_PORT="$port" NB_TRAIL="$trail" \
    $LEX run $REF_POLICY "$HERE/nplayer_bazaar.lex" run >"$WORK/ref-$port.log" 2>&1 &
  local ref=$!
  for _ in $(seq 1 40); do grep -q "referee on" "$WORK/ref-$port.log" 2>/dev/null && break; sleep 0.3; done
  local i=0
  for strat in "$@"; do
    i=$((i + 1))
    BOT_STRAT="$strat" NB_PORT="$port" $LEX run $BOT_POLICY "$HERE/nplayer_bazaar_bot.lex" run >"$WORK/bot-$port-$i.log" 2>&1 &
    sleep 0.4
  done
  for _ in $(seq 1 60); do [ -s "$trail" ] && break; sleep 0.5; done
  sleep 1; kill $ref 2>/dev/null; pkill -f nplayer_bazaar 2>/dev/null
  grep "\[bazaar\]" "$WORK/ref-$port.log" | tail -1
}

echo "== match 1: 3 seats (alpha greedy, beta ratio, gamma greedy) =="
play 8902 3 "$WORK/match1.jsonl" 0 1 0
echo "== match 2: 2-seat rematch (alpha greedy vs beta ratio) =="
play 8903 2 "$WORK/match2.jsonl" 0 1

echo
echo "== verify the emitted trails (scores recomputed by the rules) =="
echo -n "match1: "; $LEX run $IO "$HERE/nbazaar_verify.lex" verify "\"$WORK/match1.jsonl\"" | head -1
echo -n "match2: "; $LEX run $IO "$HERE/nbazaar_verify.lex" verify "\"$WORK/match2.jsonl\"" | head -1

echo
echo "== ELO season across both matches =="
cat > "$WORK/round1.json" <<JSON
[ { "trail": "$WORK/match1.jsonl", "seats": ["alpha","beta","gamma"] } ]
JSON
cat > "$WORK/round2.json" <<JSON
[ { "trail": "$WORK/match2.jsonl", "seats": ["alpha","beta"] } ]
JSON
$LEX run $IO "$HERE/nbazaar_rank.lex" rank "\"$WORK/none.json\"" "\"$WORK/round1.json\"" | grep '^{' > "$WORK/s1.json"
echo "after round 1:"; cat "$WORK/s1.json"
$LEX run $IO "$HERE/nbazaar_rank.lex" rank "\"$WORK/s1.json\"" "\"$WORK/round2.json\"" | grep '^{' > "$WORK/s2.json"
echo "after round 2:"; cat "$WORK/s2.json"

echo
echo "trails + standings in: $WORK"
