# src/a2a_llm_fallback.lex — A2A LLM fallback for open-ended dialogue (issue #22).
#
# Hybrid path: structured skill calls (#21) first; LLM only when the request
# can't be resolved to a declared, granted skill. The LLM PROPOSES; the Grant
# DISPOSES — an LLM-proposed action cannot exceed what the handshake granted.
#
# LLM integration point:
#   `mock_propose_plan` is a stub that returns a canned List[PlanStep].
#   Replace with a real lex-llm structured call (add lex-llm to lex.toml):
#     import "lex-llm/agent" as ag
#     import "lex-llm/structured" as st
#   The model must be constrained to the peer's granted skill vocabulary.
#   TODO: add lex-llm dependency once constrained/tool-style output is confirmed.
#
# Validation layer (the non-negotiable part):
#   Every step in the proposed plan is checked against the session Grant before
#   execution. Non-granted / malformed steps are dropped + audited, never silently
#   executed. This guarantee holds regardless of what the LLM returns.
#
# The [llm] effect (when integrated) must be confined to this module.
# The consent/trust path (a2a_consent.lex) stays rule-based always.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-trail/src/log" as tlog

import "./grant" as grant

import "./a2a_session" as sess

# ── Plan types ────────────────────────────────────────────────────────────────
type PlanStep = { call :: sess.SkillCall, src :: Str }

type PlanResult = { ok :: List[PlanStep], dropped :: List[(PlanStep, Str)] }

# ── LLM propose stub ─────────────────────────────────────────────────────────
fn mock_propose_plan(peer_msg :: Str, granted_skills :: List[Str]) -> List[PlanStep] {
  [{ call: { skill: "move_to", args_json: "{\"x\":0.5,\"y\":0.5,\"z\":0.2}" }, src: "llm: approach the target" }, { call: { skill: "grasp", args_json: "{\"force\":10.0}" }, src: "llm: pick up the object" }, { call: { skill: "self_destruct", args_json: "{}" }, src: "llm (injected): unauthorized action" }]
}

# ── Grant validation pass ─────────────────────────────────────────────────────
# Partition a proposed plan into allowed and dropped steps.
# Non-granted steps are dropped, NOT executed.
fn validate_plan(plan :: List[PlanStep], session :: sess.PeerSession) -> PlanResult
  examples {
    validate_plan([{ call: { skill: "move_to", args_json: "{}" }, src: "llm" }, { call: { skill: "self_destruct", args_json: "{}" }, src: "injected" }], { session_id: "s", peer_name: "P", peer_endpoint: "http://p:8900", peer_pubkey_b64: "k", grant: { skills: ["move_to"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 1.0, max_force: 10.0, max_grip_force: 15.0, budget_actions: 5, budget_wall_ms: 10000 }, actions_used: 0, expires_at_ms: 9999999 }) => { ok: [{ call: { skill: "move_to", args_json: "{}" }, src: "llm" }], dropped: [({ call: { skill: "self_destruct", args_json: "{}" }, src: "injected" }, "skill not in session grant: self_destruct")] },
    validate_plan([], { session_id: "s", peer_name: "P", peer_endpoint: "http://p:8900", peer_pubkey_b64: "k", grant: { skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 1.0, max_force: 10.0, max_grip_force: 15.0, budget_actions: 5, budget_wall_ms: 10000 }, actions_used: 0, expires_at_ms: 9999999 }) => { ok: [], dropped: [] }
  }
{
  list.fold(plan, { ok: [], dropped: [] }, fn (acc :: PlanResult, step :: PlanStep) -> PlanResult {
    if grant.skill_allowed(session.grant, step.call.skill) {
      { ok: list.concat(acc.ok, [step]), dropped: acc.dropped }
    } else {
      let reason := str.concat("skill not in session grant: ", step.call.skill)
      { ok: acc.ok, dropped: list.concat(acc.dropped, [(step, reason)]) }
    }
  })
}

# ── Resolve-or-propose ────────────────────────────────────────────────────────
# Fast path: if the request names a skill directly and it's granted → structured.
# Slow path: free-text → mock/LLM → validate.
fn first_matching_skill(msg :: Str, skills :: List[Str]) -> Option[Str] {
  list.fold(skills, None, fn (acc :: Option[Str], sk :: Str) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => if str.contains(msg, sk) {
        Some(sk)
      } else {
        None
      },
    }
  })
}

fn resolve_or_propose(peer_msg :: Str, session :: sess.PeerSession) -> List[PlanStep] {
  let granted := session.grant.skills
  match first_matching_skill(peer_msg, granted) {
    Some(sk) => [{ call: { skill: sk, args_json: "{}" }, src: "structured" }],
    None => mock_propose_plan(peer_msg, granted),
  }
}

# ── Trail helpers ─────────────────────────────────────────────────────────────
fn payload_str(s :: Str) -> Str {
  let clean := str.replace(str.replace(s, "\"", "'"), "\n", " ")
  str.join(["{\"detail\":\"", clean, "\"}"], "")
}

fn trail(log :: tlog.Log, parent :: Str, kind :: Str, detail :: Str) -> [sql, time] Str {
  match tlog.append(log, kind, Some(parent), payload_str(detail)) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
}

fn audit_dropped(log :: tlog.Log, parent :: Str, dropped :: List[(PlanStep, Str)]) -> [sql, time] Str {
  list.fold(dropped, parent, fn (par :: Str, item :: (PlanStep, Str)) -> [sql, time] Str {
    match item {
      (step, reason) => trail(log, par, "a2a_llm_dropped", str.join(["skill=", step.call.skill, " reason=", reason], "")),
    }
  })
}

# ── Execute plan (one step at a time) ─────────────────────────────────────────
fn execute_step(acc :: (List[sess.SkillResult], sess.PeerSession), step :: PlanStep, now_ms :: Int) -> [net] (List[sess.SkillResult], sess.PeerSession) {
  match acc {
    (results, s) => match sess.invoke_skill(s, step.call, now_ms) {
      (result, s2) => (list.concat(results, [result]), s2),
    },
  }
}

fn execute_plan(plan :: PlanResult, session :: sess.PeerSession, now_ms :: Int) -> [net] (List[sess.SkillResult], sess.PeerSession) {
  list.fold(plan.ok, ([], session), fn (acc :: (List[sess.SkillResult], sess.PeerSession), step :: PlanStep) -> [net] (List[sess.SkillResult], sess.PeerSession) {
    execute_step(acc, step, now_ms)
  })
}

# ── Audited execute ───────────────────────────────────────────────────────────
# Logs free-text request, plan summary, each dropped step, and execution count.
fn execute_plan_audited(peer_msg :: Str, session :: sess.PeerSession, now_ms :: Int, log :: tlog.Log, parent :: Str) -> [net, sql, time] (List[sess.SkillResult], sess.PeerSession, Str) {
  let p1 := trail(log, parent, "a2a_llm_request", str.concat("msg=", str.slice(peer_msg, 0, 80)))
  let plan := resolve_or_propose(peer_msg, session)
  let filtered := validate_plan(plan, session)
  let p2 := trail(log, p1, "a2a_llm_plan", str.join(["allowed=", int.to_str(list.len(filtered.ok)), " dropped=", int.to_str(list.len(filtered.dropped))], ""))
  let p3 := audit_dropped(log, p2, filtered.dropped)
  let pair := execute_plan(filtered, session, now_ms)
  match pair {
    (results, sess2) => {
      let pfinal := trail(log, p3, "a2a_llm_done", str.concat("executed=", int.to_str(list.len(results))))
      (results, sess2, pfinal)
    },
  }
}

