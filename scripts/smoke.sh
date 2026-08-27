#!/usr/bin/env bash
# Reproducible smoke test: type-check everything, then run the four zero-dependency
# governance demos and assert the load-bearing lines. No ML deps (lex + python3).
# Exit non-zero on any failure — suitable for CI.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
skipped=0
pass() { printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=1; }
skip() { printf "  \033[33mSKIP\033[0m %s\n" "$1"; skipped=$((skipped+1)); }

# Type-check every Lex source. A file is SKIPped (visible, not silent) only when
# an external package it imports isn't present in the minimal CI — the lex-guard
# A2A-commerce demos use the `../lex-guard` path dep, absent from a lone lex-robot
# checkout. A genuine type error still FAILs. (std.crypto.ed25519 — used by the
# A2A cards and lex-games — ships in lex v0.9.11, the toolchain CI installs, so
# those type-check rather than skip.)
skippable() { grep -qiE "package import error|no such file|failed to (fetch|resolve|clone)|could not (find|resolve)" <<<"$1"; }
echo "== lex check =="
for f in src/*.lex examples/*.lex tests/*.lex; do
  if out="$(lex check "$f" 2>&1)"; then
    pass "check $f"
  elif skippable "$out"; then
    skip "check $f (needs an external package not present here — e.g. ../lex-guard)"
  else
    bad "check $f"
    echo "$out" | sed 's/^/      /'
  fi
done
[ "$skipped" -gt 0 ] && echo "  ($skipped skipped — external dep not present in this checkout)"

# Run a demo and assert an expected substring appears in its output.
expect() { # <demo> <needle> <label>
  out="$(scripts/demo.sh "$1" 2>/dev/null | tr -d '\r')"
  if grep -qF "$2" <<<"$out"; then pass "$3"; else bad "$3 — missing: $2"; echo "$out" | sed 's/^/      /'; fi
}

echo "== demos =="
expect grant "denied" "grant gate denies out-of-bounds move"
expect llm   "BLOCKED (never sent): 3" "LLM planner blocks 3 unsafe actions"
expect llm   "chain intact" "LLM planner audit chain verifies"
expect task  "SUCCESS" "evidence-gated task graph succeeds"
expect depot "task SUCCESS" "OCPP-gated depot demo succeeds"
expect dynamic_keepout "commands BLOCKED" "dynamic keep-out blocks intrusions into moving bystander zone"
expect dynamic_keepout "entered zone: 0" "dynamic keep-out: zero commands reach the moving zone when governed"
expect xlerobot "denied: base target outside granted floor area" "xlerobot: base kept inside the granted floor area"
expect xlerobot "denied: right arm target outside granted workspace" "xlerobot: arm kept inside the granted reach box"
expect xlerobot "denied: skill move_base not in grant" "xlerobot: arm grant holds no base authority (cross-envelope refusal)"
expect xlerobot_task "governed_fetch   verified=yes legal=yes goal=yes" "xlerobot task: governed fetch verifies through the robot_task referee"
expect xlerobot_task "DISQUALIFIED" "xlerobot task: forged over-grant entry is disqualified"
expect xlerobot_task "submission written" "xlerobot task: portable JSONL submission is written"
expect xlerobot_voice "voice goal: fetch the cup to the table" "xlerobot voice: spoken transcript becomes the human goal"
expect xlerobot_voice "denied: skill listen not in grant" "xlerobot voice: mic-less grant refuses listen at the capability layer"
expect xlerobot_touch "tap: yes" "xlerobot touch: screen prompt's tapped answer reaches the governed program"
expect xlerobot_touch "denied: skill read_touch not in grant" "xlerobot touch: ask-only grant refuses the tap read at the capability layer"
expect xlerobot_vision "detect: cup found (judged by the vision service)" "vision split: sidecar frame judged by the vision service over HTTP"
expect xlerobot_vision "(mock) a cup" "vision split: list_visible_items round-trips the vision service"
expect vision_pose "cup at world x=322mm y=30mm z=0mm" "vision pose: the 2D box projects onto the calibrated plane"
expect vision_pose "→ reached (5 cm above the cup)" "vision pose: the projected position is reachable by a granted arm"
expect vision_pose "below the 0.995 floor — refusing to guess a position" "vision pose: the confidence floor refuses instead of guessing"
expect stream 'stream frame: {"joints"' "stream: /stream pushes joint+base state over WebSocket into dial_ws"
expect stream "stream closed cleanly (server-bounded)" "stream: the bounded stream ends with a clean server-side close"
expect home_wash "REFUSED: peak tariff above the 15c/kWh ceiling" "home wash: peak-tariff start refused by the examples-tested gate, never sent"
expect home_wash "washer started in off-peak window" "home wash: same request passes in the valley window"
expect home_wash "denied: skill appliance_start not in grant" "home wash: observer grant may read the house but not actuate it"
expect xlerobot_find "located 'cup' at world" "xlerobot find: locate_object turns an object name into a real position"
expect xlerobot_find "grasp 15N                  → reached" "xlerobot find: vision-driven approach + grasp succeeds"
expect ap2 "sale completed: Red Ceramic Bowl for 8 cr (receipt ap2-pot-001-" "ap2: mandate-backed sale completes with a receipt"
expect ap2 "REFUSED by credential provider: exceeds instrument ceiling" "ap2: over-ceiling payment mandate is never signed"
expect ap2 "REFUSED by stall: mandate_required" "ap2: the stall refuses a sale without mandates"
expect ap2 "REFUSED by stall: mandate_invalid: payment mandate bound to a different checkout" "ap2: hash binding refuses a swapped checkout"
expect ap2 "denied: skill complete_sale not in grant (never sent)" "ap2: browse-only grant cannot buy — refused before any request exists"
expect dispense "B2: short — 210/300 µl; top-up 90 µl" "dispense: the scale catches the short dispense; bounded top-up"
expect dispense "task SUCCESS — all 3 wells within tolerance (Verify gate passed)" "dispense: SUCCESS only when every well verifies"
expect dispense "REFUSED: well D4 not in the granted wells (never sent)" "dispense: well allowlist refuses before any request exists"
expect dispense "REFUSED: 900 µl above the 500 µl single-dispense ceiling (never sent)" "dispense: volume ceiling refuses before any request exists"
expect dispense "TAMPERED entry detected: forged measured_ul fails the content-hash check" "dispense: a doctored audit record is caught by chain verify"

# The LLM planner's tool-dispatch loop, verified for real with a scripted
# mock model (no OpenCode API key / network needed): both tool calls it
# proposes go over a real A2A round-trip into a real, live a2a_robot_server
# process, so the actual grant — not a stand-in — decides allow/deny.
echo "== LLM planner (mock model, real grant) =="
if bash scripts/llm_planner_mock_test.sh 2>/dev/null | grep -qF "ALL PASS:"; then
  pass "llm planner: mock-scripted tool calls reach the real grant-gated A2A server"
else
  bad "llm planner: mock-scripted tool-dispatch test failed"
fi

# The safe-RL/eval loop, closed: a policy's rollout (here, the committed fixture
# — regenerating it needs a mujoco venv, out-of-band) is replayed through the
# ACTUAL grant gate (not re-scripted), verified by the robot_task referee, and
# folded into the did:lex reputation registry (the kernel, #73).
echo "== xlerobot policy rollout =="
xpr="$(bash examples/xlerobot_policy_run.sh 2>/dev/null | tr -d '\r')"
if grep -qF '"verified":true' <<<"$xpr" && grep -qF '"legal":true' <<<"$xpr" && grep -qF '"goal_met":true' <<<"$xpr"; then pass "xlerobot policy: rollout replayed through the grant gate verifies"; else bad "xlerobot policy: rollout did not verify"; echo "$xpr" | sed 's/^/      /'; fi
if grep -qF "reputation: did:lex:agent:xlerobot-reach-greedy" <<<"$xpr" && grep -qF "credited=1, rejected=0" <<<"$xpr"; then pass "xlerobot policy: verified rollout signs into the did:lex reputation registry"; else bad "xlerobot policy: reputation fold missing/wrong"; fi
expect tool_fire "BLOCKED: target outside tool firing zone" "tool fire: out-of-zone attempts blocked"
expect tool_fire "BLOCKED: workpiece not clamped" "tool fire: pre-clamp attempt blocked"
expect tool_fire "→ FIRED" "tool fire: valid fire after clamp verify"

# The budget wall (DESIGN.md §6/§9.5): the grant carries action + wall-clock
# budgets, and the in-box supervisor (src/budget.lex) kills a run that exceeds
# them BEFORE the next command leaves the box — the runtime twin of the effect
# wall. budget_demo uses a zero-action grant, so the same task that SUCCEEDs
# above is killed with no command sent, and the kill is recorded in the trail.
echo "== budget kill =="
expect budget "action budget exhausted" "supervisor reports the budget breach reason"
expect budget "task KILLED" "zero-action grant → run killed before any command"

echo "== non-finite refusal (#193) =="
# tests/test_nonfinite.lex panics (1/0) on any failure; exit 0 on all-pass.
# Pure grant/wire functions only — no sidecar, no ML deps.
if lex run --allow-effects io tests/test_nonfinite.lex main >/dev/null 2>&1; then
  pass "grant refuses NaN/inf: workspace, keep-out boxes, and all three clamps"
else
  bad "grant admitted a non-finite value (or a clamp stopped reporting what bit)"
  lex run --allow-effects io tests/test_nonfinite.lex main 2>&1 | sed 's/^/      /'
fi

echo "== MCP grant gate =="
# test_mcp_grant.lex panics (1/0) on any failure; exit 0 on all-pass.
if scripts/demo.sh mcp_grant >/dev/null 2>&1; then
  pass "MCP grant gate: all four assertions pass (deny / allow / clamp / kill)"
else
  bad "MCP grant gate: one or more assertions failed"
fi

# The MCP server serves actuation over HTTP, but the effect wall still holds at
# RUN time: the request handler declares `sense`/`actuate`, so withholding them
# from --allow-effects makes the server unable to drive the arm even though the
# same code is reachable over the network. (We don't bind a port here — the run
# is rejected before serving because the actuating skills are unreachable.)
mcpw="$(lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,approval \
          examples/mcp_server_demo.lex run 2>&1 | tr -d '\r')"
if grep -qF "effect \`actuate\` not in --allow-effects" <<<"$mcpw"; then
  pass "MCP server: actuate withheld → actuating tools unreachable (runtime wall holds over HTTP)"
else
  bad "MCP server: actuate withheld did NOT block the server"
  echo "$mcpw" | sed 's/^/      /'
fi

echo "== A2A grant gate =="
# test_a2a_robot_grant.lex panics (1/0) on any failure; exit 0 on all-pass.
# Drives the standard Google A2A tasks/send wire shape (via lex-agent's
# protocol/message/task types), not just the internal dispatcher — proving
# the grant holds through the standard-protocol layer too.
if scripts/demo.sh a2a_grant >/dev/null 2>&1; then
  pass "A2A grant gate: all assertions pass (deny / allow / clamp / kill / per-arm / unknown-skill)"
else
  bad "A2A grant gate: one or more assertions failed"
fi

# Same runtime effect-wall property as the MCP server, over the A2A wire.
a2aw="$(lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,approval \
          examples/a2a_robot_demo.lex run 2>&1 | tr -d '\r')"
if grep -qF "effect \`actuate\` not in --allow-effects" <<<"$a2aw"; then
  pass "A2A server: actuate withheld → actuating skills unreachable (runtime wall holds over HTTP)"
else
  bad "A2A server: actuate withheld did NOT block the server"
  echo "$a2aw" | sed 's/^/      /'
fi

# The effect wall (DESIGN.md §4): actuate/sense are real Lex effects, so the
# judgment/authority split is type-enforced — not a runtime convention. Both
# halves are NEGATIVE checks: the build must FAIL to actuate when it shouldn't.
echo "== effect wall =="
neg="$ROOT/.effwall_neg.lex"
cat > "$neg" <<'LEXEOF'
import "./src/types" as t
import "./src/skills" as skills
# A "look but don't touch" routine that ILLEGALLY tries to drive the arm.
fn calibrate(r :: t.Robot) -> [net, sense] t.Outcome {
  skills.move_to(r, { pos: { x: 0.2, y: 0.0, z: 0.1 }, rx: 0.0, ry: 0.0, rz: 0.0 })
}
LEXEOF
if lex check "$neg" >/dev/null 2>&1; then
  bad "compile-time: [sense]-only routine calling move_to type-checked (should be rejected)"
else
  pass "compile-time: [sense] routine cannot call an [actuate] skill (lex check rejects it)"
fi
rm -f "$neg"

# The leLab adapter's read-only guarantee, as a NEGATIVE check on both halves.
# `--allow-effects` is checked over the whole reachable import graph, so the
# read-only entry point cannot merely avoid calling an actuating function -- it
# must live in a module with no import path to one. That is why the adapter is
# split in two, and this is the assertion that keeps it split: the sensing
# module must run under a sense-only policy, and the full one must not.
if lex check src/lelab_adapter.lex 2>&1 | grep -qF "required effects: env, io, net, sense"; then
  pass "leLab adapter: the read-only module's effect row contains no actuate"
else
  bad "leLab adapter: read-only module now requires actuate (the split has leaked)"
  lex check src/lelab_adapter.lex 2>&1 | sed 's/^/      /'
fi

lelabw="$(lex run --allow-effects io,env,net,sense src/lelab_adapter_full.lex run 2>&1 | tr -d '\r')"
if grep -qF "effect \`actuate\` not in --allow-effects" <<<"$lelabw"; then
  pass "leLab adapter: actuate withheld → the FULL adapter refuses to serve at all"
else
  bad "leLab adapter: full adapter served with actuate withheld (should be blocked)"
  echo "$lelabw" | sed 's/^/      /'
fi

lelabneg="$ROOT/.lelab_neg.lex"
cat > "$lelabneg" <<'LEXEOF'
import "./src/types" as t
import "./src/skills" as skills
import "./src/lelab_adapter" as base
# The read-only adapter, "just this once" reaching for an actuating skill.
fn sneak(r :: t.Robot) -> [net, sense] Option[Response] {
  Some(base.ok_json(base.outcome_json(skills.move_arm(r, "left", { pos: { x: 0.2, y: 0.0, z: 0.1 }, rx: 0.0, ry: 0.0, rz: 0.0 }))))
}
LEXEOF
if lex check "$lelabneg" >/dev/null 2>&1; then
  bad "leLab adapter: a [sense]-only handler calling move_arm type-checked (should be rejected)"
else
  pass "leLab adapter: a read-only handler cannot reach move_arm (lex check rejects it)"
fi
rm -f "$lelabneg"

# The actuating skills that used to have no Lex expression at all -- and so no
# grant naming them. Each is now wrapped and gated; this asserts the gate is a
# refusal, not a warning, and that it refuses BEFORE the request exists. There
# is deliberately no sidecar on 127.0.0.1:1: anything that actually sent would
# come back `stalled`, so four `denied` lines are the never-sent proof.
gate="$ROOT/.gate_actuating.lex"
cat > "$gate" <<'LEXEOF'
import "std.io" as io
import "./src/types" as t
import "./src/skills" as skills
import "./src/wire" as wire

fn narrow() -> t.Grant {
  {
    skills: ["read_joints"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 0.1, max_force: 1.0, max_grip_force: 1.0,
    budget_actions: 10, budget_wall_ms: 1000,
  }
}

fn main() -> [net, sense, actuate, io] Unit {
  let r :: t.Robot := { sidecar_url: "http://127.0.0.1:1", grant: narrow() }
  let __0 := io.print(wire.outcome_str(skills.teach_replay(r, "demo", 1.0)))
  let __1 := io.print(wire.outcome_str(skills.teach_home_go(r, "left")))
  let __2 := io.print(wire.outcome_str(skills.release_arm(r, "left")))
  let __3 := io.print(wire.outcome_str(skills.reset(r)))
}
LEXEOF
gateout="$(lex run --allow-effects net,sense,actuate,io "$gate" main 2>&1 | tr -d '\r')"
for sk in teach_replay teach_home_go release_arm reset; do
  if grep -qF "denied: skill $sk not in grant" <<<"$gateout"; then
    pass "grant gate: $sk refused before any request exists (never sent)"
  else
    bad "grant gate: $sk was not refused by the grant"
    echo "$gateout" | sed 's/^/      /'
  fi
done
rm -f "$gate"

# ha_sidecar.lex claims to be a drop-in for ha_sidecar.py -- "same env vars,
# same HTTP API". Assert it instead of trusting it: both servers, same 28
# requests, byte-identical answers. The appliance cases read back the state
# they just changed, so the two are compared as state machines rather than as
# pure functions.
haq="$ROOT/.ha_lex.log"; hap="$ROOT/.ha_py.log"
rm -f /tmp/lex-ha-8951.db
LEX_ROBOT_SIDECAR_PORT=8951 lex run --allow-effects env,fs_write,io,net,sql \
  "$ROOT/sidecar/ha_sidecar.lex" run >"$haq" 2>&1 &
halex=$!
LEX_ROBOT_SIDECAR_PORT=8952 "${PYTHON:-python3}" "$ROOT/sidecar/ha_sidecar.py" >"$hap" 2>&1 &
hapy=$!
sleep 5
if haout="$(LEX_PORT=8951 PY_PORT=8952 "${PYTHON:-python3}" "$ROOT/scripts/ha_parity.py" 2>&1)"; then
  pass "ha sidecar: the Lex port answers identically to the Python it replaces"
else
  bad "ha sidecar: the Lex port diverged from the Python it replaces"
  echo "$haout" | sed 's/^/      /'
  sed -n '1,5p' "$haq" | sed 's/^/      lex: /'
fi
kill $halex $hapy 2>/dev/null || true
rm -f "$haq" "$hap" /tmp/lex-ha-8951.db

# The structured SkillOutcome: the single grant-checked move records
# skill+args+grant (integer milli-units) in the trail, so the lex-games
# `robot_task` verifier can re-derive that the move stayed inside its workspace
# box. The `task` demo (run above) wrote its trail to /tmp/lex-robot-trail.db.
echo "== structured SkillOutcome =="
scripts/demo.sh task >/dev/null 2>&1 || true   # (re)write /tmp/lex-robot-trail.db
if command -v sqlite3 >/dev/null 2>&1; then
  pj="$(sqlite3 /tmp/lex-robot-trail.db "select payload_json from events where kind='execute' limit 1;" 2>/dev/null || true)"
  if grep -qF '"skill":"move_to"' <<<"$pj" && grep -qF '"grant"' <<<"$pj"; then
    pass "execute event records the structured SkillOutcome (skill+args+grant)"
  else
    bad "execute event is not the structured SkillOutcome — got: $pj"
  fi
else
  skip "structured SkillOutcome (sqlite3 not present)"
fi

# Run-time: the grant's authority is --allow-effects. Withhold `actuate` and the
# same demo code is unreachable before it runs — no command can leave the box.
if lex run --allow-effects net,sense,io examples/demo.lex run >/dev/null 2>&1; then
  bad "run-time: demo.lex ran with actuate withheld (should be blocked)"
else
  pass "run-time: actuate withheld → actuating skill blocked before execution"
fi

# The live policy-eval leaderboard (direction #3, end to end): real rollouts under
# different ISO-derived grants are scored through the lex-games robot_task referee
# and ranked; the compliant policy wins and a forged out-of-grant submission is
# disqualified — proving the legality gate on live runs, not just a fixture.
echo "== live policy-eval leaderboard =="
pe="$(bash examples/policy_eval_run.sh 2>/dev/null | tr -d '\r')"
if grep -qF "winner: compliant_policy" <<<"$pe"; then pass "live leaderboard: compliant policy wins"; else bad "live leaderboard: wrong/no winner"; echo "$pe" | sed 's/^/      /'; fi
if grep -qF "DISQUALIFIED" <<<"$pe"; then pass "live leaderboard: forged over-grant submission disqualified"; else bad "live leaderboard: forged submission not disqualified"; fi

# Durable did:lex identity + portable reputation (the kernel, #73): an agent is
# an ed25519 keypair, so a reputation submission is SIGNED, not merely claimed.
# One identity earns a verified trail in two apps (robot + agent-ops) and its
# profile accumulates across both; an impersonator (same did, different key) and
# a tampered trail both earn nothing.
echo "== portable reputation =="
pr="$(bash examples/portable_reputation_run.sh 2>/dev/null | tr -d '\r')"
if grep -qF "atlas earned in 2 apps under one identity" <<<"$pr"; then pass "portable reputation: one identity accrues across two apps"; else bad "portable reputation: cross-app accrual missing"; echo "$pr" | sed 's/^/      /'; fi
if grep -qF "impersonation rejected=1" <<<"$pr"; then pass "identity: impersonation (same did, different key) earns nothing"; else bad "identity: impersonation not rejected"; fi
if grep -qF "tampered submission credited=0" <<<"$pr"; then pass "identity: tampered trail breaks the signature — earns nothing"; else bad "identity: tampered submission not rejected"; fi

# The control plane (the kernel, #73): issue / scope / revoke capability tokens,
# with a reviewable trail. A valid, unexpired, unrevoked token is admitted and
# its embedded Grant still gates concrete commands through grant.lex's own
# checks (the control plane doesn't bypass the physical layer); a token
# presented by the wrong subject, a revoked token, an expired token, and a
# forged token are all refused, and every decision lands on the trail.
echo "== control plane =="
cpo="$(lex run --allow-effects io,sql,time,fs_write,crypto examples/control_plane_demo.lex run 2>/dev/null | tr -d '\r')"
if grep -qF "1. valid, right subject] ADMITTED" <<<"$cpo" && grep -qF "denied — control plane doesn't bypass the physical layer" <<<"$cpo"; then pass "control plane: valid token admitted, out-of-workspace still refused by grant.lex"; else bad "control plane: valid-token admission or composability check failed"; echo "$cpo" | sed 's/^/      /'; fi
if grep -qF "3. wrong subject presents it] REFUSED — token not issued to this subject" <<<"$cpo"; then pass "control plane: token refused for the wrong subject"; else bad "control plane: wrong-subject refusal missing"; fi
if grep -qF "4. revoked] REFUSED — token revoked" <<<"$cpo"; then pass "control plane: revoked token id is refused"; else bad "control plane: revocation not enforced"; fi
if grep -qF "5. expired] REFUSED — token expired" <<<"$cpo"; then pass "control plane: expired token is refused"; else bad "control plane: expiry not enforced"; fi
if grep -qF "6. forged (attacker's key)] REFUSED — signature invalid" <<<"$cpo"; then pass "control plane: forged token (attacker's key) is refused"; else bad "control plane: forged token not rejected"; fi
if grep -qF "review trail: 1 issued, 1 admitted, 4 refused, 1 revoked" <<<"$cpo"; then pass "control plane: every issue/admit/refuse/revoke decision is on the reviewable trail"; else bad "control plane: review trail counts wrong"; fi

echo
if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILURES ABOVE"; fi
exit "$fail"
