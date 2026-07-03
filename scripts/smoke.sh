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
mcpw="$(lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense \
          examples/mcp_server_demo.lex run 2>&1 | tr -d '\r')"
if grep -qF "effect \`actuate\` not in --allow-effects" <<<"$mcpw"; then
  pass "MCP server: actuate withheld → actuating tools unreachable (runtime wall holds over HTTP)"
else
  bad "MCP server: actuate withheld did NOT block the server"
  echo "$mcpw" | sed 's/^/      /'
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

echo
if [ "$fail" -eq 0 ]; then echo "ALL GREEN"; else echo "FAILURES ABOVE"; fi
exit "$fail"
