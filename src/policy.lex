# lex-robot/policy.lex — run_policy and its async polling.
#
# A real closed-loop rollout runs tens of seconds — past std.http's hard ~10s
# client timeout (which with_timeout_ms does not raise; see client.lex). So
# run_policy hands the rollout to the sidecar asynchronously: the sidecar starts
# it and answers immediately with a `status`, and we poll `policy_status` (each
# call sub-10s) until the job finishes. This lives outside skills.lex so the
# [time] effect the poll loop needs does NOT attach to the core skill surface —
# a plain move/grasp program stays time-free.

import "std.str" as str

import "std.int" as int

import "std.time" as time

import "./types" as t

import "./grant" as grant

import "./client" as client

import "./skills" as skills

# Poll an async rollout to completion. Each call reads only job status (sub-10s),
# so the loop never trips the ~10s http ceiling that a single blocking rollout
# would. `fuel` bounds the total wait (≈fuel × 0.5s); on overrun we report Timeout.
fn poll_policy(r :: t.Robot, fuel :: Int) -> [net, time] t.Outcome {
  if fuel <= 0 {
    Timeout
  } else {
    let __s := time.sleep_ms(500)
    match client.call(r.sidecar_url, "policy_status", "{}") {
      Err(e) => Stalled(e),
      Ok(s) => if str.contains(s, "\"running\"") {
        poll_policy(r, fuel - 1)
      } else {
        skills.parse_outcome(s)
      },
    }
  }
}

# Hands the high-rate loop to LeRobot; the lex-os supervisor enforces the budget.
# The sidecar runs the rollout in the background and answers immediately with a
# `status` field; we poll to completion. A synchronous sidecar (the stub) instead
# returns an `outcome` inline, which we parse directly — so both backends work
# unchanged from the caller's view.
fn run_policy(r :: t.Robot, name :: Str, goal :: Str, budget_ms :: Int) -> [net, sense, actuate, time] t.Outcome {
  if grant.skill_allowed(r.grant, "run_policy") {
    let body := str.join([
      "{\"name\":\"", name, "\",\"goal\":\"", goal, "\",\"budget_ms\":", int.to_str(budget_ms), "}"
    ], "")
    match client.call(r.sidecar_url, "run_policy", body) {
      Err(e) => Stalled(e),
      Ok(resp) => if str.contains(resp, "\"status\"") {
        poll_policy(r, 360)
      } else {
        skills.parse_outcome(resp)
      },
    }
  } else {
    Denied("skill run_policy not in grant")
  }
}
