# lex-robot/tests/test_mcp_grant.lex — CI smoke tests for mcp_server.lex
#
# Covers the four grant/budget assertions from issue #29, without a live sidecar:
#
#   1. Deny        — skill absent from grant → "denied:…"
#   2. No-deny     — skill present, target in workspace → reaches sidecar
#                    (returns "stalled:…" because localhost:19999 is not running,
#                     but never "denied:")
#   3. Force-clamp — excess force on grasp is silently clamped, not denied
#   4. Budget kill — budget_actions=1; second actuating call returns "killed:…"
#
# Run (standalone):
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#       tests/test_mcp_grant.lex main

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.time" as time

import "lex-schema/json_value" as jv

import "lex-agent/src/message" as msg

import "lex-agent/src/server" as srv

import "lex-trail/log" as trail

import "../src/types" as t

import "../src/mcp_server" as mcp

# ── Fixtures ──────────────────────────────────────────────────────────────────

fn make_grant(skill_names :: List[Str], budget_actions :: Int) -> t.Grant {
  {
    skills: skill_names,
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 0.5,
    max_force: 50.0,
    max_grip_force: 40.0,
    budget_actions: budget_actions,
    budget_wall_ms: 60000,
  }
}

fn make_robot(skill_names :: List[Str], budget_actions :: Int) -> t.Robot {
  { sidecar_url: "http://localhost:19999", grant: make_grant(skill_names, budget_actions) }
}

fn data_msg(args :: jv.Json) -> msg.Message {
  { message_id: "t", role: RoleUser, parts: [DataPart(args)] }
}

fn move_to_args(x :: Float, y :: Float, z :: Float) -> jv.Json {
  JObj([("x", JFloat(x)), ("y", JFloat(y)), ("z", JFloat(z))])
}

fn reply_text(o :: srv.HandlerOutcome) -> Str {
  match o.reply {
    None => "",
    Some(m) => list.fold(m.parts, "", fn (acc :: Str, p :: msg.Part) -> Str {
      if str.is_empty(acc) { match p { TextPart(s) => s, _ => acc } } else { acc }
    }),
  }
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Deny: skill not in grant → handler returns "denied:…" immediately.
fn test_deny_skill_not_in_grant() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, actuate, sense] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["grasp"], 10)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let skill := mcp.make_move_to_skill(robot, db, log)
        let o := skill.handle(data_msg(move_to_args(0.5, 0.5, 0.2)))
        if str.starts_with(reply_text(o), "denied:") {
          Ok(())
        } else {
          Err(str.concat("expected denied, got: ", reply_text(o)))
        }
      },
    },
  }
}

# 2. Allow: skill present, target in workspace → hits sidecar (stalled ≠ denied).
fn test_allow_reaches_sidecar() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, actuate, sense] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_to"], 10)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let skill := mcp.make_move_to_skill(robot, db, log)
        let o := skill.handle(data_msg(move_to_args(0.5, 0.5, 0.2)))
        if str.starts_with(reply_text(o), "denied:") {
          Err(str.concat("skill was denied but should have reached sidecar: ", reply_text(o)))
        } else {
          Ok(())
        }
      },
    },
  }
}

# 3. Clamp: grasp force above max_grip_force is clamped, not denied.
fn test_grasp_force_clamped_not_denied() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, actuate, sense] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["grasp"], 10)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let skill := mcp.make_grasp_skill(robot, db, log)
        let o := skill.handle(data_msg(JObj([("force", JFloat(999.9))])))
        if str.starts_with(reply_text(o), "denied: skill grasp") {
          Err(str.concat("grasp was denied (should be clamped): ", reply_text(o)))
        } else {
          Ok(())
        }
      },
    },
  }
}

# 4. Budget: budget_actions=1; second actuating call returns "killed:…".
fn test_budget_exhausted_returns_killed() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, actuate, sense] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_to"], 1)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let skill := mcp.make_move_to_skill(robot, db, log)
        let m := data_msg(move_to_args(0.5, 0.5, 0.2))
        let _first := skill.handle(m)
        let second := skill.handle(m)
        if str.starts_with(reply_text(second), "killed:") {
          Ok(())
        } else {
          Err(str.concat("expected killed, got: ", reply_text(second)))
        }
      },
    },
  }
}

# ── Runner (CI: panics on any failure) ───────────────────────────────────────

fn main() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, actuate, sense] Nil {
  let results := [
    test_deny_skill_not_in_grant(),
    test_allow_reaches_sidecar(),
    test_grasp_force_clamped_not_denied(),
    test_budget_exhausted_returns_killed()
  ]
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  })
  if failures == 0 {
    ()
  } else {
    let _ := 1 / 0
    ()
  }
}
