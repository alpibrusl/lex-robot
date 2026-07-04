#!/usr/bin/env bash
# examples/xlerobot_policy_run.sh — the safe-RL/eval loop, end to end:
#
#   train/eval  -> gym_env/xlerobot_policy_eval.py runs a closed-loop policy
#                  (today: a reactive geometric controller; a future RL-trained
#                  policy against the registered LexXLeRobotFetch-v0 gym env
#                  plugs into the same rollout format) and writes its rollout
#   roll out    -> examples/xlerobot_policy_rollout.lex replays that EXACT
#                  sequence through the governed skill surface (grant-checked,
#                  clamped, chained into a robot_task trail)
#   verify      -> the lex-games robot_task referee re-derives the verdict
#   reputation  -> the policy's did:lex identity signs the verified submission
#                  into the durable reputation registry (examples/agent_registry.lex)
#
# Without a Python+mujoco venv (CI, or no venv on PATH), this replays the
# COMMITTED fixture (examples/fixtures/xlerobot_policy_rollout.json) instead of
# regenerating it — the eval step is out-of-band (like examples/physics/), but
# the roll-out/verify/reputation steps have no ML dependency and run every time.
#
# Usage: ./examples/xlerobot_policy_run.sh [venv-python]
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
PORT="${LEX_ROBOT_SIDECAR_PORT:-8900}"
PY="${1:-${PYTHON:-}}"

ROLLOUT="$WORK/rollout.json"
if [ -n "$PY" ] && [ -x "$PY" ]; then
  echo "→ eval: running the policy against MuJoCo ($PY)"
  "$PY" "$HERE/../gym_env/xlerobot_policy_eval.py" "$ROLLOUT" || true
fi
if [ ! -s "$ROLLOUT" ]; then
  echo "→ eval: no venv given/available — replaying the committed fixture"
  cp "$HERE/fixtures/xlerobot_policy_rollout.json" "$ROLLOUT"
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
  '"xlerobot-reach-greedy"' '"xlerobot-policy-seed-0001"' '"robot"' '"robot_task"' "\"$TRAIL\"" '"0"' '"true"' 2>/dev/null | grep '^{')"
printf '{"entries":[%s]}' "$E1" > "$WORK/batch.json"
$LEX run --allow-effects io,crypto "$HERE/agent_registry.lex" apply '"none.json"' "\"$WORK/batch.json\"" 2>/dev/null | grep '^{' \
  | python3 -c 'import sys, json
d = json.load(sys.stdin)
p = d["profiles"][0]
print("reputation: " + p["did"] + "  score=" + str(p["reputation"]) + "  apps=" + str(p["apps"]) + "  (credited=" + str(d["credited"]) + ", rejected=" + str(d["rejected"]) + ")")'

rm -rf "$WORK"
