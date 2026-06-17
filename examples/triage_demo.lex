# examples/triage_demo.lex — Earthquake disaster response triage demo.
#
# Three sensor robots scan disaster zones and report casualties. A coordinator
# robot dispatches rescue units based on zone reports. Evacuation orders require
# mayor approval via ask_human.
#
# Zone layout:
#   :8901  Zone Alpha    — Sensor-A scans and tags survivors
#   :8902  Zone Beta     — Sensor-B scans and tags survivors
#   :8903  Zone Gamma    — Sensor-G scans and tags survivors
#   :8904  Hospital HQ   — Coordinator dispatches units, orders evacuation
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

import "std.iter" as iter

# ── Zone secrets ──────────────────────────────────────────────────────────────
fn alpha_secret() -> Bytes { bytes.from_str("d1000000000000000000000000000001") }
fn beta_secret()  -> Bytes { bytes.from_str("d2000000000000000000000000000002") }
fn gamma_secret() -> Bytes { bytes.from_str("d3000000000000000000000000000003") }
fn hq_secret()    -> Bytes { bytes.from_str("d4000000000000000000000000000004") }

# ── Skill lists ───────────────────────────────────────────────────────────────
fn zone_pub_skills() -> List[card.AgentSkill] {
  [{ name: "survey_zone", description: "Survey the zone for survivors and casualties" }]
}

fn zone_ext_skills() -> List[card.AgentSkill] {
  [{ name: "survey_zone", description: "Survey the zone for survivors and casualties" }, { name: "tag_survivors", description: "Tag survivors for rescue priority" }]
}

fn hq_pub_skills() -> List[card.AgentSkill] {
  [{ name: "dispatch_unit", description: "Dispatch a rescue unit to a zone" }]
}

fn hq_ext_skills() -> List[card.AgentSkill] {
  [{ name: "dispatch_unit", description: "Dispatch a rescue unit to a zone" }, { name: "order_evacuation", description: "Order evacuation of a zone" }, { name: "request_helicopter", description: "Request helicopter support for a zone" }]
}

# ── Dashboard helper ──────────────────────────────────────────────────────────
fn post_ui(dash :: Str, json :: Str) -> [net] Str {
  let req0 := { method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 1000), "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => "",
    Ok(_) => "",
  }
}

fn json_esc(sv :: Str) -> Str {
  msg.json_escape(sv)
}

# ── Stall setup helper ────────────────────────────────────────────────────────
fn setup_zone(url :: Str, name :: Str, secret :: Bytes, pub_skills :: List[card.AgentSkill], ext_skills :: List[card.AgentSkill]) -> [net, io] Result[baz.StallInfo, Str] {
  match baz.setup_seller(url, name, secret, pub_skills, ext_skills) {
    Err(er) => Err(str.join(["setup ", name, ": ", er], "")),
    Ok(pub_b64) => {
      let __1 := io.print(str.join(["   ", name, "  pubkey=", str.slice(pub_b64, 0, 16), "..."], ""))
      Ok({ url: url, name: name, pubkey_b64: pub_b64 })
    },
  }
}

# ── Error helpers ─────────────────────────────────────────────────────────────
fn skill_err(why :: Str) -> e.Errors {
  [{ path: "", code: "skill_failed", message: why }]
}

# ── Tool parameter schemas ────────────────────────────────────────────────────
fn no_params() -> s.ModelSchema {
  { title: "no_params", description: "No parameters required", fields: [] }
}

fn tag_params() -> s.ModelSchema {
  { title: "tag_params", description: "Tag survivors in a zone", fields: [s.required_str("zone_id", [])] }
}

fn dispatch_params() -> s.ModelSchema {
  { title: "dispatch_params", description: "Dispatch rescue units to a zone", fields: [s.required_str("zone_id", []), s.required_int("unit_count", [])] }
}

fn evacuate_params() -> s.ModelSchema {
  { title: "evacuate_params", description: "Order evacuation of a zone", fields: [s.required_str("zone_id", []), s.required_str("reason", [])] }
}

fn helicopter_params() -> s.ModelSchema {
  { title: "helicopter_params", description: "Request helicopter for a zone", fields: [s.required_str("zone_id", [])] }
}

# ── Tool builders ─────────────────────────────────────────────────────────────
fn make_survey_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot_id :: Str) -> t.Tool {
  t.define("survey_zone", "Survey the zone for survivors and casualties. Returns zone status and casualty count.", no_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let args_json := "{}"
    let __p0 := io.print(str.join(["  ", robot_id, " → survey_zone()"], ""))
    let __ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"survey_zone\",\"args\":{}}"], ""))
    match sess.invoke_skill(session, { skill: "survey_zone", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __p1 := io.print(str.concat("  LLM ← ", body))
        let __ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"survey_zone\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_tag_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot_id :: Str) -> t.Tool {
  t.define("tag_survivors", "Tag survivors for rescue priority.", tag_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let zone_id := match jv.get_field(args, "zone_id") { Some(JStr(v)) => v, _ => "" }
    let args_json := str.join(["{\"zone_id\":\"", zone_id, "\"}"], "")
    let __p0 := io.print(str.join(["  ", robot_id, " → tag_survivors(zone_id=\"", zone_id, "\")"], ""))
    let __ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"tag_survivors\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "tag_survivors", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __p1 := io.print(str.concat("  LLM ← ", body))
        let __ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"tag_survivors\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_dispatch_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot_id :: Str) -> t.Tool {
  t.define("dispatch_unit", "Dispatch rescue units to a zone.", dispatch_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let zone_id := match jv.get_field(args, "zone_id") { Some(JStr(v)) => v, _ => "" }
    let unit_count := match jv.get_field(args, "unit_count") { Some(JInt(n)) => n, _ => 0 }
    let args_json := str.join(["{\"zone_id\":\"", zone_id, "\",\"unit_count\":", int.to_str(unit_count), "}"], "")
    let __p0 := io.print(str.join(["  ", robot_id, " → dispatch_unit(zone_id=\"", zone_id, "\", unit_count=", int.to_str(unit_count), ")"], ""))
    let __ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"dispatch_unit\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "dispatch_unit", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __p1 := io.print(str.concat("  LLM ← ", body))
        let __ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"dispatch_unit\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_evacuate_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot_id :: Str) -> t.Tool {
  t.define("order_evacuation", "Order evacuation of a zone. Requires prior mayor approval via ask_human.", evacuate_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let zone_id := match jv.get_field(args, "zone_id") { Some(JStr(v)) => v, _ => "" }
    let reason := match jv.get_field(args, "reason") { Some(JStr(v)) => v, _ => "" }
    let args_json := str.join(["{\"zone_id\":\"", zone_id, "\",\"reason\":\"", json_esc(reason), "\"}"], "")
    let __p0 := io.print(str.join(["  ", robot_id, " → order_evacuation(zone_id=\"", zone_id, "\", reason=\"", reason, "\")"], ""))
    let __ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"order_evacuation\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "order_evacuation", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __p1 := io.print(str.concat("  LLM ← ", body))
        let __ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"order_evacuation\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_helicopter_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, robot_id :: Str) -> t.Tool {
  t.define("request_helicopter", "Request helicopter support for a zone.", helicopter_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let zone_id := match jv.get_field(args, "zone_id") { Some(JStr(v)) => v, _ => "" }
    let args_json := str.join(["{\"zone_id\":\"", zone_id, "\"}"], "")
    let __p0 := io.print(str.join(["  ", robot_id, " → request_helicopter(zone_id=\"", zone_id, "\")"], ""))
    let __ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"request_helicopter\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "request_helicopter", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let __p1 := io.print(str.concat("  LLM ← ", body))
        let __ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"robot\":\"", robot_id, "\",\"zone\":\"", session.peer_name, "\",\"skill\":\"request_helicopter\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let __p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let __p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

# ── Step helpers ──────────────────────────────────────────────────────────────
fn extract_done_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDone(m) => match m { AssistantMsg(text, _) => text, _ => acc },
      _ => acc,
    }
  })
}

fn emit_step_events(steps :: List[d.Step], zone_name :: Str, dash :: Str, robot_id :: Str) -> [net] Unit {
  let __r := list.fold(steps, (), fn (_ :: Unit, step :: d.Step) -> [net] Unit {
    match step {
      StepToolExec(name, _) => {
        let __p := post_ui(dash, str.join(["{\"kind\":\"llm_tool\",\"robot\":\"", robot_id, "\",\"zone\":\"", zone_name, "\",\"tool\":\"", name, "\"}"], ""))
        ()
      },
      _ => (),
    }
  })
  ()
}

# ── Per-robot sensor run ──────────────────────────────────────────────────────
# Returns (report_text, final_parent_id, updated_nonce_list)
fn run_sensor(zone :: baz.StallInfo, robot_id :: Str, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str) -> [net, sql, time, llm, io, proc] (Str, Str, List[Str]) {
  let blob := { endpoint: zone.url, ephemeral_token: "triage-token", peer_pubkey: zone.pubkey_b64, nonce: str.concat("n-", str.concat(robot_id, zone.name)), expires_at: now + 300000 }
  match audit.run_audited(blob, policy, now, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, str.concat("sensor-", zone.name), now + 60000) {
      None => {
        let __pf := io.print(str.join(["  [", robot_id, "] handshake failed for ", zone.name], ""))
        (str.join(["Zone ", zone.name, ": INACCESSIBLE (handshake failed)"], ""), p1, used2)
      },
      Some(session) => {
        let __think := post_ui(dash, str.join(["{\"kind\":\"sensor_start\",\"robot\":\"", robot_id, "\",\"zone\":\"", zone.name, "\"}"], ""))
        let __pio := io.print(str.join(["  [", robot_id, " @ LLM] scanning ", zone.name, " ..."], ""))

        let tools := [make_survey_tool(session, now, dash, robot_id), make_tag_tool(session, now, dash, robot_id)]

        let system_prompt := str.join([
          "You are ", robot_id, ", a disaster sensor robot scanning ", zone.name, ".",
          " Survey the zone and tag any survivors you find.",
          " Step 1: call survey_zone to assess the situation.",
          " Step 2: if survivors are found, call tag_survivors with the zone_id.",
          " After completing, output EXACTLY one of:\n",
          "RESULT:SURVEYED:N_CASUALTIES\n",
          "RESULT:CLEAR\n",
          "RESULT:INACCESSIBLE\n",
          "where N_CASUALTIES is the integer number of casualties found."
        ], "")

        let conversation := [UserMsg(str.join(["Scan ", zone.name, " for survivors and casualties."], ""))]
        let agent := llm_agent.make_agent(zone.name, system_prompt, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let __evs := emit_step_events(steps, zone.name, dash, robot_id)
        let done_text := extract_done_text(steps)
        let __lrt := post_ui(dash, str.join(["{\"kind\":\"sensor_done\",\"robot\":\"", robot_id, "\",\"zone\":\"", zone.name, "\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        let report := str.join(["Zone ", zone.name, " (", robot_id, "): ", done_text], "")
        (report, p1, used2)
      },
    },
  }
}

# ── Coordinator run ───────────────────────────────────────────────────────────
# Returns (summary_text, final_parent_id, updated_nonce_list)
fn run_coordinator(hq :: baz.StallInfo, zone_reports :: Str, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str) -> [net, sql, time, llm, io, proc] (Str, Str, List[Str]) {
  let blob := { endpoint: hq.url, ephemeral_token: "triage-token", peer_pubkey: hq.pubkey_b64, nonce: str.concat("n-", str.concat("Coordinator", hq.name)), expires_at: now + 300000 }
  match audit.run_audited(blob, policy, now, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, "coordinator-hq", now + 120000) {
      None => {
        let __pf := io.print("  [Coordinator] handshake with HQ failed")
        ("RESULT:OVERWHELMED (HQ handshake failed)", p1, used2)
      },
      Some(session) => {
        let __think := post_ui(dash, str.join(["{\"kind\":\"coordinator_start\",\"zone_reports\":\"", json_esc(zone_reports), "\"}"], ""))
        let __pio := io.print("  [Coordinator @ LLM] dispatching rescue units ...")

        let tools := [make_dispatch_tool(session, now, dash, "Coordinator"), make_evacuate_tool(session, now, dash, "Coordinator"), make_helicopter_tool(session, now, dash, "Coordinator"), human.make_ask_human_tool(dash, "Coordinator")]

        let system_prompt := str.join([
          "You are Coordinator at Hospital HQ managing earthquake disaster response.",
          " Zone reports: ", zone_reports, ".",
          " Your job: dispatch rescue units proportional to casualties found.",
          " For each zone with casualties, call dispatch_unit with zone_id and unit_count.",
          " For zones with mass casualties (>10), also call request_helicopter.",
          " IMPORTANT: Before calling order_evacuation for any zone, you MUST first call ask_human",
          " to get mayor approval. Include the zone_id and reason in your ask_human question.",
          " After completing all dispatches, output EXACTLY one of:\n",
          "RESULT:DISPATCHED:N\n",
          "RESULT:OVERWHELMED\n",
          "where N is the total number of units dispatched."
        ], "")

        let conversation := [UserMsg(str.join(["Zone reports received. Coordinate disaster response. Reports: ", zone_reports], ""))]
        let agent := llm_agent.make_agent("Hospital HQ", system_prompt, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let __evs := emit_step_events(steps, hq.name, dash, "Coordinator")
        let done_text := extract_done_text(steps)
        let __lrt := post_ui(dash, str.join(["{\"kind\":\"coordinator_done\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        (done_text, p1, used2)
      },
    },
  }
}

# ── Entry point ───────────────────────────────────────────────────────────────
fn run() -> [net, io, sql, fs_write, sense, time, env, llm, proc] Unit {
  let trail_path := "/tmp/lex-triage-demo.db"
  let dash := "http://localhost:8900"

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

  let __p1 := io.print("══════════════════════════════════════════════════════")
  let __p2 := io.print("   DISASTER TRIAGE DEMO  —  3 sensor robots, 1 coordinator")
  let __p3 := io.print("   Sensor-A → Zone Alpha (:8901)")
  let __p4 := io.print("   Sensor-B → Zone Beta  (:8902)")
  let __p5 := io.print("   Sensor-G → Zone Gamma (:8903)")
  let __p6 := io.print("   Coordinator → Hospital HQ (:8904)")
  let __p7 := io.print("   Dashboard: http://localhost:8900")
  let __p8 := io.print("══════════════════════════════════════════════════════")

  let __ui0 := post_ui(dash, "{\"kind\":\"start\",\"robots\":[\"Sensor-A\",\"Sensor-B\",\"Sensor-G\",\"Coordinator\"],\"zones\":4}")

  match tlog.open(trail_path) {
    Err(er) => io.print(str.concat("[triage] trail: ", er)),
    Ok(log) => {
      match tlog.append(log, "triage_start", None, "{}") {
        Err(er) => io.print(str.concat("[triage] trail root: ", er)),
        Ok(root) => {
          let now := time.now_ms()
          let policy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 20, max_budget_ms: 120000 }

          let __ps := io.print("[triage] setting up 4 zones ...")
          match setup_zone("http://localhost:8901", "Zone Alpha", alpha_secret(), zone_pub_skills(), zone_ext_skills()) {
            Err(er) => io.print(er),
            Ok(alpha) => {
              match setup_zone("http://localhost:8902", "Zone Beta", beta_secret(), zone_pub_skills(), zone_ext_skills()) {
                Err(er) => io.print(er),
                Ok(beta) => {
                  match setup_zone("http://localhost:8903", "Zone Gamma", gamma_secret(), zone_pub_skills(), zone_ext_skills()) {
                    Err(er) => io.print(er),
                    Ok(gamma) => {
                      match setup_zone("http://localhost:8904", "Hospital HQ", hq_secret(), hq_pub_skills(), hq_ext_skills()) {
                        Err(er) => io.print(er),
                        Ok(hq) => {
                          let __sl0 := time.sleep_ms(1000)

                          # ── Phase 1: Sensor robots scan zones sequentially ──
                          let __ph1 := io.print("── Phase 1: Scanning zones ──────────────────────────")
                          let __uiph1 := post_ui(dash, "{\"kind\":\"phase\",\"phase\":\"Scanning zones\"}")

                          match run_sensor(alpha, "Sensor-A", policy, log, root.id, [], now, provider, model, dash) {
                            (report_a, p1, used1) => {
                              let __pa := io.print(str.join(["[Sensor-A] ", report_a], ""))
                              let __sl1 := time.sleep_ms(2000)

                              match run_sensor(beta, "Sensor-B", policy, log, p1, used1, now, provider, model, dash) {
                                (report_b, p2, used2) => {
                                  let __pb := io.print(str.join(["[Sensor-B] ", report_b], ""))
                                  let __sl2 := time.sleep_ms(2000)

                                  match run_sensor(gamma, "Sensor-G", policy, log, p2, used2, now, provider, model, dash) {
                                    (report_g, p3, used3) => {
                                      let __pg := io.print(str.join(["[Sensor-G] ", report_g], ""))
                                      let __sl3 := time.sleep_ms(2000)

                                      # ── Phase 2: Coordinator dispatches units ──
                                      let __ph2 := io.print("── Phase 2: Dispatching units ───────────────────────")
                                      let __uiph2 := post_ui(dash, "{\"kind\":\"phase\",\"phase\":\"Dispatching units\"}")

                                      let zone_reports := str.join([report_a, " | ", report_b, " | ", report_g], "")
                                      let __pcoord := io.print(str.join(["[Coordinator] zone reports: ", zone_reports], ""))

                                      match run_coordinator(hq, zone_reports, policy, log, p3, used3, now, provider, model, dash) {
                                        (summary, __p4c, __used4) => {
                                          let __psum := io.print(str.join(["[Coordinator] ", summary], ""))
                                          let __sl4 := time.sleep_ms(2000)
                                          let __done := post_ui(dash, "{\"kind\":\"done\"}")
                                          let __pf1 := io.print("══════════════════════════════════════════════════════")
                                          io.print("   TRIAGE COMPLETE  —  check http://localhost:8900")
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
