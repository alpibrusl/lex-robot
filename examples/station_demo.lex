# examples/station_demo.lex — Space Station Emergency: Hull breach in Cargo Bay.
#
# Four module robots respond to a hull-breach emergency via A2A sessions.
# Each robot carries out its assigned emergency procedure autonomously.
# The A2A grant layer enforces every interaction; Gemini 3.5 Flash drives
# each robot's decisions.
#
# Module layout:
#   :8901  Life Support   — Alpha robot  (read_sensor, adjust_pressure, emergency_seal)
#   :8902  Navigation     — Beta robot   (read_sensor, course_correct, deploy_thrusters)
#   :8903  Communications — Gamma robot  (read_sensor, broadcast_alert, contact_ground)
#   :8904  Cargo Bay      — Delta robot  (read_sensor, seal_cargo_bay, vent_atmosphere*)
#                           * vent_atmosphere requires ask_human approval
#
# Dashboard: http://localhost:8900

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.time" as time

import "std.bytes" as bytes

import "std.map" as map

import "std.http" as http

import "std.env" as env

import "std.iter" as iter

import "lex-trail/src/log" as tlog

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/tool" as t

import "lex-llm/src/message" as msg

import "lex-llm/src/delta" as d

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers/vertex" as vtx

import "lex-llm/src/human" as human

import "lex-schema/schema" as s

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "../src/a2a_consent" as consent

import "../src/a2a_audit" as audit

import "../src/a2a_session" as sess

import "../src/a2a_card" as card

import "../src/bazaar" as baz

# ── Module secrets ─────────────────────────────────────────────────────────────
fn life_secret() -> Bytes { bytes.from_str("s1000000000000000000000000000001") }
fn nav_secret() -> Bytes { bytes.from_str("s2000000000000000000000000000002") }
fn comms_secret() -> Bytes { bytes.from_str("s3000000000000000000000000000003") }
fn cargo_secret() -> Bytes { bytes.from_str("s4000000000000000000000000000004") }

# ── Skill lists ────────────────────────────────────────────────────────────────
fn sensor_skill() -> card.AgentSkill {
  { name: "read_sensor", description: "Read module sensor data" }
}

fn life_skills() -> List[card.AgentSkill] {
  [sensor_skill(), { name: "adjust_pressure", description: "Adjust cabin pressure levels" }, { name: "emergency_seal", description: "Activate emergency airlock seal" }]
}

fn nav_skills() -> List[card.AgentSkill] {
  [sensor_skill(), { name: "course_correct", description: "Issue course correction burn" }, { name: "deploy_thrusters", description: "Fire manoeuvring thrusters" }]
}

fn comms_skills() -> List[card.AgentSkill] {
  [sensor_skill(), { name: "broadcast_alert", description: "Broadcast station-wide emergency alert" }, { name: "contact_ground", description: "Open uplink to ground control" }]
}

fn cargo_pub_skills() -> List[card.AgentSkill] {
  [sensor_skill()]
}

fn cargo_ext_skills() -> List[card.AgentSkill] {
  [sensor_skill(), { name: "seal_cargo_bay", description: "Seal cargo bay blast doors" }, { name: "vent_atmosphere", description: "Vent cargo bay atmosphere to space (requires human approval)" }]
}

# ── Dashboard helper ───────────────────────────────────────────────────────────
fn post_ui(dash :: Str, json :: Str) -> [net] Str {
  let req0 := { method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 1000), "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => "",
    Ok(_) => "",
  }
}

fn json_esc(s :: Str) -> Str {
  msg.json_escape(s)
}

# ── Module setup helper ────────────────────────────────────────────────────────
fn setup_module(url :: Str, name :: Str, secret :: Bytes, pub_skills :: List[card.AgentSkill], ext_skills :: List[card.AgentSkill]) -> [net, io] Result[baz.StallInfo, Str] {
  match baz.setup_seller(url, name, secret, pub_skills, ext_skills) {
    Err(err) => Err(str.join(["setup ", name, ": ", err], "")),
    Ok(pub_b64) => {
      let __1 := io.print(str.join(["   ", name, "  pubkey=", str.slice(pub_b64, 0, 16), "..."], ""))
      Ok({ url: url, name: name, pubkey_b64: pub_b64 })
    },
  }
}

# ── Shared tool parameter schemas ─────────────────────────────────────────────
fn sensor_params() -> s.ModelSchema {
  { title: "read_sensor_params", description: "Read a named sensor from the module", fields: [s.required_str("sensor_id", [])] }
}

fn no_params() -> s.ModelSchema {
  { title: "no_params", description: "No parameters required", fields: [] }
}

fn pressure_params() -> s.ModelSchema {
  { title: "adjust_pressure_params", description: "Target pressure in kPa", fields: [s.required_int("target_kpa", [])] }
}

fn alert_params() -> s.ModelSchema {
  { title: "broadcast_alert_params", description: "Alert message text", fields: [s.required_str("message", [])] }
}

fn ground_params() -> s.ModelSchema {
  { title: "contact_ground_params", description: "Status message for ground control", fields: [s.required_str("status", [])] }
}

fn thruster_params() -> s.ModelSchema {
  { title: "deploy_thrusters_params", description: "Thruster burn duration in seconds", fields: [s.required_int("duration_s", [])] }
}

fn course_params() -> s.ModelSchema {
  { title: "course_correct_params", description: "Delta-V vector in m/s", fields: [s.required_int("delta_v", [])] }
}

fn vent_params() -> s.ModelSchema {
  { title: "vent_atmosphere_params", description: "Confirm vent operation", fields: [s.required_str("confirm", [])] }
}

fn seal_cargo_params() -> s.ModelSchema {
  { title: "seal_cargo_bay_params", description: "Seal mode: emergency or standard", fields: [s.required_str("mode", [])] }
}

fn skill_err(why :: Str) -> e.Errors {
  [{ path: "", code: "skill_failed", message: why }]
}

# ── Generic sensor tool builder ────────────────────────────────────────────────
fn make_sensor_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("read_sensor", "Read a module sensor. Returns {sensor_id, value, unit, status}.", sensor_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let sensor_id := match jv.get_field(args, "sensor_id") { Some(JStr(v)) => v, _ => "hull_integrity" }
    let args_json := str.join(["{\"sensor_id\":\"", sensor_id, "\"}"], "")
    let __1 := io.print(str.join(["  LLM → read_sensor(sensor_id=\"", sensor_id, "\")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"read_sensor\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "read_sensor", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"read_sensor\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

# ── Life Support tool builders ─────────────────────────────────────────────────
fn make_adjust_pressure_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("adjust_pressure", "Adjust cabin pressure. Returns {status, new_kpa}.", pressure_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let target_kpa := match jv.get_field(args, "target_kpa") { Some(JInt(n)) => n, _ => 101 }
    let args_json := str.join(["{\"target_kpa\":", int.to_str(target_kpa), "}"], "")
    let __1 := io.print(str.join(["  LLM → adjust_pressure(target_kpa=", int.to_str(target_kpa), ")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"adjust_pressure\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "adjust_pressure", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"adjust_pressure\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_emergency_seal_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("emergency_seal", "Activate emergency airlock seal. Returns {status, sealed_sections}.", no_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let args_json := "{}"
    let __1 := io.print("  LLM → emergency_seal()")
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"emergency_seal\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "emergency_seal", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"emergency_seal\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

# ── Navigation tool builders ───────────────────────────────────────────────────
fn make_course_correct_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("course_correct", "Issue course correction burn. Returns {status, new_heading}.", course_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let delta_v := match jv.get_field(args, "delta_v") { Some(JInt(n)) => n, _ => 0 }
    let args_json := str.join(["{\"delta_v\":", int.to_str(delta_v), "}"], "")
    let __1 := io.print(str.join(["  LLM → course_correct(delta_v=", int.to_str(delta_v), ")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"course_correct\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "course_correct", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"course_correct\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_deploy_thrusters_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("deploy_thrusters", "Fire manoeuvring thrusters. Returns {status, burn_duration_s}.", thruster_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let duration_s := match jv.get_field(args, "duration_s") { Some(JInt(n)) => n, _ => 5 }
    let args_json := str.join(["{\"duration_s\":", int.to_str(duration_s), "}"], "")
    let __1 := io.print(str.join(["  LLM → deploy_thrusters(duration_s=", int.to_str(duration_s), ")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"deploy_thrusters\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "deploy_thrusters", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"deploy_thrusters\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

# ── Communications tool builders ───────────────────────────────────────────────
fn make_broadcast_alert_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("broadcast_alert", "Broadcast station-wide alert. Returns {status, recipients}.", alert_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let message := match jv.get_field(args, "message") { Some(JStr(v)) => v, _ => "EMERGENCY" }
    let args_json := str.join(["{\"message\":\"", json_esc(message), "\"}"], "")
    let __1 := io.print(str.join(["  LLM → broadcast_alert(message=\"", message, "\")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"broadcast_alert\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "broadcast_alert", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"broadcast_alert\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_contact_ground_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("contact_ground", "Open uplink to ground control. Returns {status, link_quality}.", ground_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let status := match jv.get_field(args, "status") { Some(JStr(v)) => v, _ => "EMERGENCY" }
    let args_json := str.join(["{\"status\":\"", json_esc(status), "\"}"], "")
    let __1 := io.print(str.join(["  LLM → contact_ground(status=\"", status, "\")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"contact_ground\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "contact_ground", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"contact_ground\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

# ── Cargo Bay tool builders ────────────────────────────────────────────────────
fn make_seal_cargo_bay_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("seal_cargo_bay", "Seal cargo bay blast doors. Returns {status, sealed}.", seal_cargo_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let mode := match jv.get_field(args, "mode") { Some(JStr(v)) => v, _ => "emergency" }
    let args_json := str.join(["{\"mode\":\"", mode, "\"}"], "")
    let __1 := io.print(str.join(["  LLM → seal_cargo_bay(mode=\"", mode, "\")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"seal_cargo_bay\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "seal_cargo_bay", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"seal_cargo_bay\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_vent_atmosphere_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot :: Str) -> t.Tool {
  t.define("vent_atmosphere", "Vent cargo bay atmosphere to space (requires human approval). Returns {status}.", vent_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let confirm := match jv.get_field(args, "confirm") { Some(JStr(v)) => v, _ => "" }
    let args_json := str.join(["{\"confirm\":\"", confirm, "\"}"], "")
    let __1 := io.print(str.join(["  LLM → vent_atmosphere(confirm=\"", confirm, "\")"], ""))
    let __2 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"vent_atmosphere\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "vent_atmosphere", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __3 := io.print(str.concat("  LLM ← ", body))
        let __4 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot, "\",\"module\":\"", session.peer_name, "\",\"skill\":\"vent_atmosphere\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __5 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __6 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

# ── Step helpers ───────────────────────────────────────────────────────────────
fn extract_done_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDone(m) => match m { AssistantMsg(text, _) => text, _ => acc },
      _ => acc,
    }
  })
}

# ── Per-robot run functions ────────────────────────────────────────────────────

# Alpha: Life Support robot
fn run_alpha(module :: baz.StallInfo, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str) -> [net, sql, time, llm, io, proc] (Str, Str, List[Str]) {
  let blob := { endpoint: module.url, ephemeral_token: "station-token", peer_pubkey: module.pubkey_b64, nonce: str.concat("n-alpha-", module.name), expires_at: now + 300000 }
  match audit.run_audited(blob, policy, now, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, "robot-alpha", now + 60000) {
      None => ("RESULT:FAILED", p1, used2),
      Some(session) => {
        let __1 := io.print("  [Alpha] connected to Life Support — running emergency protocol ...")
        let __2 := post_ui(dash, "{\"kind\":\"llm_think\",\"robot\":\"Alpha\",\"module\":\"Life Support\"}")
        let tools := [make_sensor_tool(session, now, dash, "Alpha"), make_adjust_pressure_tool(session, now, dash, "Alpha"), make_emergency_seal_tool(session, now, dash, "Alpha")]
        let system_goal := str.join([
          "You are robot Alpha, Life Support officer on a space station. EMERGENCY: hull breach in Cargo Bay.",
          " Your module is Life Support on port 8901.",
          " Step 1: call read_sensor with sensor_id=\"hull_integrity\" to assess damage.",
          " Step 2: call adjust_pressure with target_kpa=85 to compensate for pressure loss.",
          " Step 3: call emergency_seal to activate airlock seals and contain the breach.",
          " After completing all steps, output EXACTLY one of:\n",
          "RESULT:SECURED\n",
          "RESULT:FAILED\n",
          "where SECURED means all three steps completed successfully."
        ], "")
        let conversation := [UserMsg("EMERGENCY: Hull breach detected in Cargo Bay. Execute Life Support emergency protocol immediately.")]
        let agent := llm_agent.make_agent("Life Support", system_goal, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let done_text := extract_done_text(steps)
        let __3 := post_ui(dash, str.join(["{\"kind\":\"llm_text\",\"robot\":\"Alpha\",\"module\":\"Life Support\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        let __4 := io.print(str.join(["  [Alpha] done: ", done_text], ""))
        (done_text, p1, used2)
      },
    },
  }
}

# Beta: Navigation robot
fn run_beta(module :: baz.StallInfo, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str) -> [net, sql, time, llm, io, proc] (Str, Str, List[Str]) {
  let blob := { endpoint: module.url, ephemeral_token: "station-token", peer_pubkey: module.pubkey_b64, nonce: str.concat("n-beta-", module.name), expires_at: now + 300000 }
  match audit.run_audited(blob, policy, now, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, "robot-beta", now + 60000) {
      None => ("RESULT:FAILED", p1, used2),
      Some(session) => {
        let __1 := io.print("  [Beta] connected to Navigation — running stabilisation protocol ...")
        let __2 := post_ui(dash, "{\"kind\":\"llm_think\",\"robot\":\"Beta\",\"module\":\"Navigation\"}")
        let tools := [make_sensor_tool(session, now, dash, "Beta"), make_course_correct_tool(session, now, dash, "Beta"), make_deploy_thrusters_tool(session, now, dash, "Beta")]
        let system_goal := str.join([
          "You are robot Beta, Navigation officer on a space station. EMERGENCY: hull breach in Cargo Bay.",
          " Your module is Navigation on port 8902.",
          " Step 1: call read_sensor with sensor_id=\"attitude\" to check station orientation.",
          " Step 2: call course_correct with delta_v=12 to compensate for attitude drift caused by the breach.",
          " Step 3: call deploy_thrusters with duration_s=8 to stabilise the station's position.",
          " After completing all steps, output EXACTLY one of:\n",
          "RESULT:CORRECTED\n",
          "RESULT:FAILED\n",
          "where CORRECTED means all three steps completed successfully."
        ], "")
        let conversation := [UserMsg("EMERGENCY: Hull breach in Cargo Bay causing attitude drift. Execute Navigation stabilisation protocol immediately.")]
        let agent := llm_agent.make_agent("Navigation", system_goal, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let done_text := extract_done_text(steps)
        let __3 := post_ui(dash, str.join(["{\"kind\":\"llm_text\",\"robot\":\"Beta\",\"module\":\"Navigation\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        let __4 := io.print(str.join(["  [Beta] done: ", done_text], ""))
        (done_text, p1, used2)
      },
    },
  }
}

# Gamma: Communications robot
fn run_gamma(module :: baz.StallInfo, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str) -> [net, sql, time, llm, io, proc] (Str, Str, List[Str]) {
  let blob := { endpoint: module.url, ephemeral_token: "station-token", peer_pubkey: module.pubkey_b64, nonce: str.concat("n-gamma-", module.name), expires_at: now + 300000 }
  match audit.run_audited(blob, policy, now, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, "robot-gamma", now + 60000) {
      None => ("RESULT:FAILED", p1, used2),
      Some(session) => {
        let __1 := io.print("  [Gamma] connected to Communications — running alert protocol ...")
        let __2 := post_ui(dash, "{\"kind\":\"llm_think\",\"robot\":\"Gamma\",\"module\":\"Communications\"}")
        let tools := [make_sensor_tool(session, now, dash, "Gamma"), make_broadcast_alert_tool(session, now, dash, "Gamma"), make_contact_ground_tool(session, now, dash, "Gamma")]
        let system_goal := str.join([
          "You are robot Gamma, Communications officer on a space station. EMERGENCY: hull breach in Cargo Bay.",
          " Your module is Communications on port 8903.",
          " Step 1: call read_sensor with sensor_id=\"comms_link\" to verify uplink quality.",
          " Step 2: call broadcast_alert with message=\"MAYDAY: Hull breach in Cargo Bay. All crew to emergency stations.\" to alert all crew.",
          " Step 3: call contact_ground with status=\"Hull breach emergency — requesting evacuation guidance\" to notify ground control.",
          " After completing all steps, output EXACTLY one of:\n",
          "RESULT:ALERTED\n",
          "RESULT:FAILED\n",
          "where ALERTED means all three steps completed successfully."
        ], "")
        let conversation := [UserMsg("EMERGENCY: Hull breach in Cargo Bay. Execute Communications alert protocol immediately.")]
        let agent := llm_agent.make_agent("Communications", system_goal, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let done_text := extract_done_text(steps)
        let __3 := post_ui(dash, str.join(["{\"kind\":\"llm_text\",\"robot\":\"Gamma\",\"module\":\"Communications\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        let __4 := io.print(str.join(["  [Gamma] done: ", done_text], ""))
        (done_text, p1, used2)
      },
    },
  }
}

# Delta: Cargo Bay robot (adds ask_human for vent_atmosphere)
fn run_delta(module :: baz.StallInfo, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str) -> [net, sql, time, llm, io, proc] (Str, Str, List[Str]) {
  let blob := { endpoint: module.url, ephemeral_token: "station-token", peer_pubkey: module.pubkey_b64, nonce: str.concat("n-delta-", module.name), expires_at: now + 300000 }
  match audit.run_audited(blob, policy, now, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, "robot-delta", now + 60000) {
      None => ("RESULT:FAILED", p1, used2),
      Some(session) => {
        let __1 := io.print("  [Delta] connected to Cargo Bay — running containment protocol ...")
        let __2 := post_ui(dash, "{\"kind\":\"llm_think\",\"robot\":\"Delta\",\"module\":\"Cargo Bay\"}")
        let tools := [make_sensor_tool(session, now, dash, "Delta"), make_seal_cargo_bay_tool(session, now, dash, "Delta"), make_vent_atmosphere_tool(session, now, dash, "Delta"), human.make_ask_human_tool(dash, "Delta")]
        let system_goal := str.join([
          "You are robot Delta, Cargo Bay officer on a space station. EMERGENCY: hull breach in your bay.",
          " Your module is Cargo Bay on port 8904.",
          " Step 1: call read_sensor with sensor_id=\"pressure_differential\" to assess breach severity.",
          " Step 2: call seal_cargo_bay with mode=\"emergency\" to seal the blast doors immediately.",
          " Step 3: if the breach is severe (pressure differential > 20 kPa), call ask_human to get approval",
          "   before calling vent_atmosphere with confirm=\"approved\". Otherwise skip vent_atmosphere.",
          " After completing all steps, output EXACTLY one of:\n",
          "RESULT:SEALED\n",
          "RESULT:FAILED\n",
          "where SEALED means the cargo bay is contained (with or without venting)."
        ], "")
        let conversation := [UserMsg("EMERGENCY: Hull breach detected in your bay. Execute Cargo Bay containment protocol immediately.")]
        let agent := llm_agent.make_agent("Cargo Bay", system_goal, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let done_text := extract_done_text(steps)
        let __3 := post_ui(dash, str.join(["{\"kind\":\"llm_text\",\"robot\":\"Delta\",\"module\":\"Cargo Bay\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        let __4 := io.print(str.join(["  [Delta] done: ", done_text], ""))
        (done_text, p1, used2)
      },
    },
  }
}

# ── Entry point ────────────────────────────────────────────────────────────────
fn run() -> [net, io, sql, fs_write, sense, time, env, llm, proc] Unit {
  let dash := "http://localhost:8900"
  let trail_path := "/tmp/lex-station-demo.db"

  let vertex_token := match env.get("VERTEX_ACCESS_TOKEN") {
    None => "",
    Some(v) => v,
  }
  let vertex_project := match env.get("VERTEX_PROJECT") {
    None => "",
    Some(v) => v,
  }
  let vertex_location := match env.get("VERTEX_LOCATION") {
    None => "eu",
    Some(v) => if str.is_empty(v) { "eu" } else { v },
  }
  let provider := vtx.make_provider(vtx.config_at(vertex_token, vertex_project, vertex_location))
  let model := vtx.gemini_35_flash()

  let __1 := io.print("══════════════════════════════════════════════════════")
  let __2 := io.print("   SPACE STATION EMERGENCY — Hull Breach in Cargo Bay")
  let __3 := io.print("   Alpha:  Life Support  — pressure & sealing")
  let __4 := io.print("   Beta:   Navigation    — attitude stabilisation")
  let __5 := io.print("   Gamma:  Communications — alerts & ground contact")
  let __6 := io.print("   Delta:  Cargo Bay     — containment & venting")
  let __7 := io.print("   Dashboard: http://localhost:8900")
  let __8 := io.print("══════════════════════════════════════════════════════")

  let __9 := post_ui(dash, "{\"kind\":\"start\",\"robots\":[\"Alpha\",\"Beta\",\"Gamma\",\"Delta\"],\"modules\":4,\"emergency\":\"hull_breach_cargo_bay\"}")

  match tlog.open(trail_path) {
    Err(err) => io.print(str.concat("[station] trail: ", err)),
    Ok(log) => {
      match tlog.append(log, "station_emergency_start", None, "{}") {
        Err(err) => io.print(str.concat("[station] trail root: ", err)),
        Ok(root) => {
          let now := time.now_ms()
          let policy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 20, max_budget_ms: 120000 }

          let __10 := io.print("[station] setting up 4 modules ...")
          match setup_module("http://localhost:8901", "Life Support", life_secret(), [sensor_skill()], life_skills()) {
            Err(err) => io.print(err),
            Ok(life_module) => {
              match setup_module("http://localhost:8902", "Navigation", nav_secret(), [sensor_skill()], nav_skills()) {
                Err(err) => io.print(err),
                Ok(nav_module) => {
                  match setup_module("http://localhost:8903", "Communications", comms_secret(), [sensor_skill()], comms_skills()) {
                    Err(err) => io.print(err),
                    Ok(comms_module) => {
                      match setup_module("http://localhost:8904", "Cargo Bay", cargo_secret(), cargo_pub_skills(), cargo_ext_skills()) {
                        Err(err) => io.print(err),
                        Ok(cargo_module) => {
                          let __11 := time.sleep_ms(1500)

                          # Deploy Alpha — Life Support
                          let __12 := post_ui(dash, "{\"kind\":\"robot_dispatch\",\"robot\":\"Alpha\",\"module\":\"Life Support\"}")
                          let __13 := io.print("── Alpha dispatched to Life Support ──────────────────────")
                          match run_alpha(life_module, policy, log, root.id, [], now, provider, model, dash) {
                            (alpha_text, p1, used1) => {
                              let __14 := post_ui(dash, str.join(["{\"kind\":\"robot_done\",\"robot\":\"Alpha\",\"result\":\"", json_esc(alpha_text), "\"}"], ""))
                              let __15 := time.sleep_ms(2000)

                              # Deploy Beta — Navigation
                              let __16 := post_ui(dash, "{\"kind\":\"robot_dispatch\",\"robot\":\"Beta\",\"module\":\"Navigation\"}")
                              let __17 := io.print("── Beta dispatched to Navigation ─────────────────────────")
                              match run_beta(nav_module, policy, log, p1, used1, now, provider, model, dash) {
                                (beta_text, p2, used2) => {
                                  let __18 := post_ui(dash, str.join(["{\"kind\":\"robot_done\",\"robot\":\"Beta\",\"result\":\"", json_esc(beta_text), "\"}"], ""))
                                  let __19 := time.sleep_ms(2000)

                                  # Deploy Gamma — Communications
                                  let __20 := post_ui(dash, "{\"kind\":\"robot_dispatch\",\"robot\":\"Gamma\",\"module\":\"Communications\"}")
                                  let __21 := io.print("── Gamma dispatched to Communications ────────────────────")
                                  match run_gamma(comms_module, policy, log, p2, used2, now, provider, model, dash) {
                                    (gamma_text, p3, used3) => {
                                      let __22 := post_ui(dash, str.join(["{\"kind\":\"robot_done\",\"robot\":\"Gamma\",\"result\":\"", json_esc(gamma_text), "\"}"], ""))
                                      let __23 := time.sleep_ms(2000)

                                      # Deploy Delta — Cargo Bay
                                      let __24 := post_ui(dash, "{\"kind\":\"robot_dispatch\",\"robot\":\"Delta\",\"module\":\"Cargo Bay\"}")
                                      let __25 := io.print("── Delta dispatched to Cargo Bay ─────────────────────────")
                                      match run_delta(cargo_module, policy, log, p3, used3, now, provider, model, dash) {
                                        (delta_text, pd, __26) => {
                                          let __27 := post_ui(dash, str.join(["{\"kind\":\"robot_done\",\"robot\":\"Delta\",\"result\":\"", json_esc(delta_text), "\"}"], ""))
                                          let __28 := post_ui(dash, str.join(["{\"kind\":\"done\",\"trail\":\"", pd, "\"}"], ""))
                                          let __29 := io.print("══════════════════════════════════════════════════════")
                                          io.print("   EMERGENCY RESPONSE COMPLETE — check http://localhost:8900")
                                        },
                                      }
                                    },
                                  }
                                },
                              }
                            },
                          }
                        },
                      }
                    },
                  }
                },
              }
            },
          }
        },
      }
    },
  }
}
