# lex-robot/tests/test_llm_planner.lex — proves llm_planner.lex's
# tool-dispatch path is real: a SCRIPTED mock Provider (no network, no LLM)
# drives lex-llm's run_loop, and every tool call it proposes goes over a
# REAL HTTP round-trip into a REAL, live a2a_robot_server + sidecar
# process — the actual grant gate decides allow/deny, not a stand-in.
#
# This is the verification a live OpenCode call can't give in an
# environment with no API key or network access to opencode.ai: it proves
# 100% of llm_planner.lex's OWN code (the A2A tool wrapper, the wire
# parsing, the run_loop wiring) end to end. What it can NOT prove — and
# what stays honestly unverified without a real key — is whether a real
# hosted model reliably picks the right tool for an English sentence.
# That's a live, out-of-band check (see the README), same category as
# this repo's other ML-dependent demos.
#
# A Provider is just `{ name :: Str, chat :: (...) -> [net, llm] Iter[Delta] }`
# (provider.lex) — substituting a scripted one for the real OpenCode
# adapter is a genuine substitution of the SAME interface, not a special
# test-only code path.
#
# Needs a REAL a2a_robot_server + sidecar already running (this file is a
# CLIENT, exactly like llm_planner.lex itself) — see
# `make xlerobot-llm-mock`, which starts both (examples/a2a_robot_demo.lex's
# grant: move_arm/grasp_arm/move_base/read_base granted, "speak" NOT
# granted — deliberately, so this test exercises both the allow and deny
# paths through the real grant), waits for health, runs this, tears down.
#
# Run:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
#       tests/test_llm_planner.lex main

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.iter" as iter

import "lex-llm/src/message" as msg

import "lex-llm/src/delta" as d

import "lex-llm/src/provider" as prov

import "lex-llm/src/tool" as t

import "../src/llm_planner" as planner

# ── Scripted mock provider ────────────────────────────────────────────────
#
# Decides what to do purely from how many ToolMsg replies are already in
# the conversation — run_loop passes the FULL accumulated conversation on
# every turn, so this needs no mutable state, matching Lex's functional
# style:
#
#   turn 0 (no tool results yet):  propose move_base(x=0.3, y=0.2) — inside
#                                   examples/a2a_robot_demo.lex's granted
#                                   floor area (that demo shares one narrow
#                                   arm-reach-shaped box across move_arm AND
#                                   move_base), so the real server should
#                                   say "reached".
#   turn 1 (1 tool result seen):   propose speak(text="done") — NOT
#                                   granted, so the real server should
#                                   say "denied: skill speak not in grant".
#   turn 2 (2 tool results seen):  stop, echoing both real results
#                                   verbatim into the final reply so the
#                                   test can assert on what the REAL
#                                   server actually said.
fn tool_msg_contents(messages :: List[msg.Message]) -> List[Str] {
  list.fold(messages, [], fn (acc :: List[Str], m :: msg.Message) -> List[Str] {
    match m {
      ToolMsg(_, content) => list.concat(acc, [content]),
      _ => acc,
    }
  })
}

fn mock_provider() -> prov.Provider {
  { name: "mock", chat: fn (model :: prov.ModelRef, messages :: List[msg.Message], tools :: List[t.Tool]) -> [net, llm] Iter[d.Delta] {
    let seen := tool_msg_contents(messages)
    let n := list.len(seen)
    let deltas := if n == 0 {
      [ToolCallBegin("call_1", "move_base"), ToolArgChunk("call_1", "{\"x\":0.3,\"y\":0.2}"), FinishDelta("tool_calls")]
    } else {
      if n == 1 {
        [ToolCallBegin("call_2", "speak"), ToolArgChunk("call_2", "{\"text\":\"done\"}"), FinishDelta("tool_calls")]
      } else {
        [TextChunk(str.concat("saw: ", str.join(seen, " || "))), FinishDelta("stop")]
      }
    }
    iter.from_list(deltas)
  } }
}

# ── Assertions ─────────────────────────────────────────────────────────────
fn assert_contains(label :: Str, haystack :: Str, needle :: Str) -> Result[Unit, Str] {
  if str.contains(haystack, needle) {
    Ok(())
  } else {
    Err(str.join([label, ": expected to find `", needle, "` in `", haystack, "`"], ""))
  }
}

# The real assertion: the final reply (built entirely from the mock's own
# scripted TextChunk, which just echoes tool_msg_contents back) contains
# BOTH a real "reached" from the granted move_base call AND a real
# "denied: skill speak not in grant" from the ungranted speak call — proof
# that a2a_robot_server.lex's actual grant, not a stand-in, decided both.
fn test_tool_calls_reach_real_grant_gated_server() -> [net, crypto, llm, io, proc, approval] Result[Unit, Str] {
  let steps := planner.plan("http://localhost:8766", "mocktest-1", mock_provider(), prov.make_model_ref("mock", "mock-1"), "drive to (1,1.5) then say done")
  let final := planner.final_text(steps)
  match assert_contains("move_base result", final, "reached") {
    Err(e) => Err(e),
    Ok(_) => assert_contains("speak result", final, "denied: skill speak not in grant"),
  }
}

fn main() -> [net, crypto, llm, io, proc, approval] Nil {
  match test_tool_calls_reach_real_grant_gated_server() {
    Ok(_) => io.print("ALL PASS: llm_planner tool-dispatch reaches the real grant-gated server"),
    Err(reason) => io.print(str.concat("FAIL: ", reason)),
  }
}

