# lex-robot/tests/test_a2a_robot_grant.lex — CI smoke tests for
# a2a_robot_server.lex
#
# Mirrors tests/test_mcp_grant.lex's four grant/budget assertions, but drives
# them through the actual A2A JSON-RPC wire shape (`dispatch_request` with a
# `tasks/send` body) instead of calling `dispatch_skill` directly — proving
# the grant holds through the standard-protocol layer, not just the internal
# dispatcher. Adds several more: the XLeRobot's per-arm dispatch (move_arm/
# grasp_arm), that the response is a real, spec-shaped A2A Task, and — since
# a2a_robot_auth.lex — that NOTHING reaches dispatch_skill without a session
# opened via `session/open` first, sensing skills included.
#
# Every test opens a REAL session first (a real Ed25519 keypair, a real
# signed card, a real session/open round trip through dispatch_request) —
# not a hand-built contextId — so this exercises the exact path an actual
# caller goes through, the same reasoning llm_planner.lex's own
# open_client_session follows.
#
# Run (standalone; llm,proc required too — see a2a_robot_server.lex; stream
# is required because lex-agent/src/client's OTHER functions (subscribe/
# decode_stream, unused here) declare it, and the toolchain validates the
# whole imported module graph, not just the call path exercised):
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate,stream \
#       tests/test_a2a_robot_grant.lex main

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.sql" as sql

import "std.time" as time

import "lex-schema/json_value" as jv

import "lex-agent/src/protocol" as rpc

import "lex-agent/src/client" as a2a_client

import "lex-trail/log" as trail

import "../src/types" as t

import "../src/mcp_server" as mcp

import "../src/a2a_robot_server" as a2a

import "../src/a2a_card" as card

import "../src/a2a_consent" as consent

# ── Fixtures ──────────────────────────────────────────────────────────────────
fn make_grant(skill_names :: List[Str], budget_actions :: Int) -> t.Grant {
  { skills: skill_names, ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.5, max_force: 50.0, max_grip_force: 40.0, budget_actions: budget_actions, budget_wall_ms: 60000 }
}

fn make_robot(skill_names :: List[Str], budget_actions :: Int) -> t.Robot {
  { sidecar_url: "http://localhost:19999", grant: make_grant(skill_names, budget_actions) }
}

# Open policy — these tests exercise grant/budget mechanics, not consent
# policy edge cases (see test_a2a_robot_auth.lex for those); any signed
# card is accepted here, matching examples/a2a_robot_demo.lex's own choice.
fn open_policy() -> consent.ConsentPolicy {
  { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 1000, max_budget_ms: 600000 }
}

# A `tasks/send` body naming `skill_name` with a DataPart carrying `data_json`
# as its structured arguments, using a REAL session's contextId.
fn tasks_send_body(ctx_id :: Str, skill_name :: Str, data_json :: Str) -> Str {
  str.join(["{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{", "\"id\":\"t_1\",\"contextId\":\"", ctx_id, "\",\"skill\":\"", skill_name, "\",", "\"message\":{\"kind\":\"message\",\"messageId\":\"m1\",\"role\":\"user\",", "\"parts\":[{\"type\":\"data\",\"data\":", data_json, "}]}}}"], "")
}

fn extract_field(resp :: Str, outer :: Str, field :: Str) -> Str {
  match jv.parse(resp) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, outer) {
      None => "",
      Some(o) => match jv.get_field(o, field) {
        Some(JStr(s)) => s,
        _ => "",
      },
    },
  }
}

# Real session/open round trip: a real keypair (deterministic from `seed`,
# same reasoning identity.lex documents), a real signed card requesting
# `requested_skills`, a real dispatch_request call. Returns "" on any
# failure (bad signature, refused card, no shared skills) — a test using
# that as a contextId then correctly sees "no active session" downstream,
# same graceful-degradation shape llm_planner.lex's client-side helper has.
fn open_test_session(robot :: t.Robot, db :: Db, log :: trail.Log, policy :: consent.ConsentPolicy, seed :: Str, requested_skills :: List[Str]) -> [sql, crypto, time, net, sense, actuate] Str {
  let secret := crypto.sha256(bytes.from_str(seed))
  match crypto.ed25519_public_key(secret) {
    Err(_) => "",
    Ok(pk) => {
      let cj := card.card_to_json({ name: "test-agent", endpoint: "https://test-agent.internal", pubkey_b64: crypto.base64url_encode(pk), tier: card.Extended, supports_extended: false, skills: list.map(requested_skills, fn (n :: Str) -> card.AgentSkill {
        { name: n, description: "" }
      }) })
      match card.sign_card(cj, secret) {
        Err(_) => "",
        Ok(sig) => {
          let params := JObj([("card_json", JStr(cj)), ("sig_b64", JStr(sig))])
          let body := a2a_client.build_envelope("session/open", params, IdStr("t_session"))
          extract_field(a2a.dispatch_request(robot, db, log, policy, body), "result", "contextId")
        },
      }
    },
  }
}

fn open_memory_fixture() -> [sql, fs_write] Result[(Db, trail.Log), Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => Ok((db, log)),
    },
  }
}

# ── Tests ─────────────────────────────────────────────────────────────────────
# 0. The core new behavior: a tasks/send whose contextId was NEVER produced
#    by session/open is refused before dispatch_skill ever runs — for ANY
#    skill, including ones the ceiling grant would otherwise allow.
fn test_unauthenticated_tasks_send_refused() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_to"], 10)
      let body := tasks_send_body("ctx_never_opened_via_session_open", "move_to", "{\"x\":0.5,\"y\":0.5,\"z\":0.2}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "\"error\"") and str.contains(resp, "no active session") {
        Ok(())
      } else {
        Err(str.concat("expected a spec-denied 'no active session' error, got: ", resp))
      }
    },
  }
}

# 0b. session/open itself refuses a tampered signature — no session is
#     created, so a follow-up tasks/send (even with the contextId a valid
#     open would have produced for this identity) still finds nothing.
fn test_session_open_refuses_bad_signature() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_to"], 10)
      let cj := card.card_to_json({ name: "bad", endpoint: "https://bad.internal", pubkey_b64: "AAAA", tier: card.Extended, supports_extended: false, skills: [] })
      let params := JObj([("card_json", JStr(cj)), ("sig_b64", JStr("not-a-real-signature"))])
      let body := a2a_client.build_envelope("session/open", params, IdStr("t_bad"))
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "\"error\"") {
        Ok(())
      } else {
        Err(str.concat("expected session/open to refuse a bad signature, got: ", resp))
      }
    },
  }
}

# 1. Deny: skill not in grant → the Task comes back `failed` with a
#    "denied:" outcome in the reply DataPart.
fn test_deny_skill_not_in_grant() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["grasp"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-deny", ["grasp", "move_to"])
      let body := tasks_send_body(ctx_id, "move_to", "{\"x\":0.5,\"y\":0.5,\"z\":0.2}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "\"state\":\"failed\"") and str.contains(resp, "denied:") {
        Ok(())
      } else {
        Err(str.concat("expected a failed task carrying denied:, got: ", resp))
      }
    },
  }
}

# 2. Allow: skill present, target in workspace → reaches the sidecar
#    (stalled, since :19999 isn't listening) and the Task is `completed` —
#    stalled/timeout still count as the goal action having left the box,
#    same distinction dispatch_skill's outcome text already draws.
fn test_allow_reaches_sidecar() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_to"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-allow", ["move_to"])
      let body := tasks_send_body(ctx_id, "move_to", "{\"x\":0.5,\"y\":0.5,\"z\":0.2}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied:") {
        Err(str.concat("skill was denied but should have reached the sidecar: ", resp))
      } else {
        if str.contains(resp, "\"kind\":\"task\"") and str.contains(resp, "\"id\":\"t_1\"") {
          Ok(())
        } else {
          Err(str.concat("response is not a well-formed A2A task: ", resp))
        }
      }
    },
  }
}

# 3. Clamp: grasp force above max_grip_force is clamped, not denied.
fn test_grasp_force_clamped_not_denied() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["grasp"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-clamp", ["grasp"])
      let body := tasks_send_body(ctx_id, "grasp", "{\"force\":999.9}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied: skill grasp") {
        Err(str.concat("grasp was denied (should be clamped): ", resp))
      } else {
        Ok(())
      }
    },
  }
}

# 4. Budget: budget_actions=1; second actuating call returns a "killed:"
#    outcome inside a `failed` task. Same session both times — the whole
#    point of a per-session ledger is that it's shared across calls FROM
#    THAT SESSION, not reset each time. Uses move_arm (not move_to) —
#    move_arm/grasp_arm/speak/move_base are the four skills that actually
#    go through the new per-session ledger; move_to/grasp/connect_charger
#    fall through to mcp.dispatch_skill's own separate global ledger (see
#    a2a_robot_auth.lex's module comment) and aren't what this is testing.
fn test_budget_exhausted_returns_killed() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_arm"], 1)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-budget", ["move_arm"])
      let body := tasks_send_body(ctx_id, "move_arm", "{\"arm\":\"left\",\"x\":0.3,\"y\":0.2,\"z\":0.2}")
      let _first := a2a.dispatch_request(robot, db, log, open_policy(), body)
      let second := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(second, "\"state\":\"failed\"") and str.contains(second, "killed:") {
        Ok(())
      } else {
        Err(str.concat("expected a failed task carrying killed:, got: ", second))
      }
    },
  }
}

# 4b. Budget isolation: a SECOND session (different identity) against the
#     same server is unaffected by the first session's exhausted budget —
#     the whole reason a2a_robot_auth.lex keys the ledger by context_id
#     instead of reusing mcp_server.lex's single global row.
fn test_budget_is_isolated_per_session() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_arm"], 1)
      let policy := open_policy()
      let ctx_a := open_test_session(robot, db, log, policy, "seed-isolation-a", ["move_arm"])
      let ctx_b := open_test_session(robot, db, log, policy, "seed-isolation-b", ["move_arm"])
      let body_a := tasks_send_body(ctx_a, "move_arm", "{\"arm\":\"left\",\"x\":0.3,\"y\":0.2,\"z\":0.2}")
      let body_b := tasks_send_body(ctx_b, "move_arm", "{\"arm\":\"left\",\"x\":0.3,\"y\":0.2,\"z\":0.2}")
      let _exhaust_a := a2a.dispatch_request(robot, db, log, policy, body_a)
      let a_second := a2a.dispatch_request(robot, db, log, policy, body_a)
      let b_first := a2a.dispatch_request(robot, db, log, policy, body_b)
      if str.contains(a_second, "killed:") and not str.contains(b_first, "killed:") {
        Ok(())
      } else {
        Err(str.join(["expected session A killed but session B unaffected -- a_second: ", a_second, " | b_first: ", b_first], ""))
      }
    },
  }
}

# 5. XLeRobot per-arm dispatch: move_arm resolves through the same grant —
#    denied when move_arm isn't granted, reaches the sidecar when it is.
fn test_move_arm_denied_when_not_granted() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["grasp_arm"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-move-arm-denied", ["grasp_arm", "move_arm"])
      let body := tasks_send_body(ctx_id, "move_arm", "{\"arm\":\"left\",\"x\":0.3,\"y\":0.2,\"z\":0.2}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied: skill move_arm") {
        Ok(())
      } else {
        Err(str.concat("expected move_arm denied, got: ", resp))
      }
    },
  }
}

fn test_move_arm_reaches_sidecar_when_granted() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_arm"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-move-arm-granted", ["move_arm"])
      let body := tasks_send_body(ctx_id, "move_arm", "{\"arm\":\"left\",\"x\":0.3,\"y\":0.2,\"z\":0.2}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied:") {
        Err(str.concat("move_arm was denied but should have reached the sidecar: ", resp))
      } else {
        Ok(())
      }
    },
  }
}

# 6. speak: grant-gated like every other actuating skill — denied when not
#    granted, reaches the sidecar (and is budget-charged) when it is.
fn test_speak_denied_when_not_granted() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_arm"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-speak-denied", ["move_arm", "speak"])
      let body := tasks_send_body(ctx_id, "speak", "{\"text\":\"hello\"}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied: skill speak") {
        Ok(())
      } else {
        Err(str.concat("expected speak denied, got: ", resp))
      }
    },
  }
}

fn test_speak_reaches_sidecar_when_granted() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["speak"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-speak-granted", ["speak"])
      let body := tasks_send_body(ctx_id, "speak", "{\"text\":\"hello, i have the cup\"}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied:") {
        Err(str.concat("speak was denied but should have reached the sidecar: ", resp))
      } else {
        Ok(())
      }
    },
  }
}

# 7. locate_object/transform_to_arm are sensing-only and carry NO grant
#    check inside sense.lex itself (a deliberate choice for trusted local/
#    MCP callers — see dispatch_read_base's comment) — but an A2A session
#    now gates them exactly like every other skill at the top level, which
#    is the whole point of this feature: a caller whose session doesn't
#    include them is denied, closing what would otherwise be a free,
#    unlimited information-disclosure surface over a public port.
fn test_locate_object_denied_when_not_in_session() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_arm"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-locate-denied", ["move_arm"])
      let body := tasks_send_body(ctx_id, "locate_object", "{\"name\":\"cup\"}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied: skill locate_object") {
        Ok(())
      } else {
        Err(str.concat("expected locate_object denied (not in session grant), got: ", resp))
      }
    },
  }
}

fn test_transform_to_arm_reaches_sidecar_when_in_session() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["transform_to_arm"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-transform-granted", ["transform_to_arm"])
      let body := tasks_send_body(ctx_id, "transform_to_arm", "{\"x\":0.3,\"y\":0.1,\"z\":0.2}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied:") {
        Err(str.concat("transform_to_arm was denied but should have reached the sidecar: ", resp))
      } else {
        if str.contains(resp, "\"state\":\"failed\"") {
          Ok(())
        } else {
          Err(str.concat("expected a failed task (no sidecar listening), got: ", resp))
        }
      }
    },
  }
}

# 8. A skill name genuinely unknown to the sidecar still refuses cleanly
#    (mcp.dispatch_skill's "error: unknown tool:") when it's ALSO in the
#    session's grant — e.g. a stale AgentCard/ceiling listing a skill name
#    the sidecar never implemented. Both the ceiling and the session must
#    include it, or the NEW top-level session gate denies it first (a
#    different, but equally clean, refusal — see test_unknown_skill_
#    not_in_session_denied_before_reaching_sidecar below) without ever
#    asking whether the sidecar would even recognise the name.
fn test_unknown_skill_reaches_fallback_when_in_session() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["teleport"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-unknown-in-session", ["teleport"])
      let body := tasks_send_body(ctx_id, "teleport", "{}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "\"state\":\"failed\"") and str.contains(resp, "error: unknown tool") {
        Ok(())
      } else {
        Err(str.concat("expected failed task carrying an unknown-tool error, got: ", resp))
      }
    },
  }
}

# 8b. The far more common case: a skill name that's neither granted nor
#     requested is denied by the session gate itself, before dispatch_skill
#     (and therefore the sidecar) is ever consulted.
fn test_unknown_skill_not_in_session_denied_before_reaching_sidecar() -> [sql, fs_write, crypto, time, net, sense, actuate] Result[Unit, Str] {
  match open_memory_fixture() {
    Err(e) => Err(e),
    Ok((db, log)) => {
      let robot := make_robot(["move_to"], 10)
      let ctx_id := open_test_session(robot, db, log, open_policy(), "seed-unknown-outside-session", ["move_to"])
      let body := tasks_send_body(ctx_id, "teleport", "{}")
      let resp := a2a.dispatch_request(robot, db, log, open_policy(), body)
      if str.contains(resp, "denied: skill teleport not in grant") {
        Ok(())
      } else {
        Err(str.concat("expected teleport denied by the session gate, got: ", resp))
      }
    },
  }
}

# ── Runner (CI: panics on any failure) ───────────────────────────────────────
fn main() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, sense, actuate] Nil {
  let results := [test_unauthenticated_tasks_send_refused(), test_session_open_refuses_bad_signature(), test_deny_skill_not_in_grant(), test_allow_reaches_sidecar(), test_grasp_force_clamped_not_denied(), test_budget_exhausted_returns_killed(), test_budget_is_isolated_per_session(), test_move_arm_denied_when_not_granted(), test_move_arm_reaches_sidecar_when_granted(), test_speak_denied_when_not_granted(), test_speak_reaches_sidecar_when_granted(), test_locate_object_denied_when_not_in_session(), test_transform_to_arm_reaches_sidecar_when_in_session(), test_unknown_skill_reaches_fallback_when_in_session(), test_unknown_skill_not_in_session_denied_before_reaching_sidecar()]
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __lex_discard_1 := 1 / 0
    ()
  }
}

