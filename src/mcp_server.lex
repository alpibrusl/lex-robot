# lex-robot/mcp_server.lex — Robot skills exposed as a grant-gated MCP server.
#
# WHY THIS OWNS ITS OWN HTTP ENDPOINT (and does not go through lex-mcp's
# `run_http` / lex-agent's `AgentDef`):
#
#   lex-agent's `Skill.handle` field is typed with a *concrete, fixed* effect
#   row — `[io, time, crypto, random, sql, fs_read, fs_write, net, concurrent,
#   llm, proc]`. It deliberately knows nothing about `sense`/`actuate` (it is a
#   generic A2A/agent framework). A handler that transitively calls an actuating
#   skill (`skills.move_to :: [net, sense, actuate]`) therefore cannot fit that
#   field — there is no row variable to absorb the extra effects. Pushing a
#   physical-actuation handler through the generic `Skill` would require dragging
#   `sense`/`actuate` into lex-agent (and lex-web), weakening the DESIGN.md §4
#   effect wall for *every* agent consumer.
#
#   Instead we serve MCP directly: `std.net.serve_fn` DOES admit `actuate` in its
#   handler row, so this module declares `[..., sense, actuate]` honestly — the
#   effect wall holds at compile time (`lex check` sees the actuation) AND at run
#   time (`lex run` must be given `--allow-effects actuate`). We reuse lex-mcp's
#   *pure* protocol/tool builders (`proto.*`) and lex-agent's *pure* JSON-RPC
#   parser (`rpc.*`) for the wire format, so this is real MCP — only the dispatch
#   step, the one place that crosses into `actuate`, lives here where the wall is.
#
# Grant + budget checks are INSIDE the dispatcher (gate-in-handler, lex-guard
# pattern): the grant/clamp logic stays in `skills.lex` (every call goes through
# `skills.move_to` etc., never a raw `client.call`), so there is no bypass path
# and no duplicated grant logic.
#
# SQLite ledger table (single row, id=1):
#   robot_mcp_ledger(id, actions_used, started_ms, action_cap, wall_cap_ms)
# Initialized at startup from the grant; actions_used incremented on each
# actuating call; started_ms is fixed at server-start time, so the wall-clock
# budget spans the whole server lifetime.
#
# Skills:
#   move_to          — actuating; grant-gated (skill + workspace); budget-supervised
#   grasp            — actuating; grant-gated; force clamped to max_grip_force
#   connect_charger  — actuating; grant-gated; force clamped to max_force
#   read_joints      — sensing only; no grant/budget gate
#   read_camera      — sensing only; no grant/budget gate
#
# Entry point: `run(robot, port, trail_path, db_path)` → blocks serving MCP HTTP.
#
# Run:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
#       src/mcp_server.lex run

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.list" as list

import "std.map" as map

import "std.time" as time

import "std.sql" as sql

import "std.net" as net

import "lex-schema/schema" as sch

import "lex-schema/json_value" as jv

import "lex-spec/capability" as cap

import "lex-agent/src/protocol" as rpc

import "lex-trail/log" as trail

import "lex-mcp/src/protocol" as proto

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

# ── Arg extraction helpers (MCP tools/call arguments arrive as a Json object) ──

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

# ── Capability declarations (project to MCP tool descriptors for tools/list) ──

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

fn cap_to_tool(c :: cap.Capability) -> proto.McpTool {
  { name: c.name, description: c.description, input_schema: sch.to_json_schema(c.params) }
}

fn all_tools() -> List[proto.McpTool] {
  list.map([move_to_cap(), grasp_cap(), connect_charger_cap(), read_joints_cap(), read_camera_cap()], cap_to_tool)
}

# ── Tool dispatch — the single place that crosses into `sense`/`actuate` ──────
#
# Returns the reply text for a tools/call. For actuating skills the budget
# ledger is read from SQLite, the breach checked BEFORE the command leaves the
# box (→ "killed: …"), the skill run through the grant-gated `skills.*` API
# (→ "reached" / "denied: …" / "stalled: …"), and the structured SkillOutcome
# appended to the trail. One action is charged only when the command actually
# left the box: a grant `Denied` outcome never reaches the wire, so it is logged
# but NOT charged (the budget mirrors the manifest's `max_commands`). Sensor
# reads ("read_*") never charge the budget. An unknown tool name returns an
# "error: …" string so the caller surfaces `isError: true`.

# Charge one action against the ledger unless the grant refused the command
# (a `Denied` outcome never left the box, so it costs no budget).
fn charge_if_committed(db :: Db, led :: bud.Ledger, o :: t.Outcome) -> [sql] Unit {
  match o {
    Denied(_) => (),
    _ => ledger_write(db, bud.spend(led)),
  }
}

fn dispatch_move_to(robot :: t.Robot, db :: Db, log :: trail.Log, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  let target := {
    pos: { x: get_float(args, "x", 0.0), y: get_float(args, "y", 0.0), z: get_float(args, "z", 0.0) },
    rx: get_float(args, "rx", 0.0), ry: get_float(args, "ry", 0.0), rz: get_float(args, "rz", 0.0)
  }
  let now := time.now_ms()
  let led := ledger_read(db, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => rtask.outcome_str(Killed(reason)),
    None => {
      let o := skills.move_to(robot, target)
      let _ := rtask.trail_raw(log, "mcp", "mcp.move_to", rtask.skill_payload(robot.grant, target, o))
      let _ := charge_if_committed(db, led, o)
      rtask.outcome_str(o)
    },
  }
}

fn dispatch_grasp(robot :: t.Robot, db :: Db, log :: trail.Log, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  let force := get_float(args, "force", 0.0)
  let now := time.now_ms()
  let led := ledger_read(db, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => rtask.outcome_str(Killed(reason)),
    None => {
      let o := skills.grasp(robot, force)
      let detail := str.join(["{\"skill\":\"grasp\",\"force\":", flt.to_str(force), ",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let _ := rtask.trail_raw(log, "mcp", "mcp.grasp", detail)
      let _ := charge_if_committed(db, led, o)
      rtask.outcome_str(o)
    },
  }
}

fn dispatch_connect_charger(robot :: t.Robot, db :: Db, log :: trail.Log, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  let force := get_float(args, "force", 0.0)
  let now := time.now_ms()
  let led := ledger_read(db, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => rtask.outcome_str(Killed(reason)),
    None => {
      let o := skills.connect_charger(robot, force)
      let detail := str.join(["{\"skill\":\"connect_charger\",\"force\":", flt.to_str(force), ",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let _ := rtask.trail_raw(log, "mcp", "mcp.connect_charger", detail)
      let _ := charge_if_committed(db, led, o)
      rtask.outcome_str(o)
    },
  }
}

# The single tool router. Declares `sense`/`actuate` because the actuating
# branches transitively produce them — this is the effect-wall marker that makes
# `lex run --allow-effects` able to withhold actuation from the whole server.
fn dispatch_skill(robot :: t.Robot, db :: Db, log :: trail.Log, name :: Str, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  if name == "move_to" {
    dispatch_move_to(robot, db, log, args)
  } else {
    if name == "grasp" {
      dispatch_grasp(robot, db, log, args)
    } else {
      if name == "connect_charger" {
        dispatch_connect_charger(robot, db, log, args)
      } else {
        if name == "read_joints" {
          match skills.read_joints(robot) {
            Err(e) => str.concat("error: read_joints: ", e),
            Ok(s) => s,
          }
        } else {
          if name == "read_camera" {
            match skills.read_camera(robot, get_str(args, "name", "main")) {
              Err(e) => str.concat("error: read_camera: ", e),
              Ok(s) => s,
            }
          } else {
            str.concat("error: unknown tool: ", name)
          }
        }
      }
    }
  }
}

# ── JSON-RPC routing (reuses lex-agent rpc.* + lex-mcp proto.* — pure) ────────

fn handle_tools_call(robot :: t.Robot, db :: Db, log :: trail.Log, req :: rpc.Request) -> [sql, time, net, sense, actuate] Str {
  let name := match jv.get_field(req.params, "name") {
    None => "",
    Some(v) => match jv.as_str(v) { Some(s) => s, None => "" },
  }
  let args := match jv.get_field(req.params, "arguments") {
    None => JObj([]),
    Some(a) => a,
  }
  if str.is_empty(name) {
    rpc.response_to_str(ResOk(req.id, proto.tools_call_error("tools/call missing required param: name")))
  } else {
    let text := dispatch_skill(robot, db, log, name, args)
    let result := if str.starts_with(text, "error:") {
      proto.tools_call_error(text)
    } else {
      proto.tools_call_result(text)
    }
    rpc.response_to_str(ResOk(req.id, result))
  }
}

fn route(robot :: t.Robot, db :: Db, log :: trail.Log, req :: rpc.Request) -> [sql, time, net, sense, actuate] Str {
  if req.method == proto.method_initialize() {
    rpc.response_to_str(ResOk(req.id, proto.initialize_result("lex-robot-mcp", "0.1.0")))
  } else {
    if req.method == proto.method_notifications_initialized() {
      ""
    } else {
      if req.method == proto.method_tools_list() {
        rpc.response_to_str(ResOk(req.id, proto.tools_list_result(all_tools())))
      } else {
        if req.method == proto.method_tools_call() {
          handle_tools_call(robot, db, log, req)
        } else {
          rpc.response_to_str(ResErr(req.id, rpc.error(rpc.err_method_not_found(), str.concat("method not supported: ", req.method))))
        }
      }
    }
  }
}

# Parse one JSON-RPC body and produce its response string ("" for notifications).
fn handle_message(robot :: t.Robot, db :: Db, log :: trail.Log, body :: Str) -> [sql, time, net, sense, actuate] Str {
  match rpc.parse_request(body) {
    Err(rpcerr) => rpc.response_to_str(ResErr(IdNull, rpcerr)),
    Ok(req) => route(robot, db, log, req),
  }
}

# ── Entry point ───────────────────────────────────────────────────────────────
#
# Opens a persistent trail at `trail_path` and a SQLite ledger DB at `db_path`,
# initialises the budget ledger from the grant, then serves MCP over HTTP on
# `port` via `net.serve_fn`. Blocks indefinitely. The request handler declares
# `sense`/`actuate`, so the whole binary requires `--allow-effects …,sense,
# actuate` — withhold them and no command can leave the box (the runtime half of
# the effect wall) even though the same code is reachable over the network.

fn run(robot :: t.Robot, port :: Int, trail_path :: Str, db_path :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, sense, actuate] Nil {
  match trail.open(trail_path) {
    Err(_) => (),
    Ok(log) => match sql.open(db_path) {
      Err(_) => (),
      Ok(db) => {
        let now := time.now_ms()
        let _ := ledger_init(db, robot.grant, now)
        let hdrs := map.from_list([("content-type", "application/json")])
        let handler := fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, sense, actuate] Response {
          if req.method == "POST" {
            let out := handle_message(robot, db, log, req.body)
            if str.is_empty(out) {
              { status: 202, body: BodyStr(""), headers: hdrs }
            } else {
              { status: 200, body: BodyStr(out), headers: hdrs }
            }
          } else {
            { status: 405, body: BodyStr("{\"error\":\"MCP HTTP transport accepts POST only\"}"), headers: hdrs }
          }
        }
        net.serve_fn(port, handler)
      },
    },
  }
}
