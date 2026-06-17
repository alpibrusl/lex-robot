# src/bazaar_llm.lex — LLM-driven A2A shopping agent for the robot bazaar.
#
# Wraps an A2A session's skills as lex-llm Tools so that an LLM provider
# autonomously drives the query→reserve→buy sequence.
# The A2A grant is still enforced on every skill call.
#
# shop_with_llm parameters:
#   goal             — free-form natural-language shopping goal from the operator
#   ask_human_enabled — if true, adds the generic ask_human tool so the LLM
#                       can pause and ask the operator for guidance
#
# Dashboard events:
#   llm_think   — LLM starting at a stall
#   a2a_call    — skill call with arguments
#   a2a_resp    — skill response body
#   llm_tool    — which tool was invoked
#   llm_text    — the LLM's final reasoning text
#
# Effects: [net, sql, time, llm, io, proc]

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.iter" as iter

import "std.io" as io

import "std.http" as http

import "std.bytes" as bytes

import "std.map" as map

import "lex-trail/src/log" as tlog

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/tool" as t

import "lex-llm/src/message" as msg

import "lex-llm/src/delta" as d

import "lex-llm/src/provider" as prov

import "lex-llm/src/human" as human

import "lex-schema/schema" as s

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "./a2a_consent" as consent

import "./a2a_audit" as audit

import "./a2a_session" as sess

import "./bazaar" as baz

# ── Dashboard helper ──────────────────────────────────────────────────────────
fn post_event(dash :: Str, json :: Str) -> [net] Str {
  if str.is_empty(dash) {
    ""
  } else {
    let req0 := { method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }
    let req := http.with_header(http.with_timeout_ms(req0, 1000), "Content-Type", "application/json")
    match http.send(req) {
      Err(_) => "",
      Ok(_) => "",
    }
  }
}

fn json_esc(s :: Str) -> Str {
  msg.json_escape(s)
}

# ── Tool parameter schemas ────────────────────────────────────────────────────
fn query_params() -> s.ModelSchema {
  { title: "query_stock_params", description: "Search stock by keyword and price ceiling", fields: [s.required_str("search", []), s.required_int("max_price", [])] }
}

fn reserve_params() -> s.ModelSchema {
  { title: "reserve_params", description: "Reserve an item by ID", fields: [s.required_str("item_id", [])] }
}

fn complete_params() -> s.ModelSchema {
  { title: "complete_params", description: "Finalise purchase", fields: [s.required_str("item_id", []), s.required_int("payment", [])] }
}

fn skill_err(why :: Str) -> e.Errors {
  [{ path: "", code: "skill_failed", message: why }]
}

# ── Tool builders ─────────────────────────────────────────────────────────────
fn make_query_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, customer :: Str) -> t.Tool {
  t.define("query_stock", "Search stall inventory. Returns {found,id,name,category,price} or {found:0}.", query_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let search := match jv.get_field(args, "search") { Some(JStr(v)) => v, _ => "" }
    let max_price := match jv.get_field(args, "max_price") { Some(JInt(n)) => n, _ => 0 }
    let args_json := str.join(["{\"search\":\"", search, "\",\"max_price\":", int.to_str(max_price), "}"], "")
    let _p0 := io.print(str.join(["  LLM → query_stock(search=\"", search, "\", max_price=", int.to_str(max_price), ")"], ""))
    let _ev0 := post_event(dash, str.join(["{\"kind\":\"a2a_call\",\"customer\":\"", customer, "\",\"stall\":\"", session.peer_name, "\",\"skill\":\"query_stock\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "query_stock", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let _p1 := io.print(str.concat("  LLM ← ", body))
        let _ev1 := post_event(dash, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"", customer, "\",\"stall\":\"", session.peer_name, "\",\"skill\":\"query_stock\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let _p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let _p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_reserve_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, customer :: Str) -> t.Tool {
  t.define("reserve_item", "Reserve an item by ID. Returns {status:\"reserved\"} or {status:\"already_reserved\"}.", reserve_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let item_id := match jv.get_field(args, "item_id") { Some(JStr(v)) => v, _ => "" }
    let args_json := str.join(["{\"item_id\":\"", item_id, "\"}"], "")
    let _p0 := io.print(str.concat("  LLM → reserve_item(item_id=\"", str.concat(item_id, "\")")))
    let _ev0 := post_event(dash, str.join(["{\"kind\":\"a2a_call\",\"customer\":\"", customer, "\",\"stall\":\"", session.peer_name, "\",\"skill\":\"reserve_item\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "reserve_item", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let _p1 := io.print(str.concat("  LLM ← ", body))
        let _ev1 := post_event(dash, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"", customer, "\",\"stall\":\"", session.peer_name, "\",\"skill\":\"reserve_item\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let _p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let _p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_complete_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, customer :: Str) -> t.Tool {
  t.define("complete_sale", "Finalise purchase. Returns {status:\"sold\"} on success.", complete_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let item_id := match jv.get_field(args, "item_id") { Some(JStr(v)) => v, _ => "" }
    let payment := match jv.get_field(args, "payment") { Some(JInt(n)) => n, _ => 0 }
    let args_json := str.join(["{\"item_id\":\"", item_id, "\",\"payment\":", int.to_str(payment), "}"], "")
    let _p0 := io.print(str.join(["  LLM → complete_sale(item_id=\"", item_id, "\", payment=", int.to_str(payment), ")"], ""))
    let _ev0 := post_event(dash, str.join(["{\"kind\":\"a2a_call\",\"customer\":\"", customer, "\",\"stall\":\"", session.peer_name, "\",\"skill\":\"complete_sale\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "complete_sale", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let _p1 := io.print(str.concat("  LLM ← ", body))
        let _ev1 := post_event(dash, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"", customer, "\",\"stall\":\"", session.peer_name, "\",\"skill\":\"complete_sale\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let _p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let _p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
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

fn extract_reasoning(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDelta(dl) => match dl { TextChunk(s) => str.concat(acc, s), _ => acc },
      _ => acc,
    }
  })
}

fn emit_step_events(steps :: List[d.Step], stall_name :: Str, dash :: Str, customer :: Str) -> [net] Unit {
  let _r := list.fold(steps, (), fn (_ :: Unit, step :: d.Step) -> [net] Unit {
    match step {
      StepToolExec(name, _) => {
        let _p := post_event(dash, str.join(["{\"kind\":\"llm_tool\",\"customer\":\"", customer, "\",\"stall\":\"", stall_name, "\",\"tool\":\"", name, "\"}"], ""))
        ()
      },
      _ => (),
    }
  })
  ()
}

# ── Result parsing ────────────────────────────────────────────────────────────
# The LLM is instructed to end with one of:
#   RESULT:SOLD:ITEM_NAME:PRICE
#   RESULT:ALREADY_RESERVED
#   RESULT:NOT_FOUND
fn parse_llm_result(text :: Str) -> baz.TxResult {
  let lines := str.split(text, "\n")
  let result_line := list.fold(lines, "", fn (acc :: Str, line :: Str) -> Str {
    let trimmed := str.trim(line)
    if str.contains(trimmed, "RESULT:") { trimmed } else { acc }
  })
  if str.contains(result_line, "RESULT:NOT_FOUND") {
    NotFound
  } else {
    if str.contains(result_line, "RESULT:ALREADY_RESERVED") {
      AlreadyReserved
    } else {
      match str.strip_prefix(result_line, "RESULT:SOLD:") {
        None => NotFound,
        Some(rest) => {
          let parts := str.split(rest, ":")
          let rev_parts := list.reverse(parts)
          let price_str := match list.head(rev_parts) { Some(p) => str.trim(p), None => "0" }
          let price := match str.to_int(price_str) { Some(n) => n, None => 0 }
          let name_parts := list.reverse(list.tail(rev_parts))
          let name := str.join(name_parts, ":")
          Sold({ id: "llm-item", name: name, category: "unknown", price: price })
        },
      }
    }
  }
}

# ── LLM shopping agent ────────────────────────────────────────────────────────
# goal             — free-form natural-language goal (e.g. "Find a bowl ≤ 15 cr")
# ask_human_enabled — adds the generic ask_human tool when true
fn shop_with_llm(stall :: baz.StallInfo, goal :: Str, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now_ms :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str, customer :: Str, ask_human_enabled :: Bool) -> [net, sql, time, llm, io, proc] (baz.TxResult, Str, List[Str]) {
  let blob := { endpoint: stall.url, ephemeral_token: "bazaar-token", peer_pubkey: stall.pubkey_b64, nonce: str.concat("n-llm-", str.concat(customer, stall.name)), expires_at: now_ms + 300000 }
  match audit.run_audited(blob, policy, now_ms, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, str.concat("llm-", stall.name), now_ms + 60000) {
      None => (TxDenied("handshake failed"), p1, used2),
      Some(session) => {
        let _think := post_event(dash, str.join(["{\"kind\":\"llm_think\",\"customer\":\"", customer, "\",\"stall\":\"", stall.name, "\"}"], ""))
        let _pio := io.print(str.join(["  [", customer, " @ LLM] reasoning at ", stall.name, " ..."], ""))

        let base_tools := [make_query_tool(session, now_ms, dash, customer), make_reserve_tool(session, now_ms, dash, customer), make_complete_tool(session, now_ms, dash, customer)]
        let tools := if ask_human_enabled {
          list.concat(base_tools, [human.make_ask_human_tool(dash, customer)])
        } else {
          base_tools
        }

        let ask_hint := if ask_human_enabled { " If you face a genuine choice or need operator guidance, call ask_human." } else { "" }
        let system_goal := str.join([
          "You are a shopping robot visiting ", stall.name, ". Goal: ", goal, ".", ask_hint,
          " Step 1: call query_stock to find items that match the goal (pick a search keyword and infer a max_price from the goal).",
          " Step 2: if found, call reserve_item with the item's id.",
          " Step 3: call complete_sale with the item's id and price as payment.",
          " If no item matches, stop immediately. Do not guess item IDs.",
          " After completing (success or failure), output EXACTLY one of:\n",
          "RESULT:SOLD:ITEM_NAME:PRICE\n",
          "RESULT:NOT_FOUND\n",
          "RESULT:ALREADY_RESERVED\n",
          "where ITEM_NAME is the actual name returned by query_stock and PRICE is the integer price."
        ], "")

        let conversation := [UserMsg(str.join(["Visit ", stall.name, ". Goal: ", goal], ""))]
        let agent := llm_agent.make_agent(stall.name, system_goal, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let _evs := emit_step_events(steps, stall.name, dash, customer)
        let done_text := extract_done_text(steps)
        let _lrt := post_event(dash, str.join(["{\"kind\":\"llm_text\",\"customer\":\"", customer, "\",\"stall\":\"", stall.name, "\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        let tx := parse_llm_result(done_text)
        (tx, p1, used2)
      },
    },
  }
}
