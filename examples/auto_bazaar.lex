# examples/auto_bazaar.lex — Autonomous shopping robot with full A2A handshake.
#
# Three-phase flow:
#   1. DISCOVER  — call scan_area on the dashboard sidecar to find stalls.
#   2. HANDSHAKE — for each stall, fetch its BootstrapBlob (stored by the stall
#                  at startup via register_bootstrap) then run the full A2A
#                  handshake: public-card fetch → Ed25519 verify → consent →
#                  extended-card fetch → verify → open PeerSession.
#   3. SHOP      — LLM agent equipped with A2A-backed query_stock_at and
#                  purchase_at tools.  Every call is grant-checked by the session.
#
# Robots start with NO prior knowledge of each other.  The stalls register their
# bootstrap blobs at startup so the customer can discover and verify them without
# any out-of-band key distribution.
#
# Env vars:
#   SIDECAR_URL            dashboard sidecar (default http://localhost:8900)
#   AUTO_ITEM              item to search for (default "Bowl")
#   AUTO_QTY               how many to buy    (default 2)
#   AUTO_BUDGET            credit ceiling      (default 50)
#   VERTEX_ACCESS_TOKEN / VERTEX_PROJECT / VERTEX_LOCATION
#
# Run via examples/auto_bazaar_run.sh

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.float" as float
import "std.list"  as list
import "std.iter"  as iter
import "std.bytes" as bytes
import "std.http"  as http
import "std.map"   as map
import "std.time"  as time

import "lex-llm/src/agent"            as llm_agent
import "lex-llm/src/tool"             as t
import "lex-llm/src/message"          as msg
import "lex-llm/src/delta"            as d
import "lex-llm/src/providers/vertex" as vtx

import "lex-schema/schema"     as s
import "lex-schema/json_value" as jv
import "lex-schema/error"      as e

import "../src/human_goal"    as hgoal

import "../src/a2a_bootstrap" as boot
import "../src/a2a_handshake" as hs
import "../src/a2a_session"   as sess
import "../src/a2a_consent"   as consent
import "../src/a2a_card"      as card

# ── HTTP helpers ──────────────────────────────────────────────────────────────

fn http_err_str(err :: HttpError) -> Str {
  match err {
    TimeoutError    => "timeout",
    TlsError(m)     => str.concat("tls: ", m),
    NetworkError(m) => m,
    DecodeError(m)  => m,
  }
}

fn call_sidecar(base_url :: Str, skill :: Str, body :: Str) -> [net] Str {
  let url := str.join([base_url, "/skill/", skill], "")
  let req0 := { method: "POST", url: url, headers: map.new(),
                body: Some(bytes.from_str(body)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 20000), "Content-Type", "application/json")
  match http.send(req) {
    Err(err) => str.join(["{\"error\":\"", http_err_str(err), "\"}"], ""),
    Ok(r)    => match bytes.to_str(r.body) {
      Err(_) => "{\"error\":\"bad-utf8\"}",
      Ok(s)  => s,
    },
  }
}

fn http_get(url :: Str) -> [net] Str {
  let req0 := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: None }
  let req := http.with_timeout_ms(req0, 10000)
  match http.send(req) {
    Err(err) => str.join(["{\"error\":\"", http_err_str(err), "\"}"], ""),
    Ok(r)    => match bytes.to_str(r.body) {
      Err(_) => "{\"error\":\"bad-utf8\"}",
      Ok(s)  => s,
    },
  }
}

fn json_str(s :: Str) -> Str {
  str.concat("\"", str.concat(str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\""))
}

fn notify_auto(dash_url :: Str, json :: Str) -> [net] Unit {
  if str.is_empty(dash_url) { () } else {
    let url := str.concat(dash_url, "/event")
    let req0 := { method: "POST", url: url, headers: map.new(),
                  body: Some(bytes.from_str(json)), timeout_ms: None }
    let req := http.with_header(http.with_timeout_ms(req0, 1000), "Content-Type", "application/json")
    let _ := http.send(req)
    ()
  }
}

# Map stall name → its base URL (must match auto_bazaar_run.sh port assignments).
fn stall_url(stall_name :: Str) -> Str {
  if stall_name == "pottery" or stall_name == "clay"    { "http://localhost:8901" } else {
  if stall_name == "textile" or stall_name == "fabric"  { "http://localhost:8902" } else {
  if stall_name == "spices"  or stall_name == "herb"    { "http://localhost:8903" } else {
  "" }}}
}

# ── Stall discovery ───────────────────────────────────────────────────────────

fn parse_stall_names(scan_result :: Str) -> List[Str] {
  let parts := list.tail(str.split(scan_result, "\"name\":\""))
  list.fold(parts, [], fn (acc :: List[Str], part :: Str) -> List[Str] {
    let name := match list.head(str.split(part, "\"")) { Some(n) => n, None => "" }
    if str.is_empty(name) { acc } else { list.concat(acc, [name]) }
  })
}

# ── A2A bootstrap + handshake ─────────────────────────────────────────────────

fn extract_blob_b64(resp :: Str) -> Str {
  match list.head(list.tail(str.split(resp, "\"blob\":\""))) {
    None     => "",
    Some(rest) => match list.head(str.split(rest, "\"")) { Some(v) => v, None => "" },
  }
}

# Read a numeric JSON field as a string (handles Int or Float).
fn jnum_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(v) => match jv.as_float(v) { Some(f) => float.to_str(f), None => "0" },
    None    => "0",
  }
}

# Emit the robot's REAL physics position (parsed from a move_to result) so the
# dashboard places the sprite where the robot actually is — physical presence,
# not a timed guess.
fn emit_pos(dash :: Str, result :: Str) -> [net] Unit {
  match jv.parse_into_errors(result) {
    Err(_) => (),
    Ok(j)  => match jv.get_field(j, "pos") {
      None    => (),
      Some(p) => notify_auto(dash, str.join(["{\"kind\":\"pos\",\"customer\":\"robot\",\"x\":", jnum_str(p, "x"), ",\"y\":", jnum_str(p, "y"), "}"], "")),
    },
  }
}

# Physically drive the robot to a stall via the physics server, then publish its
# real position. Returns the move_to result body.
fn walk_to(base_url :: Str, dash :: Str, stall_name :: Str) -> [net, io] Str {
  let _ := io.print(str.join(["  [robot] walking to ", stall_name, " ..."], ""))
  let result := call_sidecar(base_url, "move_to", str.join(["{\"stall\":", json_str(stall_name), "}"], ""))
  let _ := emit_pos(dash, result)
  result
}

fn do_handshake(stall_name :: Str, policy :: consent.ConsentPolicy, now_ms :: Int, dash_url :: Str) -> [net, io] Option[sess.PeerSession] {
  let endpoint := stall_url(stall_name)
  if str.is_empty(endpoint) {
    let _ := io.print(str.join(["    [hs] ", stall_name, ": no known endpoint"], ""))
    None
  } else {
    let blob_url := str.concat(endpoint, "/a2a/bootstrap-blob")
    let resp := http_get(blob_url)
    let _ := io.print(str.join(["    [hs] ", stall_name, ": blob-resp=", str.slice(resp, 0, 120)], ""))
    let b64  := extract_blob_b64(resp)
    if str.is_empty(b64) {
      let _ := io.print(str.join(["    [hs] ", stall_name, ": b64 empty — blob not stored?"], ""))
      None
    } else {
      # The robot had NO prior knowledge of this stall's key. The bootstrap blob
      # it just received IS the entire meeting handshake — render it as a QR so
      # the "strangers exchanging one artifact" property is visible on screen.
      let _qr := notify_auto(dash_url, str.join(["{\"kind\":\"qr_meet\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"blob\":", json_str(b64), "}"], ""))
      match boot.decode(b64) {
        Err(e) => {
          let _ := io.print(str.join(["    [hs] ", stall_name, ": decode error: ", e], ""))
          None
        },
        Ok(blob) => {
          let result := sess.open_session(hs.run(blob, policy, now_ms), stall_name, now_ms + 300000)
          let tag := match result { Some(_) => "session-ok", None => "session-none" }
          let _ := io.print(str.join(["    [hs] ", stall_name, ": ", tag], ""))
          result
        },
      }
    }
  }
}

# ── Session registry ──────────────────────────────────────────────────────────

type StallConn = { stall :: Str, session :: Option[sess.PeerSession] }

fn find_session(conns :: List[StallConn], stall :: Str) -> Option[sess.PeerSession] {
  list.fold(conns, None, fn (acc :: Option[sess.PeerSession], c :: StallConn) -> Option[sess.PeerSession] {
    match acc {
      Some(_) => acc,
      None    => if c.stall == stall { c.session } else { None },
    }
  })
}

# ── Tool definitions ──────────────────────────────────────────────────────────

fn make_move_tool(base_url :: Str, dash_url :: Str) -> t.Tool {
  t.define("move_to",
    "Navigate the robot to a named stall. Use the exact stall name (e.g. \"pottery\", \"textile\", \"spices\").",
    { title: "move_to_params", description: "Stall to navigate to", fields: [s.required_str("stall", [])] },
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      let stall_name := match jv.get_field(args, "stall") { Some(JStr(v)) => v, _ => "" }
      let _ := notify_auto(dash_url, str.join(["{\"kind\":\"llm_tool\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"tool\":\"move_to\"}"], ""))
      let _ := notify_auto(dash_url, str.join(["{\"kind\":\"visit\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), "}"], ""))
      let _ := io.print(str.join(["  [robot] → move_to(stall=\"", stall_name, "\")"], ""))
      let body := str.join(["{\"stall\":\"", stall_name, "\"}"], "")
      let result := call_sidecar(base_url, "move_to", body)
      let _ := emit_pos(dash_url, result)
      let _ := io.print(str.concat("  [robot] ← ", result))
      match jv.parse_into_errors(result) {
        Ok(j)  => Ok(j),
        Err(_) => Ok(JStr(result)),
      }
    })
}

fn make_query_tool(conns :: List[StallConn], now_ms :: Int) -> t.Tool {
  t.define("query_stock_at",
    "Search a specific stall's inventory via A2A session. Returns {found:1,id,name,price} or {found:0}.",
    { title: "query_at_params", description: "Query stock at a named stall", fields: [
        s.required_str("stall", []),
        s.required_str("search", []),
        s.required_float("max_price", [])
      ] },
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      let stall_name := match jv.get_field(args, "stall") { Some(JStr(v)) => v, _ => "" }
      let search     := match jv.get_field(args, "search") { Some(JStr(v)) => v, _ => "" }
      let max_price  := match jv.get_field(args, "max_price") { Some(JFloat(f)) => float.to_int(f), Some(JInt(n)) => n, _ => 9999 }
      let _ := io.print(str.join(["  [robot A2A] → query_stock_at(stall=\"", stall_name, "\", search=\"", search, "\", max_price=", int.to_str(max_price), ")"], ""))
      match find_session(conns, stall_name) {
        None => {
          let _ := io.print(str.concat("  [robot A2A] ← no A2A session for: ", stall_name))
          Ok(JObj([("stall", JStr(stall_name)), ("found", JInt(0)), ("error", JStr("no-session"))]))
        },
        Some(session) => {
          let args_json := str.join(["{\"search\":\"", search, "\",\"max_price\":", int.to_str(max_price), "}"], "")
          match sess.invoke_skill(session, { skill: "query_stock", args_json: args_json }, now_ms) {
            (SkillOk(body), _) => {
              let _ := io.print(str.concat("  [robot A2A] ← ", body))
              match jv.parse_into_errors(body) {
                Ok(j)  => Ok(j),
                Err(_) => Ok(JObj([("stall", JStr(stall_name)), ("found", JInt(0)), ("error", JStr("bad-json"))])),
              }
            },
            (SkillDenied(why), _) => {
              let _ := io.print(str.concat("  [robot A2A] ← denied: ", why))
              Ok(JObj([("stall", JStr(stall_name)), ("found", JInt(0)), ("error", JStr(str.concat("denied: ", why)))]))
            },
            (SkillFailed(why), _) => {
              let _ := io.print(str.concat("  [robot A2A] ← failed: ", why))
              Ok(JObj([("stall", JStr(stall_name)), ("found", JInt(0)), ("error", JStr(str.concat("failed: ", why)))]))
            },
          }
        },
      }
    })
}

fn make_purchase_tool(conns :: List[StallConn], now_ms :: Int, dash_url :: Str) -> t.Tool {
  t.define("purchase_at",
    "Purchase an item from a stall via A2A (reserve then complete). Use item_id and price from query_stock_at. Payment must equal the item price.",
    { title: "purchase_params", description: "Buy an item from a named stall", fields: [
        s.required_str("stall", []),
        s.required_str("item_id", []),
        s.required_float("payment", [])
      ] },
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      let stall_name := match jv.get_field(args, "stall")   { Some(JStr(v)) => v, _ => "" }
      let item_id    := match jv.get_field(args, "item_id") { Some(JStr(v)) => v, _ => "" }
      let payment    := match jv.get_field(args, "payment") { Some(JFloat(f)) => float.to_int(f), Some(JInt(n)) => n, _ => 0 }
      let _ := notify_auto(dash_url, str.join(["{\"kind\":\"llm_tool\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"tool\":\"purchase_at\"}"], ""))
      let _ := io.print(str.join(["  [robot A2A] → purchase_at(stall=\"", stall_name, "\", item_id=\"", item_id, "\", payment=", int.to_str(payment), ")"], ""))
      match find_session(conns, stall_name) {
        None => {
          let _ := io.print(str.concat("  [robot A2A] ← no A2A session for: ", stall_name))
          Ok(JObj([("outcome", JStr("error")), ("stall", JStr(stall_name)), ("detail", JStr("no-session"))]))
        },
        Some(session) => {
          let rsv_args := str.join(["{\"item_id\":\"", item_id, "\"}"], "")
          let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_call\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"reserve_item\"}"], ""))
          match sess.invoke_skill(session, { skill: "reserve_item", args_json: rsv_args }, now_ms) {
            (SkillDenied(why), _) => {
              let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"reserve_item\",\"ok\":false}"], ""))
              let _ := io.print(str.concat("  [robot A2A] ← reserve denied: ", why))
              Ok(JObj([("outcome", JStr("denied")), ("detail", JStr(why))]))
            },
            (SkillFailed(why), _) => {
              let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"reserve_item\",\"ok\":false}"], ""))
              let _ := io.print(str.concat("  [robot A2A] ← reserve failed: ", why))
              Ok(JObj([("outcome", JStr("failed")), ("detail", JStr(why))]))
            },
            (SkillOk(rsv_body), sess2) => {
              let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"reserve_item\",\"body\":", json_str(rsv_body), ",\"ok\":true}"], ""))
              let _ := io.print(str.concat("  [robot A2A] ← reserve: ", rsv_body))
              if str.contains(rsv_body, "\"reserved\"") {
                let sale_args := str.join(["{\"item_id\":\"", item_id, "\",\"payment\":", int.to_str(payment), "}"], "")
                let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_call\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"complete_sale\"}"], ""))
                match sess.invoke_skill(sess2, { skill: "complete_sale", args_json: sale_args }, now_ms) {
                  (SkillOk(sale_body), _) => {
                    let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"complete_sale\",\"body\":", json_str(sale_body), ",\"ok\":true}"], ""))
                    let _ := notify_auto(dash_url, str.join(["{\"kind\":\"result\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"tx\":\"SOLD ", item_id, " @ ", int.to_str(payment), "cr\"}"], ""))
                    let _ := io.print(str.concat("  [robot A2A] ← sale: ", sale_body))
                    Ok(JObj([("outcome", JStr("purchased")), ("stall", JStr(stall_name)), ("item_id", JStr(item_id)), ("payment", JInt(payment))]))
                  },
                  (SkillDenied(why), _) => {
                    let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"complete_sale\",\"ok\":false}"], ""))
                    Ok(JObj([("outcome", JStr("sale-denied")), ("detail", JStr(why))]))
                  },
                  (SkillFailed(why), _) => {
                    let _ := notify_auto(dash_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"complete_sale\",\"ok\":false}"], ""))
                    Ok(JObj([("outcome", JStr("sale-failed")), ("detail", JStr(why))]))
                  },
                }
              } else {
                Ok(JObj([("outcome", JStr("reserve-failed")), ("detail", JStr(rsv_body))]))
              }
            },
          }
        },
      }
    })
}

# ── Result extraction ─────────────────────────────────────────────────────────

fn extract_done_text(steps :: List[d.Step]) -> [io] Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> [io] Str {
    match step {
      StepDone(m) => match m {
        AssistantMsg(text, _) => {
          let _ := io.print(str.join(["  [step] Done: ", str.slice(text, 0, 120)], ""))
          text
        },
        _ => acc
      },
      StepToolExec(name, id) => {
        let _ := io.print(str.join(["  [step] ToolExec: ", name, " (", id, ")"], ""))
        acc
      },
      StepToolResult(id, success) => {
        let ok := if success { "ok" } else { "error" }
        let _ := io.print(str.join(["  [step] ToolResult(", ok, "): ", id], ""))
        acc
      },
      StepDelta(_) => acc,
      _ => acc,
    }
  })
}

# Query a stall for EVERY item on the shopping list, returning one matrix line
# per item the stall actually carries. This is how the robot gathers full market
# data from each stop before deciding how to distribute its purchases.
fn query_items(session :: sess.PeerSession, items :: List[Str], budget :: Int, stall_name :: Str, base_url :: Str, now_ms :: Int) -> [net, io] List[Str] {
  list.fold(items, [], fn (acc :: List[Str], it0 :: Str) -> [net, io] List[Str] {
    let it := str.trim(it0)
    let args := str.join(["{\"search\":\"", it, "\",\"max_price\":", int.to_str(budget), "}"], "")
    let _ := notify_auto(base_url, str.join(["{\"kind\":\"a2a_call\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"query_stock\"}"], ""))
    match sess.invoke_skill(session, { skill: "query_stock", args_json: args }, now_ms) {
      (SkillOk(body), _) => if str.contains(body, "\"found\":0") {
        acc
      } else {
        let _ := io.print(str.join(["  ← ", stall_name, " has ", it, ": ", body], ""))
        let _ := notify_auto(base_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"query_stock\",\"body\":", json_str(body), ",\"ok\":true}"], ""))
        list.concat(acc, [str.join([stall_name, " has ", it, " -> ", body], "")])
      },
      (SkillDenied(_), _) => acc,
      (SkillFailed(_), _) => acc,
    }
  })
}

# Parse a human goal answer "item1, item2, ...; budget" into (items_csv, budget).
fn parse_goal(ans :: Str, dflt_budget :: Int) -> (Str, Int) {
  if str.is_empty(ans) {
    ("Bowl, Scarf, Saffron", dflt_budget)
  } else {
    let parts := str.split(ans, ";")
    let items_str := match list.head(parts) { Some(s) => str.trim(s), None => ans }
    let budget := match list.head(list.tail(parts)) {
      Some(b) => match str.to_int(str.trim(b)) { Some(n) => n, None => dflt_budget },
      None    => dflt_budget,
    }
    (if str.is_empty(items_str) { "Bowl, Scarf, Saffron" } else { items_str }, budget)
  }
}

# ── Entry point ───────────────────────────────────────────────────────────────

fn run() -> [env, net, io, llm, time, proc] Unit {
  let base_url := match env.get("SIDECAR_URL") { None => "http://localhost:8900", Some(u) => u }
  let env_budget := match env.get("AUTO_BUDGET") { None => 50, Some(v) => match str.to_int(v) { Some(n) => n, None => 50 } }
  # The GOAL is provided by the human, not hardcoded: if AUTO_ITEMS is set (a
  # scripted/headless run) we use it; otherwise we ask the operator through the
  # dashboard and block until they answer (the reusable human-goal pattern).
  let env_items := match env.get("AUTO_ITEMS") { None => "", Some(v) => v }
  let goal_pair := if str.is_empty(env_items) {
    parse_goal(hgoal.ask_goal(base_url, "robot", "What should I shop for? List items comma-separated, then your budget after a ';'.  e.g.  Bowl, Scarf, Saffron; 25"), env_budget)
  } else {
    (env_items, env_budget)
  }
  let items_raw := match goal_pair { (s, _) => s }
  let budget    := match goal_pair { (_, b) => b }
  let items := list.filter(str.split(items_raw, ","), fn (s :: Str) -> Bool { not str.is_empty(str.trim(s)) })
  let item  := match list.head(items) { Some(h) => str.trim(h), None => "Bowl" }
  let token    := match env.get("VERTEX_ACCESS_TOKEN") { None => "", Some(v) => v }
  let project  := match env.get("VERTEX_PROJECT")      { None => "", Some(v) => v }
  let location := match env.get("VERTEX_LOCATION") {
    None    => "eu",
    Some(v) => if str.is_empty(v) { "eu" } else { v },
  }
  let now_ms   := time.now_ms()

  let provider := vtx.make_provider(vtx.config_at(token, project, location))
  let model    := vtx.gemini_35_flash()

  let list_str := str.join(items, ", ")
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print(str.join(["   AUTO BAZAAR  ·  shopping list: ", list_str, "  budget: ", int.to_str(budget), " cr"], ""))
  let _ := io.print("══════════════════════════════════════════════════════")

  let goal_str := str.join(["buy [", list_str, "] across the bazaar (budget: ", int.to_str(budget), "cr)"], "")
  let _ := notify_auto(base_url, str.join(["{\"kind\":\"customer_start\",\"customer\":\"robot\",\"goal\":", json_str(goal_str), "}"], ""))
  # Publish the shopping list so the dashboard can show it being ticked off.
  let items_json := str.join(["[", str.join(list.map(items, fn (s :: Str) -> Str { json_str(str.trim(s)) }), ","), "]"], "")
  let _ := notify_auto(base_url, str.join(["{\"kind\":\"shopping_list\",\"items\":", items_json, ",\"budget\":", int.to_str(budget), "}"], ""))

  # Phase 1: Discover stalls via scan_area
  let _ := io.print("[Phase 1] scanning bazaar ...")
  let scan_result := call_sidecar(base_url, "scan_area", "{}")
  let _ := io.print(str.join(["[Phase 1] scan_area raw: ", str.slice(scan_result, 0, 200)], ""))
  let stall_names := parse_stall_names(scan_result)
  let _ := io.print(str.join(["[Phase 1] stalls visible: ", str.join(stall_names, ", ")], ""))
  # Publish the real world map (robot_pos + each agent's scanned bearing/distance)
  # so the dashboard lays agents out at their TRUE positions, not a fixed grid.
  let _ := notify_auto(base_url, str.join(["{\"kind\":\"world\",\"scan\":", scan_result, "}"], ""))

  # Phase 2+3: physically travel to each stall, then handshake + query there.
  # Presence is real — the robot drives to each agent (physics) before talking,
  # and the dashboard follows its actual position.
  let _ := io.print("[Phase 2] visiting stalls: walk → handshake + query stock ...")
  let policy := {
    allowed_pubkeys: [],
    allowed_skills: [],
    max_tier: card.Extended,
    require_https: false,
    max_budget_actions: 20,
    max_budget_ms: 120000
  }
  let discovery := list.fold(stall_names, ([], []), fn (acc :: (List[StallConn], List[Str]), stall_name :: Str) -> [net, io] (List[StallConn], List[Str]) {
    let prev_conns := match acc { (c, _) => c }
    let prev_lines := match acc { (_, l) => l }
    let _ := io.print(str.join(["  → ", stall_name], ""))
    # Physically walk to the agent FIRST (publishes the robot's real position),
    # then announce presence and handshake at that spot.
    let _ := walk_to(base_url, base_url, stall_name)
    let _ := notify_auto(base_url, str.join(["{\"kind\":\"visit\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), "}"], ""))
    let _ := notify_auto(base_url, str.join(["{\"kind\":\"a2a_call\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"handshake\"}"], ""))
    let session_opt := do_handshake(stall_name, policy, now_ms, base_url)
    let ok_str := match session_opt { Some(_) => "true", None => "false" }
    let _ := notify_auto(base_url, str.join(["{\"kind\":\"a2a_resp\",\"customer\":\"robot\",\"stall\":", json_str(stall_name), ",\"skill\":\"handshake\",\"ok\":", ok_str, "}"], ""))
    let tag := match session_opt { Some(_) => "[OK]", None => "[FAIL]" }
    let _ := io.print(str.join(["  ", tag, " ", stall_name], ""))
    let new_conn := { stall: stall_name, session: session_opt }
    match session_opt {
      None => (list.concat(prev_conns, [new_conn]), prev_lines),
      Some(session) => {
        # Query this stall for EVERY item on the list — gather full market data.
        let lines := query_items(session, items, budget, stall_name, base_url, now_ms)
        (list.concat(prev_conns, [new_conn]), list.concat(prev_lines, lines))
      },
    }
  })
  let conns        := match discovery { (c, _) => c }
  let market_lines := match discovery { (_, l) => l }
  let market_summary := if list.is_empty(market_lines) {
    "No results — all stalls returned nothing."
  } else {
    str.join(market_lines, "\n")
  }
  let _ := io.print(str.join(["[Phase 2] market:\n", market_summary], ""))

  # Phase 3: LLM receives market data and calls move_to + purchase_at.
  let _ := io.print("[Phase 3] launching LLM purchasing agent ...")
  let connected := list.filter(stall_names, fn (s :: Str) -> Bool {
    match find_session(conns, s) { Some(_) => true, None => false }
  })
  let _ := io.print(str.join(["[Phase 3] A2A sessions active: ", str.join(connected, ", ")], ""))
  let _ := notify_auto(base_url, "{\"kind\":\"llm_think\",\"customer\":\"robot\",\"stall\":\"\"}")

  let tools := [
    make_move_tool(base_url, base_url),
    make_purchase_tool(conns, now_ms, base_url),
  ]

  let goal := str.join([
    "You are an autonomous shopping robot. A2A sessions are live for: ",
    str.join(connected, ", "), ".\n\n",
    "SHOPPING LIST: ", list_str, "\n",
    "Total budget: ", int.to_str(budget), " credits.\n\n",
    "You have ALREADY visited every stall and gathered the full market data below ",
    "(which stall sells which item, and at what price). Now DECIDE how to ",
    "distribute your purchases: for each item on your list, choose the stall ",
    "offering it at the best price, and buy it — keeping the running total within ",
    "budget. If you cannot afford the whole list, buy the largest subset you can.\n\n",
    "For each item you decide to buy:\n",
    "  1. move_to(stall) — navigate to the chosen stall.\n",
    "  2. purchase_at(stall, item_id, payment) — buy it (exact item_id + price).\n\n",
    "When finished, output EXACTLY:\n",
    "  DONE:BOUGHT:<count>:<total_spent>\n",
    "where <count> is how many list items you acquired.\n",
    "IMPORTANT: use exact item_id values from the market data; never guess."
  ], "")

  let user_msg := str.join([
    "Shopping list: ", list_str, "    Budget: ", int.to_str(budget), " cr.\n\n",
    "Full market data gathered from every stall:\n",
    market_summary, "\n\n",
    "Decide the cheapest stall for each item and buy what fits the budget. ",
    "Start now — move_to then purchase_at for each chosen item."
  ], "")

  let agent        := llm_agent.make_agent("robot", goal, model, provider, tools, llm_agent.default_options())
  let conversation := [UserMsg(user_msg)]
  let steps        := iter.to_list(llm_agent.run_loop(agent, conversation))
  let final_text   := extract_done_text(steps)
  let result_str   := if str.contains(final_text, "BOUGHT") or str.contains(final_text, "PURCHASED") { str.concat("SOLD ", final_text) } else { final_text }
  let _ := notify_auto(base_url, str.join(["{\"kind\":\"customer_done\",\"customer\":\"robot\",\"result\":", json_str(result_str), "}"], ""))
  let _ := notify_auto(base_url, "{\"kind\":\"done\"}")
  let _ := io.print(str.concat("\n[auto_bazaar] result: ", final_text))
  io.print("══════════════════════════════════════════════════════")
}
