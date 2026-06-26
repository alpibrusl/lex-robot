#!/usr/bin/env bash
# nplayer_bazaar_llm_run.sh — launch the N-player Bazaar referee and one
# LLM-driven seat per model, then play a full multi-model draft to completion.
#
# Each seat is a different hosted open-weights model (OpenCode Zen "Go plan"),
# so the standings are a tiny live model-vs-model tournament.
#
# Usage:
#   OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) \
#     NB_MODELS="glm-5.1 kimi-k2.6 deepseek-v4-flash" \
#     LEX=lex ./examples/nplayer_bazaar_llm_run.sh
set -u
LEX="${LEX:-lex}"
PORT="${NB_PORT:-8902}"
MODELS="${NB_MODELS:-glm-5.1 kimi-k2.6 deepseek-v4-flash}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REF_POLICY="--allow-effects env,net,concurrent,io"
BOT_POLICY="--allow-effects concurrent,env,fs_write,io,llm,net,proc,sql,time"

if [ -z "${OPENCODE_API_KEY:-}" ]; then
  echo "OPENCODE_API_KEY is required (e.g. \$(cat ~/.credentials/opencode/key))" >&2; exit 1
fi
if lsof -i ":$PORT" >/dev/null 2>&1; then
  echo "port $PORT is busy — set NB_PORT to a free port" >&2; exit 1
fi

# count seats = number of models
set -- $MODELS
SEATS=$#
echo "== launching referee on :$PORT for $SEATS LLM seats: $MODELS =="
NB_SEATS="$SEATS" NB_PORT="$PORT" $LEX run $REF_POLICY "$HERE/nplayer_bazaar.lex" run >/tmp/nb-referee.log 2>&1 &
REF=$!
trap 'kill $REF 2>/dev/null; pkill -f nplayer_bazaar 2>/dev/null' EXIT
for _ in $(seq 1 40); do grep -q "referee on" /tmp/nb-referee.log 2>/dev/null && break; sleep 0.3; done

i=0
for M in $MODELS; do
  i=$((i + 1))
  BOT_MODEL="$M" NB_PORT="$PORT" OPENCODE_API_KEY="$OPENCODE_API_KEY" \
    $LEX run $BOT_POLICY "$HERE/nplayer_bazaar_llm_bot.lex" run >"/tmp/nb-llm-$i.log" 2>&1 &
  sleep 0.6   # stagger joins so seat order is deterministic
done

# LLM turns are slow (reasoning models) — wait up to ~5 min for over=1
for _ in $(seq 1 300); do grep -q "over=1" /tmp/nb-referee.log 2>/dev/null && break; sleep 1; done
sleep 1

echo
echo "== final state =="
grep "over=1" /tmp/nb-referee.log | tail -1 || echo "(game did not finish — see /tmp/nb-referee.log)"
echo
echo "== referee transcript =="
grep "\[bazaar\]" /tmp/nb-referee.log
echo
echo "== per-model turns =="
i=0
for M in $MODELS; do
  i=$((i + 1))
  echo "-- seat $i: $M --"
  grep "turn →\|error\|required" "/tmp/nb-llm-$i.log" 2>/dev/null | head -6
done
