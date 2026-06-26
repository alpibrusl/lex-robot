#!/usr/bin/env bash
# nplayer_bazaar_run.sh — launch the N-player Bazaar referee and N heuristic
# bots, let them play a full draft, and print the final standings.
#
# Usage: NB_SEATS=3 NB_PORT=8902 LEX=lex ./examples/nplayer_bazaar_run.sh
set -u
LEX="${LEX:-lex}"
SEATS="${NB_SEATS:-3}"
PORT="${NB_PORT:-8902}"
POLICY="--allow-effects env,net,concurrent,io"
HERE="$(cd "$(dirname "$0")" && pwd)"

if lsof -i ":$PORT" >/dev/null 2>&1; then
  echo "port $PORT is busy — set NB_PORT to a free port" >&2; exit 1
fi

echo "== launching referee on :$PORT for $SEATS seats =="
NB_SEATS="$SEATS" NB_PORT="$PORT" $LEX run $POLICY "$HERE/nplayer_bazaar.lex" run >/tmp/nb-referee.log 2>&1 &
REF=$!
trap 'kill $REF 2>/dev/null; pkill -f nplayer_bazaar 2>/dev/null' EXIT

# wait for the referee to bind
for _ in $(seq 1 40); do grep -q "referee on" /tmp/nb-referee.log 2>/dev/null && break; sleep 0.3; done

# launch SEATS bots, alternating strategy (0 = max value, 1 = max value/price)
PIDS=()
for i in $(seq 1 "$SEATS"); do
  STRAT=$(( (i - 1) % 2 ))
  BOT_STRAT="$STRAT" NB_PORT="$PORT" $LEX run $POLICY "$HERE/nplayer_bazaar_bot.lex" run >"/tmp/nb-bot-$i.log" 2>&1 &
  PIDS+=("$!")
  sleep 0.4   # stagger joins so seat order is deterministic
done

# the game ends when the pool is exhausted; wait for "over=1" to appear
for _ in $(seq 1 60); do grep -q "over=1" /tmp/nb-referee.log 2>/dev/null && break; sleep 0.5; done
sleep 1

echo
echo "== final state =="
grep "over=1" /tmp/nb-referee.log | tail -1 || echo "(game did not finish — see /tmp/nb-referee.log)"
echo
echo "== referee transcript =="
grep "\[bazaar\]" /tmp/nb-referee.log
