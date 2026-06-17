# examples/trading_demo.lex — Robot Trading Floor demo: 4 traders, 3 markets.
#
# Four robot traders (Axon, Byte, Coil, Dusk) each visit three commodity
# exchanges sequentially. Each trader starts with a 500 cr budget and uses
# an LLM to decide whether to get a quote, place a bid (buy), or place an
# ask (sell). The A2A grant layer enforces every interaction.
#
# Market layout:
#   :8901  Quantum Chips Exchange   — quantum computing components
#   :8902  Solar Energy Markets     — renewable energy credits
#   :8903  Water Credits Trading    — water rights and credits
#
# Traders (sequential):
#   Axon  — visits all 3 markets
#   Byte  — visits all 3 markets
#   Coil  — visits all 3 markets
#   Dusk  — visits all 3 markets
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

# ── Market secrets ─────────────────────────────────────────────────────────────
fn quantum_secret() -> Bytes { bytes.from_str("t1000000000000000000000000000001") }
fn solar_secret()   -> Bytes { bytes.from_str("t2000000000000000000000000000002") }
fn water_secret()   -> Bytes { bytes.from_str("t3000000000000000000000000000003") }

# ── Skill lists ────────────────────────────────────────────────────────────────
fn pub_skills() -> List[card.AgentSkill] {
  [{ name: "get_quote", description: "Get current market price quote for an asset" }]
}

fn ext_skills() -> List[card.AgentSkill] {
  [
    { name: "get_quote", description: "Get current market price quote for an asset" },
    { name: "place_bid", description: "Place a buy order for an asset" },
    { name: "place_ask", description: "Place a sell order for an asset" },
  ]
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

# ── Stall setup helper ─────────────────────────────────────────────────────────
fn setup_market(url :: Str, name :: Str, secret :: Bytes) -> [net, io] Result[baz.StallInfo, Str] {
  match baz.setup_seller(url, name, secret, pub_skills(), ext_skills()) {
    Err(e) => Err(str.join(["setup ", name, ": ", e], "")),
    Ok(pub_b64) => {
      let _p := io.print(str.join(["   ", name, "  pubkey=", str.slice(pub_b64, 0, 16), "..."], ""))
      Ok({ url: url, name: name, pubkey_b64: pub_b64 })
    },
  }
}

# ── Tool parameter schemas ─────────────────────────────────────────────────────
fn quote_params() -> s.ModelSchema {
  { title: "get_quote_params", description: "Get a price quote for an asset", fields: [s.required_str("asset", [])] }
}

fn bid_params() -> s.ModelSchema {
  { title: "place_bid_params", description: "Place a buy bid for an asset", fields: [s.required_str("asset", []), s.required_int("quantity", []), s.required_int("max_price", [])] }
}

fn ask_params() -> s.ModelSchema {
  { title: "place_ask_params", description: "Place a sell ask for an asset", fields: [s.required_str("asset", []), s.required_int("quantity", []), s.required_int("min_price", [])] }
}

fn skill_err(why :: Str) -> e.Errors {
  [{ path: "", code: "skill_failed", message: why }]
}

# ── Tool builders ──────────────────────────────────────────────────────────────
fn make_quote_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, trader :: Str) -> t.Tool {
  t.define("get_quote", "Get current market price quote for an asset. Returns {asset, bid_price, ask_price, volume}.", quote_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let asset := match jv.get_field(args, "asset") { Some(JStr(v)) => v, _ => "" }
    let args_json := str.join(["{\"asset\":\"", asset, "\"}"], "")
    let _p0 := io.print(str.join(["  LLM → get_quote(asset=\"", asset, "\")"], ""))
    let _ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"trader\":\"", trader, "\",\"market\":\"", session.peer_name, "\",\"skill\":\"get_quote\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "get_quote", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let _p1 := io.print(str.concat("  LLM ← ", body))
        let _ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"trader\":\"", trader, "\",\"market\":\"", session.peer_name, "\",\"skill\":\"get_quote\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let _p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let _p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_bid_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, trader :: Str) -> t.Tool {
  t.define("place_bid", "Place a buy order for an asset. Returns {status, order_id, filled_qty, fill_price} or {status:\"rejected\"}.", bid_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let asset := match jv.get_field(args, "asset") { Some(JStr(v)) => v, _ => "" }
    let quantity := match jv.get_field(args, "quantity") { Some(JInt(n)) => n, _ => 0 }
    let max_price := match jv.get_field(args, "max_price") { Some(JInt(n)) => n, _ => 0 }
    let args_json := str.join(["{\"asset\":\"", asset, "\",\"quantity\":", int.to_str(quantity), ",\"max_price\":", int.to_str(max_price), "}"], "")
    let _p0 := io.print(str.join(["  LLM → place_bid(asset=\"", asset, "\", quantity=", int.to_str(quantity), ", max_price=", int.to_str(max_price), ")"], ""))
    let _ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"trader\":\"", trader, "\",\"market\":\"", session.peer_name, "\",\"skill\":\"place_bid\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "place_bid", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let _p1 := io.print(str.concat("  LLM ← ", body))
        let _ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"trader\":\"", trader, "\",\"market\":\"", session.peer_name, "\",\"skill\":\"place_bid\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let _p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let _p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
    }
  })
}

fn make_ask_tool(session :: sess.PeerSession, now_ms :: Int, dash :: Str, trader :: Str) -> t.Tool {
  t.define("place_ask", "Place a sell order for an asset. Returns {status, order_id, filled_qty, fill_price} or {status:\"rejected\"}.", ask_params(), fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let asset := match jv.get_field(args, "asset") { Some(JStr(v)) => v, _ => "" }
    let quantity := match jv.get_field(args, "quantity") { Some(JInt(n)) => n, _ => 0 }
    let min_price := match jv.get_field(args, "min_price") { Some(JInt(n)) => n, _ => 0 }
    let args_json := str.join(["{\"asset\":\"", asset, "\",\"quantity\":", int.to_str(quantity), ",\"min_price\":", int.to_str(min_price), "}"], "")
    let _p0 := io.print(str.join(["  LLM → place_ask(asset=\"", asset, "\", quantity=", int.to_str(quantity), ", min_price=", int.to_str(min_price), ")"], ""))
    let _ev0 := post_ui(dash, str.join(["{\"kind\":\"a2a_call\",\"trader\":\"", trader, "\",\"market\":\"", session.peer_name, "\",\"skill\":\"place_ask\",\"args\":", args_json, "}"], ""))
    match sess.invoke_skill(session, { skill: "place_ask", args_json: args_json }, now_ms) {
      (SkillOk(body), _) => {
        let _p1 := io.print(str.concat("  LLM ← ", body))
        let _ev1 := post_ui(dash, str.join(["{\"kind\":\"a2a_resp\",\"trader\":\"", trader, "\",\"market\":\"", session.peer_name, "\",\"skill\":\"place_ask\",\"ok\":true,\"body\":", body, "}"], ""))
        Ok(JStr(body))
      },
      (SkillDenied(why), _) => { let _p2 := io.print(str.concat("  LLM ← denied: ", why)); Err(skill_err(why)) },
      (SkillFailed(why), _) => { let _p3 := io.print(str.concat("  LLM ← failed: ", why)); Err(skill_err(why)) },
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

fn emit_step_events(steps :: List[d.Step], market_name :: Str, dash :: Str, trader :: Str) -> [net] Unit {
  let _r := list.fold(steps, (), fn (_ :: Unit, step :: d.Step) -> [net] Unit {
    match step {
      StepToolExec(name, _) => {
        let _p := post_ui(dash, str.join(["{\"kind\":\"llm_tool\",\"trader\":\"", trader, "\",\"market\":\"", market_name, "\",\"tool\":\"", name, "\"}"], ""))
        ()
      },
      _ => (),
    }
  })
  ()
}

# ── Result parsing ─────────────────────────────────────────────────────────────
# The LLM is instructed to end with one of:
#   RESULT:BOUGHT:ASSET:QTY:PRICE
#   RESULT:SOLD:ASSET:QTY:PRICE
#   RESULT:NO_TRADE
type TradeResult = Bought(Str, Int, Int) | TradeComplete(Str, Int, Int) | NoTrade

fn parse_bought(rest :: Str) -> TradeResult {
  let parts := str.split(rest, ":")
  let rev_parts := list.reverse(parts)
  let price_str := match list.head(rev_parts) { Some(p) => str.trim(p), None => "0" }
  let qty_str := match list.head(list.tail(rev_parts)) { Some(p) => str.trim(p), None => "0" }
  let asset_parts := list.reverse(list.tail(list.tail(rev_parts)))
  let asset := str.join(asset_parts, ":")
  let qty := match str.to_int(qty_str) { Some(n) => n, None => 0 }
  let price := match str.to_int(price_str) { Some(n) => n, None => 0 }
  Bought(asset, qty, price)
}

fn parse_sold(rest :: Str) -> TradeResult {
  let parts := str.split(rest, ":")
  let rev_parts := list.reverse(parts)
  let price_str := match list.head(rev_parts) { Some(p) => str.trim(p), None => "0" }
  let qty_str := match list.head(list.tail(rev_parts)) { Some(p) => str.trim(p), None => "0" }
  let asset_parts := list.reverse(list.tail(list.tail(rev_parts)))
  let asset := str.join(asset_parts, ":")
  let qty := match str.to_int(qty_str) { Some(n) => n, None => 0 }
  let price := match str.to_int(price_str) { Some(n) => n, None => 0 }
  TradeComplete(asset, qty, price)
}

fn parse_trade_result(text :: Str) -> TradeResult {
  let lines := str.split(text, "\n")
  let result_line := list.fold(lines, "", fn (acc :: Str, line :: Str) -> Str {
    let trimmed := str.trim(line)
    if str.contains(trimmed, "RESULT:") { trimmed } else { acc }
  })
  if str.contains(result_line, "RESULT:NO_TRADE") {
    NoTrade
  } else {
    if str.contains(result_line, "RESULT:BOUGHT:") {
      match str.strip_prefix(result_line, "RESULT:BOUGHT:") {
        None => NoTrade,
        Some(rest) => parse_bought(rest),
      }
    } else {
      if str.contains(result_line, "RESULT:SOLD:") {
        match str.strip_prefix(result_line, "RESULT:SOLD:") {
          None => NoTrade,
          Some(rest) => parse_sold(rest),
        }
      } else {
        NoTrade
      }
    }
  }
}

fn trade_result_str(tr :: TradeResult) -> Str {
  match tr {
    Bought(asset, qty, price) => str.join(["BOUGHT ", asset, " x", int.to_str(qty), " @ ", int.to_str(price), " cr"], ""),
    TradeComplete(asset, qty, price) => str.join(["SOLD ", asset, " x", int.to_str(qty), " @ ", int.to_str(price), " cr"], ""),
    NoTrade => "NO_TRADE",
  }
}

# ── Generic trader function ────────────────────────────────────────────────────
# Runs one trader at one market via LLM-driven tool loop.
# Returns (result_str, new_parent, new_used).
fn run_trader(trader :: Str, market :: baz.StallInfo, budget :: Int, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str) -> [net, sql, time, llm, io, proc] (Str, Str, List[Str]) {
  let nonce := str.concat("n-", str.concat(trader, market.name))
  let session_name := str.concat(trader, "-session")
  let blob := { endpoint: market.url, ephemeral_token: "trading-token", peer_pubkey: market.pubkey_b64, nonce: nonce, expires_at: now + 300000 }
  let _think := post_ui(dash, str.join(["{\"kind\":\"llm_think\",\"trader\":\"", trader, "\",\"market\":\"", market.name, "\"}"], ""))
  let _pio := io.print(str.join(["  [", trader, " @ LLM] reasoning at ", market.name, " ..."], ""))
  match audit.run_audited(blob, policy, now, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, session_name, now + 60000) {
      None => ("NO_TRADE:handshake_failed", p1, used2),
      Some(session) => {
        let tools := [make_quote_tool(session, now, dash, trader), make_bid_tool(session, now, dash, trader), make_ask_tool(session, now, dash, trader)]
        let system_prompt := str.join([
          "You are ", trader, ", a robot trader. Budget: ", int.to_str(budget), " credits.",
          " Visit ", market.name, ".",
          " Call get_quote to see prices, then place_bid to buy or place_ask to sell if profitable.",
          " End with: RESULT:BOUGHT:ASSET:QTY:PRICE or RESULT:SOLD:ASSET:QTY:PRICE or RESULT:NO_TRADE"
        ], "")
        let conversation := [UserMsg(str.join(["Visit ", market.name, ". Budget: ", int.to_str(budget), " credits. Assess the market and trade if profitable."], ""))]
        let agent := llm_agent.make_agent(market.name, system_prompt, model, provider, tools, llm_agent.default_options())
        let steps := iter.to_list(llm_agent.run_loop(agent, conversation))
        let _evs := emit_step_events(steps, market.name, dash, trader)
        let done_text := extract_done_text(steps)
        let _lrt := post_ui(dash, str.join(["{\"kind\":\"llm_text\",\"trader\":\"", trader, "\",\"market\":\"", market.name, "\",\"text\":\"", json_esc(done_text), "\"}"], ""))
        let trade_res := parse_trade_result(done_text)
        let res_str := trade_result_str(trade_res)
        let _evr := post_ui(dash, str.join(["{\"kind\":\"trade_result\",\"trader\":\"", trader, "\",\"market\":\"", market.name, "\",\"result\":\"", res_str, "\"}"], ""))
        let _pr := io.print(str.join(["  [", trader, " @ ", market.name, "] ", res_str], ""))
        (res_str, p1, used2)
      },
    },
  }
}

# ── Trader state for fold ──────────────────────────────────────────────────────
type TraderState = { parent :: Str, used :: List[Str] }

# ── Entry point ────────────────────────────────────────────────────────────────
fn run() -> [net, io, sql, fs_write, sense, time, env, llm, proc] Unit {
  let trail_path := "/tmp/lex-trading-demo.db"
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

  let _p1 := io.print("══════════════════════════════════════════════════════")
  let _p2 := io.print("   ROBOT TRADING FLOOR  —  4 traders, 3 markets")
  let _p3 := io.print("   Axon  Byte  Coil  Dusk  — 500 cr each")
  let _p4 := io.print("   Markets: Quantum Chips, Solar Energy, Water Credits")
  let _p5 := io.print("   Dashboard: http://localhost:8900")
  let _p6 := io.print("══════════════════════════════════════════════════════")

  let _ui0 := post_ui(dash, "{\"kind\":\"start\",\"traders\":[\"Axon\",\"Byte\",\"Coil\",\"Dusk\"],\"markets\":3}")

  match tlog.open(trail_path) {
    Err(e) => io.print(str.concat("[trading] trail: ", e)),
    Ok(log) => {
      match tlog.append(log, "trading_start", None, "{}") {
        Err(e) => io.print(str.concat("[trading] trail root: ", e)),
        Ok(root) => {
          let now := time.now_ms()
          let policy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 30, max_budget_ms: 120000 }
          let budget := 500

          let _ps := io.print("[trading] setting up 3 markets ...")
          match setup_market("http://localhost:8901", "Quantum Chips Exchange", quantum_secret()) {
            Err(e) => io.print(e),
            Ok(quantum) => {
              match setup_market("http://localhost:8902", "Solar Energy Markets", solar_secret()) {
                Err(e) => io.print(e),
                Ok(solar) => {
                  match setup_market("http://localhost:8903", "Water Credits Trading", water_secret()) {
                    Err(e) => io.print(e),
                    Ok(water) => {
                      let _sl0 := time.sleep_ms(1000)
                      let markets := [quantum, solar, water]
                      let traders := ["Axon", "Byte", "Coil", "Dusk"]
                      let init_state := { parent: root.id, used: [] }

                      let _final := list.fold(traders, init_state, fn (tstate :: TraderState, trader :: Str) -> [net, sql, time, llm, io, proc] TraderState {
                        let _ts := post_ui(dash, str.join(["{\"kind\":\"trader_start\",\"trader\":\"", trader, "\"}"], ""))
                        let _tp := io.print(str.join(["── ", trader, " entering the floor ──────────────────────────────"], ""))
                        let market_state := list.fold(markets, tstate, fn (mstate :: TraderState, market :: baz.StallInfo) -> [net, sql, time, llm, io, proc] TraderState {
                          let _uiv := post_ui(dash, str.join(["{\"kind\":\"visit\",\"trader\":\"", trader, "\",\"market\":\"", market.name, "\"}"], ""))
                          let _vi := io.print(str.join(["  [", trader, "] → ", market.name], ""))
                          let _slv := time.sleep_ms(1500)
                          match run_trader(trader, market, budget, policy, log, mstate.parent, mstate.used, now, provider, model, dash) {
                            (res, p2, used2) => {
                              let _sl := time.sleep_ms(1000)
                              { parent: p2, used: used2 }
                            },
                          }
                        })
                        let _td := post_ui(dash, str.join(["{\"kind\":\"trader_done\",\"trader\":\"", trader, "\"}"], ""))
                        let _tf := io.print(str.join(["── ", trader, " done ──────────────────────────────────────────────"], ""))
                        market_state
                      })

                      let _done := post_ui(dash, "{\"kind\":\"done\"}")
                      let _pf1 := io.print("══════════════════════════════════════════════════════")
                      io.print("   TRADING FLOOR COMPLETE  —  check http://localhost:8900")
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
