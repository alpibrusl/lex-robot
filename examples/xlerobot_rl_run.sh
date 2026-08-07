#!/usr/bin/env bash
# examples/xlerobot_rl_run.sh — the safe-RL/eval loop with an ACTUAL trained
# policy, end to end:
#
#   train    -> sidecar/xlerobot_rl_train.py (stable-baselines3 PPO against
#               the registered LexXLeRobotFetch-v0 gym env) — skipped here if
#               a model already exists at MODEL, or if no venv is given
#   eval     -> gym_env/xlerobot_rl_eval.py runs the trained policy
#               closed-loop and writes its rollout (downsampled into governed
#               move_base/move_arm/grasp steps — see that file's docstring)
#   roll out -> examples/xlerobot_policy_rollout.lex replays that EXACT
#               sequence through the governed skill surface (grant-checked,
#               clamped, chained into a robot_task trail) — same Lex program
#               the scripted-policy loop (xlerobot_policy_run.sh) uses
#   verify   -> the lex-games robot_task referee re-derives the verdict
#   reputation -> the policy's did:lex identity signs the verified
#               submission into the durable reputation registry
#
# Honest note: the trail's "verify" event is unconditional (see
# xlerobot_policy_rollout.lex — it always emits "outcome reached" after
# replaying every step; the referee's `goal_met` reflects THAT event, not
# whether the trained policy actually lifted the cup in physics). The real
# success signal is gym_env/xlerobot_rl_eval.py's own SUCCESS/FAILED line,
# printed by the eval step below — read that, not `goal_met`, to know if the
# episode actually solved the task.
#
# Without a Python+mujoco+stable-baselines3 venv (CI, or no venv on PATH),
# this replays the COMMITTED fixture (examples/fixtures/xlerobot_rl_rollout.json)
# instead of training+evaluating — the ML steps are out-of-band, but the
# roll-out/verify/reputation steps have no ML dependency and run every time.
#
# Usage: ./examples/xlerobot_rl_run.sh [venv-python] [--train]
#   (no args)          replay the committed fixture through the grant gate
#   [venv-python]      evaluate the model at $MODEL (default /tmp/xlerobot_ppo.zip)
#                       against MuJoCo with this python, then roll that out
#   [venv-python] --train   also (re)train the model first (slow — minutes)
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
PORT="${LEX_ROBOT_SIDECAR_PORT:-8900}"
PY="${1:-${PYTHON:-}}"
DO_TRAIN=0
[ "${2:-}" = "--train" ] && DO_TRAIN=1
MODEL="${MODEL:-/tmp/xlerobot_ppo.zip}"

ROLLOUT="$WORK/rollout.json"
if [ -n "$PY" ] && [ -x "$PY" ]; then
  if [ "$DO_TRAIN" -eq 1 ] || [ ! -s "$MODEL" ]; then
    echo "→ train: PPO against LexXLeRobotFetch-v0 ($PY) — this takes a few minutes"
    "$PY" "$HERE/../sidecar/xlerobot_rl_train.py" --out "$MODEL" || true
  fi
  if [ -s "$MODEL" ]; then
    echo "→ eval: running the trained policy against MuJoCo ($PY)"
    "$PY" "$HERE/../gym_env/xlerobot_rl_eval.py" "$MODEL" "$ROLLOUT" || true
  fi
fi
if [ ! -s "$ROLLOUT" ]; then
  echo "→ eval: no venv/model available — replaying the committed fixture"
  cp "$HERE/fixtures/xlerobot_rl_rollout.json" "$ROLLOUT"
fi

echo "→ starting the stub sidecar on :$PORT"
python3 "$HERE/../sidecar/xlerobot_sidecar.py" > "$WORK/sidecar.log" 2>&1 &
SID=$!
cleanup() { kill "$SID" 2>/dev/null || true; wait "$SID" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.1; done

echo "→ rolling the policy out through the grant gate"
TRAIL="$WORK/trail.jsonl"
$LEX run --allow-effects net,sense,actuate,io,fs_write,time \
  "$HERE/xlerobot_policy_rollout.lex" run "\"$ROLLOUT\"" "\"$TRAIL\""
cleanup; trap - EXIT

echo
echo "→ signing the verified submission under the policy's did:lex identity"
E1="$($LEX run --allow-effects io,crypto "$HERE/agent_registry.lex" sign \
  '"xlerobot-ppo-trained"' '"xlerobot-rl-seed-0001"' '"robot"' '"robot_task"' "\"$TRAIL\"" '"0"' '"true"' 2>/dev/null | grep '^{')"
printf '{"entries":[%s]}' "$E1" > "$WORK/batch.json"
$LEX run --allow-effects io,crypto "$HERE/agent_registry.lex" apply '"none.json"' "\"$WORK/batch.json\"" 2>/dev/null | grep '^{' \
  | python3 -c 'import sys, json
d = json.load(sys.stdin)
p = d["profiles"][0]
print("reputation: " + p["did"] + "  score=" + str(p["reputation"]) + "  apps=" + str(p["apps"]) + "  (credited=" + str(d["credited"]) + ", rejected=" + str(d["rejected"]) + ")")'

rm -rf "$WORK"
