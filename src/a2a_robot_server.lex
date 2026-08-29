# lex-robot/a2a_robot_server.lex — robot skills exposed over the standard
# Google A2A protocol (via lex-agent), grant-gated exactly like the MCP front
# door (mcp_server.lex).
#
# WHY A HAND-BUILT DISPATCHER (and not lex-agent's `AgentDef` / `Skill.handle`
# / `dispatch_request` / `mount`) — same reasoning mcp_server.lex documents
# for MCP, applied to A2A instead:
#
#   lex-agent's `Skill.handle` field is typed with a *concrete, fixed* effect
#   row — `[io, time, crypto, random, sql, fs_read, fs_write, net, concurrent,
#   llm, proc]` — chosen so an `AgentDef` mounts onto a `lex-web` router
#   without an effect-row impedance (see lex-agent/src/mount.lex). It knows
#   nothing about `sense`/`actuate`, and widening it would (a) weaken the
#   effect wall for every non-robot lex-agent consumer and (b) still not be
#   enough on its own, since `mount()`'s handler closure would then need a
#   row `lex-web`'s `router.route_effectful` doesn't accept either — a
#   second repo's fixed row, out of this package's control.
#
#   So, like mcp_server.lex, we reuse lex-agent's *pure* building blocks —
#   `agent_card` (the AgentCard/discovery document), `protocol` (JSON-RPC
#   envelope), `message`/`task` (the A2A Message/Task ADTs and lifecycle) —
#   and write our own `tasks/send` dispatch loop that calls straight into
#   `skills.lex` (which is where the grant/budget/trail checks actually
#   live). The result: any standard A2A client (ADK / LangGraph / CrewAI /
#   AutoGen, or lex-agent's own `client.lex`) can discover this robot's
#   skills at `/.well-known/agent.json` and drive them via `tasks/send`,
#   getting back a real, spec-shaped `Task` — while every command still goes
#   through the exact same grant check, force/workspace clamp, budget ledger,
#   and lex-trail audit as the MCP and in-process paths. One skill surface,
#   three front doors (in-process API, MCP, A2A), no duplicated authority.
#
# Wire contract: a `tasks/send` request names the skill via `params.skill`
# (lex-agent's own convention — see its server.lex) and carries the skill's
# arguments as the first `DataPart` of `params.message.parts` (structured
# JSON, e.g. `{"type":"data","data":{"x":0.3,"y":0.0,"z":0.2}}` for
# `move_to`). The response is a real A2A `Task` in `completed` (outcome
# `reached`) or `failed` (`denied:`/`killed:`/`stalled:`/`timeout`/`error:`)
# state, with the outcome text carried in the reply message's `DataPart`.
#
# Authentication: `tasks/send` REQUIRES a `contextId` from a prior
# `session/open` call — `{"card_json":"<canonical a2a_card.lex RobotCard
# JSON>","sig_b64":"<ed25519 sig over that exact string>"}` — verified and
# consent-checked per a2a_robot_auth.lex, which is the module to read for
# the full model, what a public deployment MUST configure (a real
# `allowed_pubkeys` allowlist), and what this does NOT cover (no TLS, no
# per-request replay nonce). A `tasks/send` with an unknown/missing
# `contextId` is refused (-32099, spec-denied) before any skill runs.
#
# Skills: the five mcp_server.lex already exposes (move_to / grasp /
# connect_charger / read_joints / read_camera) plus the XLeRobot's dual-arm
# surface (move_arm / grasp_arm / move_base / read_base / listen) — the gap
# flagged when auditing lex-agent's involvement in managing the XLeRobot: none
# of these were reachable over any standard agent protocol before.
#
# Run: `llm`/`proc` are required even though nothing here calls them — the
# toolchain validates every function in the imported `lex-agent` package,
# not just the ones actually reached, and other files in that package
# declare them. Same reason mcp_server.lex's own Run command lists them.
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
#       src/a2a_robot_server.lex run

import "std.str" as str

import "std.float" as flt

import "std.list" as list

import "std.time" as time

import "std.sql" as sql

import "std.net" as net

import "std.map" as map

import "lex-schema/schema" as sch

import "lex-schema/json_value" as jv

import "lex-spec/capability" as cap

import "lex-agent/src/protocol" as rpc

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as a2atask

import "lex-trail/log" as trail

import "./types" as t

import "./budget" as bud

import "./skills" as skills

import "./task" as rtask

import "./mcp_server" as mcp

import "./grant" as grant

import "./a2a_robot_auth" as auth

import "./a2a_consent" as consent

# ── Capability declarations (also serve as the AgentCard's advertised skills) ─
# The five shared with MCP are reused from mcp_server.lex rather than
# redeclared — one Capability value, two protocol front doors.
fn move_arm_cap() -> cap.Capability {
  cap.inbound("move_arm", "Move one XLeRobot arm ('left'|'right') to a 6-DOF pose in the arm frame; grant-gated per side and budget-supervised.", { title: "MoveArmArgs", description: "Which arm and target pose in metres in the arm frame. rx/ry/rz default to 0.", fields: [sch.required_str("arm", [StrNonEmpty]), sch.required_float("x", []), sch.required_float("y", []), sch.required_float("z", []), sch.optional(sch.required_float("rx", [])), sch.optional(sch.required_float("ry", [])), sch.optional(sch.required_float("rz", []))] })
}

fn grasp_arm_cap() -> cap.Capability {
  cap.inbound("grasp_arm", "Close one XLeRobot arm's gripper ('left'|'right') at the given force (Newtons); clamped to that arm's grant ceiling.", { title: "GraspArmArgs", description: "Which arm and closing force in Newtons.", fields: [sch.required_str("arm", [StrNonEmpty]), sch.required_float("force", [])] })
}

fn speak_cap() -> cap.Capability {
  cap.inbound("speak", "Speak text aloud through the robot's speaker (Kokoro TTS on real hardware; a simulated no-op on the stub/MuJoCo tiers). Grant-gated: an audible output is a real effect on the world.", { title: "SpeakArgs", description: "The text to say.", fields: [sch.required_str("text", [StrNonEmpty])] })
}

fn move_base_cap() -> cap.Capability {
  cap.inbound("move_base", "Drive the XLeRobot base to (x, y) on the floor; grant-gated to the permitted floor area, speed clamped to the ceiling.", { title: "MoveBaseArgs", description: "Target floor position in metres and requested speed (m/s, optional).", fields: [sch.required_float("x", []), sch.required_float("y", []), sch.optional(sch.required_float("speed", []))] })
}

fn read_base_cap() -> cap.Capability {
  cap.inbound("read_base", "Read the base's current floor pose (sensing only — no actuation, no budget charge).", { title: "ReadBaseArgs", description: "No arguments.", fields: [] })
}

fn listen_cap() -> cap.Capability {
  cap.inbound("listen", "Capture and locally transcribe microphone audio (sensing only — raw audio never leaves the sidecar).", { title: "ListenArgs", description: "Recording duration in seconds.", fields: [sch.required_float("seconds", [])] })
}

fn scan_ahead_cap() -> cap.Capability {
  cap.inbound("scan_ahead", "Look ahead and report obstacles WITH BEARINGS IN DEGREES (negative left, 0 straight ahead, positive right), plus whether the floor is clear: \"yes\", \"no\", or \"unknown\". A labelled degree scale is drawn into the frame before the vision model reads it, so bearings are read off a ruler rather than guessed. \"unknown\" means the floor could not be seen (dark, occluded, camera angled up) and is NEVER a yes. Sensing only — no actuation, no budget charge.", { title: "ScanAheadArgs", description: "Optional free-text hint about what the caller intends to do.", fields: [sch.optional(sch.required_str("question", []))] })
}

fn locate_object_cap() -> cap.Capability {
  cap.inbound("locate_object", "Find a named object's real-world position via the head camera (Tier-2: color detection + ray-cast against the rendered image; Tier-1: a canned lookup; sensing only — no actuation, no budget charge).", { title: "LocateObjectArgs", description: "The object's name (e.g. \"cup\").", fields: [sch.required_str("name", [StrNonEmpty])] })
}

fn transform_to_arm_cap() -> cap.Capability {
  cap.inbound("transform_to_arm", "Re-project a world position (from an earlier locate_object) into whichever arm frame is nearest, using the base's CURRENT pose (sensing only — no actuation, no budget charge).", { title: "TransformToArmArgs", description: "World-frame target in metres.", fields: [sch.required_float("x", []), sch.required_float("y", []), sch.required_float("z", [])] })
}

fn all_capabilities() -> List[cap.Capability] {
  [mcp.move_to_cap(), mcp.grasp_cap(), mcp.connect_charger_cap(), mcp.read_joints_cap(), mcp.read_camera_cap(), move_arm_cap(), grasp_arm_cap(), move_base_cap(), read_base_cap(), listen_cap(), locate_object_cap(), scan_ahead_cap(), transform_to_arm_cap(), speak_cap()]
}

fn robot_agent_card(base_url :: Str) -> card.AgentCard {
  card.make("lex-robot", "Effect-typed, capability-bounded robot skills over standard A2A — every tasks/send is grant-gated, budget-supervised, and lex-trail audited before it reaches the sidecar.", "0.1.0", base_url, all_capabilities())
}

fn agent_card_response(base_url :: Str) -> Str {
  card.card_to_pretty(robot_agent_card(base_url))
}

# ── Arg extraction (mirrors mcp_server.lex's, plus an Int getter for `listen`) ─
fn get_int(args :: jv.Json, key :: Str, dflt :: Int) -> Int {
  match jv.get_field(args, key) {
    None => dflt,
    Some(v) => match jv.as_int(v) {
      Some(i) => i,
      None => dflt,
    },
  }
}

# ── XLeRobot dispatch (mirrors mcp_server.lex's dispatch_move_to/dispatch_grasp:
# ledger-checked, grant-gated via skills.lex, lex-trail audited) — the ledger
# here is PER-SESSION (auth.session_ledger_read/session_charge_if_committed,
# keyed by ctx_id), not mcp_server.lex's single global one, so one caller's
# session running out of budget cannot starve another's. ─────────────────────
fn dispatch_move_arm(robot :: t.Robot, db :: Db, log :: trail.Log, ctx_id :: Str, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  let arm := mcp.get_str(args, "arm", "left")
  let target := { pos: { x: mcp.get_float(args, "x", 0.0), y: mcp.get_float(args, "y", 0.0), z: mcp.get_float(args, "z", 0.0) }, rx: mcp.get_float(args, "rx", 0.0), ry: mcp.get_float(args, "ry", 0.0), rz: mcp.get_float(args, "rz", 0.0) }
  let now := time.now_ms()
  let led := auth.session_ledger_read(db, ctx_id, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => rtask.outcome_str(Killed(reason)),
    None => {
      let o := skills.move_arm(robot, arm, target)
      let detail := str.join(["{\"skill\":\"move_arm\",\"arm\":\"", arm, "\",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let __lex_discard_1 := rtask.trail_raw(log, "a2a", "a2a.move_arm", detail)
      let __lex_discard_2 := auth.session_charge_if_committed(db, ctx_id, led, o)
      rtask.outcome_str(o)
    },
  }
}

fn dispatch_grasp_arm(robot :: t.Robot, db :: Db, log :: trail.Log, ctx_id :: Str, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  let arm := mcp.get_str(args, "arm", "left")
  let force := mcp.get_float(args, "force", 0.0)
  let now := time.now_ms()
  let led := auth.session_ledger_read(db, ctx_id, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => rtask.outcome_str(Killed(reason)),
    None => {
      let o := skills.grasp_arm(robot, arm, force)
      let detail := str.join(["{\"skill\":\"grasp_arm\",\"arm\":\"", arm, "\",\"force\":", flt.to_str(force), ",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let __lex_discard_3 := rtask.trail_raw(log, "a2a", "a2a.grasp_arm", detail)
      let __lex_discard_4 := auth.session_charge_if_committed(db, ctx_id, led, o)
      rtask.outcome_str(o)
    },
  }
}

fn dispatch_speak(robot :: t.Robot, db :: Db, log :: trail.Log, ctx_id :: Str, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  let text := mcp.get_str(args, "text", "")
  let now := time.now_ms()
  let led := auth.session_ledger_read(db, ctx_id, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => rtask.outcome_str(Killed(reason)),
    None => {
      let o := skills.speak(robot, text)
      let detail := str.join(["{\"skill\":\"speak\",\"text\":\"", skills.json_escape_str(text), "\",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let __lex_discard_5 := rtask.trail_raw(log, "a2a", "a2a.speak", detail)
      let __lex_discard_6 := auth.session_charge_if_committed(db, ctx_id, led, o)
      rtask.outcome_str(o)
    },
  }
}

fn dispatch_move_base(robot :: t.Robot, db :: Db, log :: trail.Log, ctx_id :: Str, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  let target := { x: mcp.get_float(args, "x", 0.0), y: mcp.get_float(args, "y", 0.0), z: 0.0 }
  let speed := mcp.get_float(args, "speed", 0.3)
  let now := time.now_ms()
  let led := auth.session_ledger_read(db, ctx_id, robot.grant, now)
  match bud.breach(led, now) {
    Some(reason) => rtask.outcome_str(Killed(reason)),
    None => {
      let o := skills.move_base(robot, target, speed)
      let detail := str.join(["{\"skill\":\"move_base\",\"x\":", flt.to_str(target.x), ",\"y\":", flt.to_str(target.y), ",\"outcome\":\"", rtask.outcome_str(o), "\"}"], "")
      let __lex_discard_7 := rtask.trail_raw(log, "a2a", "a2a.move_base", detail)
      let __lex_discard_8 := auth.session_charge_if_committed(db, ctx_id, led, o)
      rtask.outcome_str(o)
    },
  }
}

# Sensing skills carry no budget charge here — same as MCP's read_joints/
# read_camera (skills.lex's own [sense]-only functions have no grant check
# internally by design; they never touch an actuator, so skills.lex treats
# them as carrying no authority to gate). That design is fine for a
# trusted in-process/MCP caller but not for an arbitrary A2A caller over a
# public port, so handle_tasks_send below checks grant.skill_allowed
# against the session's grant ONCE, before any dispatch_* here runs —
# these functions don't need to (and, for consistency with skills.lex's own
# sensing functions, deliberately don't) re-check it themselves.
fn dispatch_read_base(robot :: t.Robot) -> [net, sense] Str {
  match skills.read_base(robot) {
    Err(e) => str.concat("error: read_base: ", e),
    Ok(v) => str.join(["{\"x\":", flt.to_str(v.x), ",\"y\":", flt.to_str(v.y), "}"], ""),
  }
}

fn dispatch_scan_ahead(robot :: t.Robot, args :: jv.Json) -> [net, sense] Str {
  match skills.scan_ahead(robot, mcp.get_str(args, "question", "")) {
    Err(e) => str.concat("error: scan_ahead: ", e),
    Ok(s) => s,
  }
}

fn dispatch_listen(robot :: t.Robot, args :: jv.Json) -> [net, sense] Str {
  match skills.listen(robot, get_int(args, "seconds", 3)) {
    Err(e) => str.concat("error: listen: ", e),
    Ok(s) => s,
  }
}

fn located_to_json(loc :: t.Located) -> Str {
  str.join(["{\"arm\":\"", loc.arm, "\",", "\"world\":{\"x\":", flt.to_str(loc.world.x), ",\"y\":", flt.to_str(loc.world.y), ",\"z\":", flt.to_str(loc.world.z), "},", "\"offset\":{\"x\":", flt.to_str(loc.offset.x), ",\"y\":", flt.to_str(loc.offset.y), ",\"z\":", flt.to_str(loc.offset.z), "}}"], "")
}

fn dispatch_locate_object(robot :: t.Robot, args :: jv.Json) -> [net, sense] Str {
  match skills.locate_object(robot, mcp.get_str(args, "name", "")) {
    Err(e) => str.concat("error: locate_object: ", e),
    Ok(loc) => located_to_json(loc),
  }
}

fn dispatch_transform_to_arm(robot :: t.Robot, args :: jv.Json) -> [net, sense] Str {
  let world := { x: mcp.get_float(args, "x", 0.0), y: mcp.get_float(args, "y", 0.0), z: mcp.get_float(args, "z", 0.0) }
  match skills.transform_to_arm(robot, world) {
    Err(e) => str.concat("error: transform_to_arm: ", e),
    Ok(loc) => located_to_json(loc),
  }
}

# The single skill router — the XLeRobot skills above, falling through to
# mcp_server.lex's dispatch_skill for the five it already handles (move_to /
# grasp / connect_charger / read_joints / read_camera) and for unknown names
# (surfaces "error: unknown tool: …"). The caller has already been checked
# against the session's grant by handle_tasks_send before this runs.
#
# ctx_id keys the four XLeRobot actuating skills' PER-SESSION budget ledger
# (auth.session_ledger_read/session_charge_if_committed). The mcp.dispatch_skill
# fallback below does NOT get this treatment — its own move_to/grasp/
# connect_charger still charge mcp_server.lex's single global ledger, a
# known, narrow scope boundary (see a2a_robot_auth.lex's module comment).
fn dispatch_skill(robot :: t.Robot, db :: Db, log :: trail.Log, ctx_id :: Str, name :: Str, args :: jv.Json) -> [sql, time, net, sense, actuate] Str {
  if name == "move_arm" {
    dispatch_move_arm(robot, db, log, ctx_id, args)
  } else {
    if name == "grasp_arm" {
      dispatch_grasp_arm(robot, db, log, ctx_id, args)
    } else {
      if name == "speak" {
        dispatch_speak(robot, db, log, ctx_id, args)
      } else {
        if name == "move_base" {
          dispatch_move_base(robot, db, log, ctx_id, args)
        } else {
          if name == "read_base" {
            dispatch_read_base(robot)
          } else {
            if name == "listen" {
              dispatch_listen(robot, args)
            } else {
              if name == "locate_object" {
                dispatch_locate_object(robot, args)
              } else {
                if name == "scan_ahead" {
                  dispatch_scan_ahead(robot, args)
                } else {
                  if name == "transform_to_arm" {
                    dispatch_transform_to_arm(robot, args)
                  } else {
                    mcp.dispatch_skill(robot, db, log, name, args)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# ── A2A JSON-RPC routing (reuses lex-agent's protocol/message/task — pure
# wire shapes; only the skill call crosses into sense/actuate) ──────────────
fn required_str(j :: jv.Json, field :: Str) -> Result[Str, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_str(v) {
      Some(s) => Ok(s),
      None => Err(str.concat("param must be string: ", field)),
    },
  }
}

fn required_obj(j :: jv.Json, field :: Str) -> Result[jv.Json, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_obj(v) {
      Some(_) => Ok(v),
      None => Err(str.concat("param must be object: ", field)),
    },
  }
}

fn optional_str(j :: jv.Json, field :: Str) -> Str {
  match jv.get_field(j, field) {
    None => "",
    Some(v) => match jv.as_str(v) {
      Some(s) => s,
      None => "",
    },
  }
}

# Accept `contextId` (v0.3+ canonical) OR `sessionId` (legacy) — same
# tolerance as lex-agent's own server.lex.
fn required_context_id(params :: jv.Json) -> Result[Str, Str] {
  match jv.get_field(params, "contextId") {
    Some(v) => match jv.as_str(v) {
      Some(s) => Ok(s),
      None => Err("contextId must be string"),
    },
    None => match jv.get_field(params, "sessionId") {
      Some(v) => match jv.as_str(v) {
        Some(s) => Ok(s),
        None => Err("sessionId must be string"),
      },
      None => Err("missing param: contextId (or legacy sessionId)"),
    },
  }
}

# The skill's structured arguments ride as the first DataPart of the
# message (`{"type":"data","data":{...}}`) — text-only messages (e.g. a
# human-readable goal string) dispatch with no arguments.
fn first_data_part(parts :: List[msg.Part]) -> Option[jv.Json] {
  list.fold(parts, None, fn (acc :: Option[jv.Json], p :: msg.Part) -> Option[jv.Json] {
    match acc {
      Some(_) => acc,
      None => match p {
        DataPart(d) => Some(d),
        _ => None,
      },
    }
  })
}

fn is_failure_text(text :: Str) -> Bool {
  str.starts_with(text, "denied:") or str.starts_with(text, "killed:") or str.starts_with(text, "stalled:") or str.starts_with(text, "error:") or str.starts_with(text, "timeout")
}

# A stranger presents an Ed25519-signed card + signature; if it verifies and
# a2a_consent's policy doesn't refuse it, the caller gets back a contextId
# bound to a session Grant (the intersection of what the card asked for and
# `ceiling`, budget capped to the tighter of the two) — see
# a2a_robot_auth.lex for the full model and what it does NOT cover.
fn handle_session_open(db :: Db, ceiling :: t.Grant, policy :: consent.ConsentPolicy, req :: rpc.Request) -> [sql, crypto, time] rpc.Response {
  match required_str(req.params, "card_json") {
    Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
    Ok(card_json) => match required_str(req.params, "sig_b64") {
      Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
      Ok(sig_b64) => {
        let now := time.now_ms()
        match auth.open_session(db, ceiling, policy, card_json, sig_b64, now) {
          OpenRefused(why) => rpc.fail(req.id, rpc.err_spec_denied(), why),
          OpenOk(opened) => {
            let skill_json := list.map(opened.grant.skills, fn (s :: Str) -> jv.Json {
              JStr(s)
            })
            rpc.ok(req.id, JObj([("contextId", JStr(opened.context_id)), ("skills", JList(skill_json))]))
          },
        }
      },
    },
  }
}

# Every tasks/send is gated on a session opened via session/open FIRST — no
# session, no dispatch, for ANY skill name (sensing included: several of
# skills.lex's own sensing functions carry no grant check internally by
# design for trusted local callers — see dispatch_read_base's comment — so
# this is the one place that check happens for an A2A caller). The session's
# own narrowed Grant (never the server's ceiling `robot.grant`) is what
# actually reaches dispatch_skill.
fn handle_tasks_send(robot :: t.Robot, db :: Db, log :: trail.Log, req :: rpc.Request) -> [sql, time, net, sense, actuate] rpc.Response {
  match required_str(req.params, "id") {
    Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
    Ok(task_id) => match required_context_id(req.params) {
      Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
      Ok(ctx_id) => match auth.load_session(db, ctx_id) {
        None => rpc.fail(req.id, rpc.err_spec_denied(), "no active session for this contextId — call session/open first with a signed card"),
        Some(session) => match required_obj(req.params, "message") {
          Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
          Ok(mj) => match msg.parse_message(mj) {
            Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), str.concat("invalid message: ", e)),
            Ok(m) => {
              let skill_name := optional_str(req.params, "skill")
              let args := match first_data_part(m.parts) {
                Some(d) => d,
                None => JObj([]),
              }
              let session_robot := { sidecar_url: robot.sidecar_url, grant: session.grant }
              let outcome_text := if grant.skill_allowed(session.grant, skill_name) {
                dispatch_skill(session_robot, db, log, ctx_id, skill_name, args)
              } else {
                str.join(["denied: skill ", skill_name, " not in grant"], "")
              }
              let initial := a2atask.submitted(task_id, ctx_id, m)
              let working := match a2atask.advance(initial, TSWorking, None) {
                Ok(wt) => wt,
                Err(_) => initial,
              }
              let final_state := if is_failure_text(outcome_text) {
                TSFailed
              } else {
                TSCompleted
              }
              let reply := msg.agent_data(JObj([("skill", JStr(skill_name)), ("result", JStr(outcome_text))]))
              let final_task := match a2atask.advance(working, final_state, Some(reply)) {
                Ok(ft) => ft,
                Err(_) => working,
              }
              rpc.ok(req.id, a2atask.task_to_json(final_task))
            },
          },
        },
      },
    },
  }
}

fn handle_method(robot :: t.Robot, db :: Db, log :: trail.Log, policy :: consent.ConsentPolicy, req :: rpc.Request) -> [sql, crypto, time, net, sense, actuate] rpc.Response {
  if req.method == "session/open" {
    handle_session_open(db, robot.grant, policy, req)
  } else {
    if req.method == rpc.method_tasks_send() {
      handle_tasks_send(robot, db, log, req)
    } else {
      if req.method == rpc.method_tasks_send_subscribe() {
        handle_tasks_send(robot, db, log, req)
      } else {
        rpc.fail(req.id, rpc.err_method_not_found(), str.concat("method not supported: ", req.method))
      }
    }
  }
}

# Parse one JSON-RPC body and produce its response string. Transport-agnostic
# — mirrors lex-agent's own `dispatch_request` contract exactly, just with a
# wider effect row so the dispatch chain can actually reach `skills.lex`.
fn dispatch_request(robot :: t.Robot, db :: Db, log :: trail.Log, policy :: consent.ConsentPolicy, body :: Str) -> [sql, crypto, time, net, sense, actuate] Str {
  match rpc.parse_request(body) {
    Err(rpcerr) => rpc.response_to_str(ResErr(IdNull, rpcerr)),
    Ok(req) => rpc.response_to_str(handle_method(robot, db, log, policy, req)),
  }
}

# ── Entry point ───────────────────────────────────────────────────────────────
#
# Serves the AgentCard at GET /.well-known/agent.json and JSON-RPC dispatch at
# POST / — the same two routes lex-agent's own examples (01_ping_pong.lex)
# serve via std.net.serve_fn directly, bypassing lex-web/mount() entirely
# (see the module doc comment for why). Opens its own SQLite ledger + a
# persistent lex-trail log, exactly like mcp_server.lex's `run`.
fn empty_headers() -> Map[Str, Str] {
  map.from_list([("content-type", "application/json")])
}

fn run(robot :: t.Robot, port :: Int, base_url :: Str, trail_path :: Str, db_path :: Str, policy :: consent.ConsentPolicy) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, sense, actuate] Nil {
  match trail.open(trail_path) {
    Err(_) => (),
    Ok(log) => match sql.open(db_path) {
      Err(_) => (),
      Ok(db) => {
        let now := time.now_ms()
        let __lex_discard_9 := mcp.ledger_init(db, robot.grant, now)
        let __lex_discard_10 := auth.init_sessions_table(db)
        net.serve_fn(port, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, sense, actuate] Response {
          if req.method == "GET" {
            if req.path == "/.well-known/agent.json" {
              { status: 200, body: BodyStr(agent_card_response(base_url)), headers: empty_headers() }
            } else {
              { status: 404, body: BodyStr("{\"error\":\"not found\"}"), headers: empty_headers() }
            }
          } else {
            if req.method == "POST" {
              { status: 200, body: BodyStr(dispatch_request(robot, db, log, policy, req.body)), headers: empty_headers() }
            } else {
              { status: 405, body: BodyStr("{\"error\":\"method not allowed\"}"), headers: empty_headers() }
            }
          }
        })
      },
    },
  }
}

