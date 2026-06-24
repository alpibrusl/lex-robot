# lex-robot/tests/test_mcp_grant.lex — CI smoke tests for mcp_server.lex
#
# Drives `mcp.dispatch_skill` directly (the single tool router that crosses into
# sense/actuate) so the four grant/budget assertions from issue #29 run without a
# live sidecar:
#
#   1. Deny        — skill absent from grant → "denied:…"
#   2. No-deny     — skill present, target in workspace → reaches sidecar
#                    (returns "stalled:…" because localhost:19999 is not running,
#                     but never "denied:")
#   3. Force-clamp — excess force on grasp is silently clamped, not denied
#   4. Budget kill — budget_actions=1; second actuating call returns "killed:…"
#
# Run (standalone):
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
#       tests/test_mcp_grant.lex main

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.time" as time

import "lex-schema/json_value" as jv

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

fn move_to_args(x :: Float, y :: Float, z :: Float) -> jv.Json {
  JObj([("x", JFloat(x)), ("y", JFloat(y)), ("z", JFloat(z))])
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Deny: skill not in grant → dispatch returns "denied:…" immediately.
fn test_deny_skill_not_in_grant() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["grasp"], 10)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let text := mcp.dispatch_skill(robot, db, log, "move_to", move_to_args(0.5, 0.5, 0.2))
        if str.starts_with(text, "denied:") {
          Ok(())
        } else {
          Err(str.concat("expected denied, got: ", text))
        }
      },
    },
  }
}

# 2. Allow: skill present, target in workspace → hits sidecar (stalled ≠ denied).
fn test_allow_reaches_sidecar() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_to"], 10)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let text := mcp.dispatch_skill(robot, db, log, "move_to", move_to_args(0.5, 0.5, 0.2))
        if str.starts_with(text, "denied:") {
          Err(str.concat("skill was denied but should have reached sidecar: ", text))
        } else {
          Ok(())
        }
      },
    },
  }
}

# 3. Clamp: grasp force above max_grip_force is clamped, not denied.
fn test_grasp_force_clamped_not_denied() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["grasp"], 10)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let text := mcp.dispatch_skill(robot, db, log, "grasp", JObj([("force", JFloat(999.9))]))
        if str.starts_with(text, "denied: skill grasp") {
          Err(str.concat("grasp was denied (should be clamped): ", text))
        } else {
          Ok(())
        }
      },
    },
  }
}

# 4. Budget: budget_actions=1; second actuating call returns "killed:…".
fn test_budget_exhausted_returns_killed() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_to"], 1)
        let _ := mcp.ledger_init(db, robot.grant, time.now_ms())
        let args := move_to_args(0.5, 0.5, 0.2)
        let _first := mcp.dispatch_skill(robot, db, log, "move_to", args)
        let second := mcp.dispatch_skill(robot, db, log, "move_to", args)
        if str.starts_with(second, "killed:") {
          Ok(())
        } else {
          Err(str.concat("expected killed, got: ", second))
        }
      },
    },
  }
}

# ── Runner (CI: panics on any failure) ───────────────────────────────────────

fn main() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, sense, actuate] Nil {
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
