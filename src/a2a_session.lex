# src/a2a_session.lex — A2A post-handshake session: structured skill invocation (issue #21).
#
# After the handshake (#16-20) ends with a verified peer and an escalated Grant,
# this module covers the actual conversation: calling the peer's declared skills
# as typed A2A Tasks over std.http.
#
# Design:
#   - PeerSession bundles peer identity + session_id + escalated Grant + budget.
#   - Every outbound skill call is grant-checked before the HTTP request is made.
#   - Every inbound skill call from the peer is re-checked on arrival.
#   - Session expires when budget runs out or wall-clock elapses.
#
# Wire format (A2A Task over JSON-RPC 2.0):
#   POST {peer.endpoint}/a2a/task
#   Body: {"jsonrpc":"2.0","method":"tasks/send","id":"...","params":{
#            "task":{"kind":"task","id":"...","skill":"...","args":{...}}}}
#   Reply: {"jsonrpc":"2.0","id":"...","result":{"kind":"artifact","output":{...}}}
#
# Effects:
#   Pure functions (grant check, encode/decode) — no effects
#   invoke_skill       — [net]
#   All trail-audited  — [net, sql, time]

import "std.str" as str

import "std.bytes" as bytes

import "std.list" as list

import "std.int" as int

import "std.http" as http

import "std.map" as map

import "lex-trail/src/log" as tlog

import "./types" as t

import "./grant" as grant

import "./a2a_card" as card

import "./a2a_handshake" as hs

# ── Session types ──────────────────────────────────────────────────────────────
type PeerSession = { session_id :: Str, peer_name :: Str, peer_endpoint :: Str, peer_pubkey_b64 :: Str, grant :: t.Grant, actions_used :: Int, expires_at_ms :: Int }

# A typed skill invocation request.
type SkillCall = { skill :: Str, args_json :: Str }

# Result of a skill invocation.
type SkillResult = SkillOk(Str) | SkillDenied(Str) | SkillFailed(Str)

fn open_session(outcome :: hs.HandshakeOutcome, session_id :: Str, expires_at_ms :: Int) -> Option[PeerSession] {
  match outcome {
    PublicOnly(pub_card) => Some({ session_id: session_id, peer_name: pub_card.name, peer_endpoint: pub_card.endpoint, peer_pubkey_b64: pub_card.pubkey_b64, grant: { skills: list.map(pub_card.skills, fn (s :: card.AgentSkill) -> Str {
      s.name
    }), ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 1.0, max_force: 15.0, max_grip_force: 20.0, budget_actions: 20, budget_wall_ms: 60000 }, actions_used: 0, expires_at_ms: expires_at_ms }),
    Escalated(pub_card, ext_card) => Some({ session_id: session_id, peer_name: ext_card.name, peer_endpoint: ext_card.endpoint, peer_pubkey_b64: ext_card.pubkey_b64, grant: { skills: list.map(ext_card.skills, fn (s :: card.AgentSkill) -> Str {
      s.name
    }), ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 1.0, max_force: 15.0, max_grip_force: 20.0, budget_actions: 50, budget_wall_ms: 300000 }, actions_used: 0, expires_at_ms: expires_at_ms }),
    Rejected(_) => None,
    Failed(_) => None,
  }
}

# ── Encode / decode ─────────────────────────────────────────────────────────────
# Build a JSON-RPC 2.0 tasks/send request body.
fn encode_call(session_id :: Str, call :: SkillCall) -> Str {
  str.join(["{\"jsonrpc\":\"2.0\",\"method\":\"tasks/send\",\"id\":\"", session_id, "\",\"params\":{\"task\":{\"kind\":\"task\",\"id\":\"", session_id, "\",\"skill\":\"", call.skill, "\",\"args\":", call.args_json, "}}}"], "")
}

# Extract the "output" field from a JSON-RPC result body (flat pattern).
fn decode_result(body :: Str) -> Result[Str, Str] {
  if str.contains(body, "\"error\"") {
    let msg_start := str.split(body, "\"message\":\"")
    let msg := match list.head(list.tail(msg_start)) {
      Some(s) => match list.head(str.split(s, "\"")) {
        Some(m) => m,
        None => "error",
      },
      None => "jsonrpc error",
    }
    Err(msg)
  } else {
    let out_start := str.split(body, "\"output\":")
    match list.head(list.tail(out_start)) {
      None => Err("missing output field"),
      Some(s) => {
        let trimmed := str.trim(s)
        let tok := match list.head(str.split(trimmed, "}}")) {
          Some(t) => t,
          None => trimmed,
        }
        Ok(str.concat(tok, "}"))
      },
    }
  }
}

# ── Pure examples for encode/decode ───────────────────────────────────────────
fn encode_call_example() -> Bool
  examples {
    encode_call_example() => true
  }
{
  let call := { skill: "move_to", args_json: "{\"x\":0.5}" }
  let body := encode_call("sess-1", call)
  str.contains(body, "\"method\":\"tasks/send\"") and str.contains(body, "\"skill\":\"move_to\"")
}

# ── Grant checks ───────────────────────────────────────────────────────────────
fn skill_allowed_in_session(sess :: PeerSession, skill :: Str) -> Bool {
  grant.skill_allowed(sess.grant, skill)
}

fn budget_ok(sess :: PeerSession) -> Bool {
  sess.actions_used < sess.grant.budget_actions
}

fn session_not_expired(sess :: PeerSession, now_ms :: Int) -> Bool {
  now_ms < sess.expires_at_ms
}

fn consume_action(sess :: PeerSession) -> PeerSession {
  { session_id: sess.session_id, peer_name: sess.peer_name, peer_endpoint: sess.peer_endpoint, peer_pubkey_b64: sess.peer_pubkey_b64, grant: sess.grant, actions_used: sess.actions_used + 1, expires_at_ms: sess.expires_at_ms }
}

# ── HTTP helpers ───────────────────────────────────────────────────────────────
fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("net: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn post_task(url :: Str, body :: Str, token :: Str) -> [net] Result[Str, Str] {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: None }
  let req := http.with_header(http.with_header(http.with_timeout_ms(req0, 10000), "Content-Type", "application/json"), "Authorization", str.concat("Bearer ", token))
  match http.send(req) {
    Err(e) => Err(http_err_str(e)),
    Ok(resp) => match http.text_body(resp) {
      Err(e) => Err(http_err_str(e)),
      Ok(body) => Ok(body),
    },
  }
}

# ── Skill invocation ───────────────────────────────────────────────────────────
# Check grant, send A2A task, return typed result. Session is updated (budget).
fn invoke_skill(sess :: PeerSession, call :: SkillCall, now_ms :: Int) -> [net] (SkillResult, PeerSession) {
  if not session_not_expired(sess, now_ms) {
    (SkillDenied("session expired"), sess)
  } else {
    if not budget_ok(sess) {
      (SkillDenied("session budget exhausted"), sess)
    } else {
      if not skill_allowed_in_session(sess, call.skill) {
        (SkillDenied(str.concat("skill not in session grant: ", call.skill)), sess)
      } else {
        let task_url := str.join([sess.peer_endpoint, "/a2a/task"], "")
        let body := encode_call(sess.session_id, call)
        let sess2 := consume_action(sess)
        match post_task(task_url, body, sess.session_id) {
          Err(e) => (SkillFailed(e), sess2),
          Ok(resp) => match decode_result(resp) {
            Err(e) => (SkillFailed(e), sess2),
            Ok(out) => (SkillOk(out), sess2),
          },
        }
      }
    }
  }
}

# ── Inbound request gate ───────────────────────────────────────────────────────
# Check whether an inbound skill request from the peer is allowed by our grant.
# Returns Err(reason) if denied — the caller should respond with a refusal.
fn check_inbound(sess :: PeerSession, skill :: Str) -> Result[Str, Str]
  examples {
    check_inbound({ session_id: "s", peer_name: "P", peer_endpoint: "http://p:8900", peer_pubkey_b64: "k", grant: { skills: ["move_to"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 1.0, max_force: 10.0, max_grip_force: 15.0, budget_actions: 5, budget_wall_ms: 10000 }, actions_used: 0, expires_at_ms: 9999999 }, "move_to") => Ok("allowed"),
    check_inbound({ session_id: "s", peer_name: "P", peer_endpoint: "http://p:8900", peer_pubkey_b64: "k", grant: { skills: ["move_to"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 1.0, max_force: 10.0, max_grip_force: 15.0, budget_actions: 5, budget_wall_ms: 10000 }, actions_used: 0, expires_at_ms: 9999999 }, "self_destruct") => Err("skill not in session grant: self_destruct")
  }
{
  if not skill_allowed_in_session(sess, skill) {
    Err(str.concat("skill not in session grant: ", skill))
  } else {
    Ok("allowed")
  }
}

