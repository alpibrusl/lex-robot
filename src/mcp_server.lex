# lex-robot/mcp_server.lex — Robot skills exposed as a grant-gated MCP server.
#
# Pattern mirrors lex-guard/src/skill.lex: each skill handler closes over the
# Robot (grant + sidecar URL), a SQLite DB for budget-ledger persistence, and a
# lex-trail Log. Budget and grant checks are INSIDE the handlers — no bypass
# path through the transport layer.
#
# SQLite ledger table (single row, id=1):
#   robot_mcp_ledger(id, actions_used, started_ms, action_cap, wall_cap_ms)
# Initialized at startup from the grant; actions_used incremented on each
# actuating call; started_ms is fixed at server-start time.
#
# Skills:
#   move_to          — actuating; grant-gated (skill + workspace); budget-supervised
#   grasp            — actuating; grant-gated; force clamped to max_grip_force
#   connect_charger  — actuating; grant-gated; force clamped to max_force
#   read_joints      — sensing only; no grant/budget gate
#   read_camera      — sensing only; no grant/budget gate
#
# Entry point: `run(robot, port, trail_path)` → blocks serving MCP over HTTP.
#
# Run:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#       src/mcp_server.lex run \
#       '{"sidecar_url":"http://localhost:8900","grant":{...}}' 8080 /tmp/robot_trail.db

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.list" as list

import "std.time" as time

import "std.sql" as sql

import "lex-schema/schema" as sch

import "lex-schema/json_value" as jv

import "lex-spec/capability" as cap

import "lex-agent/src/server" as srv

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "lex-agent/src/agent_card" as card

import "lex-trail/log" as trail

import "lex-mcp/src/http" as mcphttp

import "./types" as t

import "./grant" as grant

import "./budget" as bud

import "./skills" as skills

import "./task" as rtask

# ── SQLite-backed ledger persistence ─────────────────────────────────────────
#
# The grant's budget (action count + wall-clock) is a pure Ledger value in
# budget.lex. Across MCP requests we need to persist actions_used and started_ms
# so the server self-limits across calls just like the single-task loop does.

fn ledger_init(db :: Db, g :: t.Grant, now_ms :: Int) -> [sql] Unit {
  let _ := sql.exec(db, "CREATE TABLE IF NOT EXISTS robot_mcp_ledger (id INTEGER PRIMARY KEY, actions_used INTEGER NOT NULL, started_ms INTEGER NOT NULL, action_cap INTEGER NOT NULL, wall_cap_ms INTEGER NOT NULL)", [])
  let q := str.join(["INSERT OR IGNORE INTO robot_mcp_ledger (id, actions_used, started_ms, action_cap, wall_cap_ms) VALUES (1, 0, ", int.to_str(now_ms), ", ", int.to_str(g.budget_actions), ", ", int.to_str(g.budget_wall_ms), ")"], "")
  let _ := sql.exec(db, q, [])
  ()
}

fn ledger_read(db :: Db, g :: t.Grant, now_ms :: Int) -> [sql] bud.Ledger {
  let result :: Result[List[{ actions_used :: Int, started_ms :: Int, action_cap :: Int, wall_cap_ms :: Int }], SqlError] := sql.query(db, "SELECT actions_used, started_ms, action_cap, wall_cap_ms FROM robot_mcp_ledger WHERE id = 1", [])
  match result {
    Err(_) => bud.start(g, now_ms),
    Ok(rows) => match list.head(rows) {
      None => bud.start(g, now_ms),
      Some(row) => { actions_used: row.actions_used, started_ms: row.started_ms, action_cap: row.action_cap, wall_cap_ms: row.wall_cap_ms },
    },
  }
}

fn ledger_write(db :: Db, led :: bud.Ledger) -> [sql] Unit {
  let q := str.join(["UPDATE robot_mcp_ledger SET actions_used = ", int.to_str(led.actions_used), " WHERE id = 1"], "")
  let _ := sql.exec(db, q, [])
  ()
}

# ── Arg extraction helpers ────────────────────────────────────────────────────

fn extract_args(m :: msg.Message) -> jv.Json {
  match list.head(m.parts) {
    None => JObj([]),
    Some(p) => match p {
      DataPart(j) => j,
      _ => JObj([]),
    },
  }
}

fn get_float(args :: jv.Json, key :: Str, dflt :: Float) -> Float {
  match jv.get_field(args, key) {
    None => dflt,
    Some(v) => match jv.as_float(v) {
      Some(f) => f,
      None => match jv.as_int(v) {
        Some(i) => int.to_float(i),
        None => dflt,
      },
    },
  }
}

fn get_str(args :: jv.Json, key :: Str, dflt :: Str) -> Str {
  match jv.get_field(args, key) {
    None => dflt,
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => dflt,
    },
  }
}

fn outcome_reply(o :: t.Outcome) -> srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text(rtask.outcome_str(o))), artifacts: [] }
}

fn ok_reply(text :: Str) -> srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text(text)), artifacts: [] }
}

fn err_reply(text :: Str) -> srv.HandlerOutcome {
  { next_state: TSFailed, reply: Some(msg.agent_text(text)), artifacts: [] }
}

# ── Capability declarations ───────────────────────────────────────────────────

fn move_to_cap() -> cap.Capability {
  cap.inbound("move_to", "Move end-effector to a 6-DOF pose; grant-gated (skill + workspace) and budget-supervised.", {
    title: "MoveToPose",
    description: "Target pose in metres in the robot base frame. rx/ry/rz default to 0.",
    fields: [
      sch.required_float("x", []),
      sch.required_float("y", []),
      sch.required_float("z", []),
      sch.optional(sch.required_float("rx", [])),
      sch.optional(sch.required_float("ry", [])),
      sch.optional(sch.required_float("rz", []))
    ]
  })
}

fn grasp_cap() -> cap.Capability {
  cap.inbound("grasp", "Close gripper at given force (Newtons); clamped to grant max_grip_force.", {
    title: "GraspArgs",
    description: "Gripper closing force in Newtons.",
    fields: [sch.required_float("force", [])]
  })
}

fn connect_charger_cap() -> cap.Capability {
  cap.inbound("connect_charger", "Seat EV charging connector at given force (Newtons); clamped to grant max_force.", {
    title: "ConnectChargerArgs",
    description: "Connector seating force in Newtons.",
    fields: [sch.required_float("force", [])]
  })
}

fn read_joints_cap() -> cap.Capability {
  cap.inbound("read_joints", "Read current joint angles and velocities (sensing only — no actuation, no budget charge).", {
    title: "ReadJointsArgs",
    description: "No arguments.",
    fields: []
  })
}

fn read_camera_cap() -> cap.Capability {
  cap.inbound("read_camera", "Capture a JPEG frame from a named camera (sensing only — no actuation, no budget charge).", {
    title: "ReadCameraArgs",
    description: "Camera name.",
    fields: [sch.required_str("name", [StrNonEmpty])]
  })
}

# ── Actuating skill handlers (budget-supervised, grant-gated) ─────────────────

fn do_move_to(robot :: t.Robot, db :: Db, log :: trail.Log, m :: msg.Message) -> [sql, time, net] srv.HandlerOutcome {
  let args := extract_args(m)
  let target := {
    pos: { x: get_float(args, "x", 0.0), y: get_float(args, "y", 0.0), z: get_float(args, "z", 0.0) },
    rx: get_float(args, "rx", 0.0), ry: get_float(args, "ry", 0.0), rz: get_float(args, "rz", 0.0)
  }
  let now := time.now_ms()
  let led := ledger_read(db, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => outcome_reply(Killed(reason)),
    None => {
      let o := skills.move_to(robot, target)
      let spent := bud.spend(led)
      let _ := ledger_write(db, spent)
      let _ := rtask.trail_raw(log, "mcp", "mcp.move_to", rtask.skill_payload(robot.grant, target, o))
      outcome_reply(o)
    },
  }
}

fn do_grasp(robot :: t.Robot, db :: Db, log :: trail.Log, m :: msg.Message) -> [sql, time, net] srv.HandlerOutcome {
  let args := extract_args(m)
  let force := get_float(args, "force", 0.0)
  let now := time.now_ms()
  let led := ledger_read(db, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => outcome_reply(Killed(reason)),
    None => {
      let o := skills.grasp(robot, force)
      let spent := bud.spend(led)
      let _ := ledger_write(db, spent)
      let detail := str.join(["{\"skill\":\"grasp\",\"force\":", flt.to_str(force), ",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let _ := rtask.trail_raw(log, "mcp", "mcp.grasp", detail)
      outcome_reply(o)
    },
  }
}

fn do_connect_charger(robot :: t.Robot, db :: Db, log :: trail.Log, m :: msg.Message) -> [sql, time, net] srv.HandlerOutcome {
  let args := extract_args(m)
  let force := get_float(args, "force", 0.0)
  let now := time.now_ms()
  let led := ledger_read(db, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => outcome_reply(Killed(reason)),
    None => {
      let o := skills.connect_charger(robot, force)
      let spent := bud.spend(led)
      let _ := ledger_write(db, spent)
      let detail := str.join(["{\"skill\":\"connect_charger\",\"force\":", flt.to_str(force), ",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let _ := rtask.trail_raw(log, "mcp", "mcp.connect_charger", detail)
      outcome_reply(o)
    },
  }
}

# ── Sensing handlers (no budget charge, no grant gate) ────────────────────────

fn do_read_joints(robot :: t.Robot, m :: msg.Message) -> [net] srv.HandlerOutcome {
  let _ := m
  match skills.read_joints(robot) {
    Err(e) => err_reply(str.concat("read_joints error: ", e)),
    Ok(s) => ok_reply(s),
  }
}

fn do_read_camera(robot :: t.Robot, m :: msg.Message) -> [net] srv.HandlerOutcome {
  let args := extract_args(m)
  let name := get_str(args, "name", "main")
  match skills.read_camera(robot, name) {
    Err(e) => err_reply(str.concat("read_camera error: ", e)),
    Ok(s) => ok_reply(s),
  }
}

# ── Skill assembly ────────────────────────────────────────────────────────────
#
# Each skill's handle closure carries the full effect row expected by srv.Skill
# (effect widening: the inner `do_*` function uses fewer effects; the wrapper
# satisfies the wider row). Pattern from lex-guard/src/skill.lex.

fn make_move_to_skill(robot :: t.Robot, db :: Db, log :: trail.Log) -> srv.Skill {
  { capability: move_to_cap(), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    do_move_to(robot, db, log, m)
  } }
}

fn make_grasp_skill(robot :: t.Robot, db :: Db, log :: trail.Log) -> srv.Skill {
  { capability: grasp_cap(), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    do_grasp(robot, db, log, m)
  } }
}

fn make_connect_charger_skill(robot :: t.Robot, db :: Db, log :: trail.Log) -> srv.Skill {
  { capability: connect_charger_cap(), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    do_connect_charger(robot, db, log, m)
  } }
}

fn make_read_joints_skill(robot :: t.Robot) -> srv.Skill {
  { capability: read_joints_cap(), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    do_read_joints(robot, m)
  } }
}

fn make_read_camera_skill(robot :: t.Robot) -> srv.Skill {
  { capability: read_camera_cap(), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    do_read_camera(robot, m)
  } }
}

# ── Agent assembly ────────────────────────────────────────────────────────────

fn make_agent(robot :: t.Robot, db :: Db, log :: trail.Log) -> srv.AgentDef {
  let c := card.make(
    "lex-robot-mcp",
    "Grant-gated, budget-supervised robot skills over MCP HTTP.",
    "0.1.0",
    "http://localhost:8080",
    [move_to_cap(), grasp_cap(), connect_charger_cap(), read_joints_cap(), read_camera_cap()])
  srv.make_agent_def(c, [
    make_move_to_skill(robot, db, log),
    make_grasp_skill(robot, db, log),
    make_connect_charger_skill(robot, db, log),
    make_read_joints_skill(robot),
    make_read_camera_skill(robot)
  ])
}

# ── Entry point ───────────────────────────────────────────────────────────────
#
# Opens a persistent trail at `trail_path`, opens a SQLite ledger DB at
# `db_path`, initialises the budget ledger from the grant, then starts the MCP
# HTTP server on `port`. Blocks indefinitely.

fn run(robot :: t.Robot, port :: Int, trail_path :: Str, db_path :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Nil {
  match trail.open(trail_path) {
    Err(e) => {
      let _ := str.concat("trail open failed: ", e)
      ()
    },
    Ok(log) => match sql.open(db_path) {
      Err(e) => {
        let _ := str.concat("ledger db open failed: ", e.message)
        ()
      },
      Ok(db) => {
        let now := time.now_ms()
        let _ := ledger_init(db, robot.grant, now)
        let agent := make_agent(robot, db, log)
        mcphttp.run_http(agent, port)
      },
    },
  }
}
