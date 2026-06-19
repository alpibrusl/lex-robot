# examples/logistics.lex — supplier agents restock the bazaar over A2A.
#
# Three suppliers (Kiln Works → pottery, Loom Co → textile, Spice Caravan →
# spices) each meet their stall via A2A (no prior key — bootstrap QR), then
# deliver a batch of new items by calling the stall's `restock` skill.
#
# Every delivery is appended to a hash-chained lex-trail log — so the audit trail
# IS the provenance record: who supplied what to which stall, in a tamper-evident
# parent-linked chain.
#
# Env: LOG_DASH_URL (default http://localhost:8900)
# Run via examples/logistics_run.sh

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.list"  as list
import "std.bytes" as bytes
import "std.http"  as http
import "std.map"   as map
import "std.time"  as time

import "../src/a2a_bootstrap" as boot
import "../src/a2a_handshake" as hs
import "../src/a2a_session"   as sess
import "../src/a2a_consent"   as consent
import "../src/a2a_card"      as card
import "../src/human_goal"    as hgoal

import "lex-trail/log" as trail

# ── HTTP helpers ─────────────────────────────────────────────────────────────
fn http_err_str(err :: HttpError) -> Str {
  match err { TimeoutError => "timeout", TlsError(m) => str.concat("tls: ", m), NetworkError(m) => m, DecodeError(m) => m }
}
fn http_get(url :: Str) -> [net] Str {
  let req := http.with_timeout_ms({ method: "GET", url: url, headers: map.new(), body: None, timeout_ms: None }, 10000)
  match http.send(req) { Err(e) => str.join(["{\"error\":\"", http_err_str(e), "\"}"], ""), Ok(r) => match bytes.to_str(r.body) { Err(_) => "{}", Ok(s) => s } }
}
fn json_str(s :: Str) -> Str {
  str.concat("\"", str.concat(str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\""))
}
fn notify(dash :: Str, json :: Str) -> [net] Unit {
  if str.is_empty(dash) { () } else {
    let req := http.with_header(http.with_timeout_ms({ method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }, 1000), "Content-Type", "application/json")
    let _ := http.send(req)
    ()
  }
}
fn extract_blob_b64(resp :: Str) -> Str {
  match list.head(list.tail(str.split(resp, "\"blob\":\""))) { None => "", Some(rest) => match list.head(str.split(rest, "\"")) { Some(v) => v, None => "" } }
}

# ── Model ────────────────────────────────────────────────────────────────────
type Item     = { id :: Str, name :: Str, cat :: Str, price :: Int }
type Supplier = { name :: Str, stall :: Str, url :: Str, items :: List[Item] }

fn stall_url(stall :: Str) -> Str {
  if stall == "pottery" { "http://localhost:8901" } else {
  if stall == "textile" { "http://localhost:8902" } else {
  if stall == "spices"  { "http://localhost:8903" } else { "" }}}
}

fn suppliers() -> List[Supplier] {
  [
    { name: "Kiln Works",    stall: "pottery", url: stall_url("pottery"), items: [
        { id: "pot-101", name: "Glazed Urn",   cat: "pottery", price: 14 },
        { id: "pot-102", name: "Clay Pot",     cat: "pottery", price: 6 } ] },
    { name: "Loom Co",       stall: "textile", url: stall_url("textile"), items: [
        { id: "tex-101", name: "Wool Blanket", cat: "textile", price: 18 },
        { id: "tex-102", name: "Cotton Cloth", cat: "textile", price: 7 } ] },
    { name: "Spice Caravan", stall: "spices",  url: stall_url("spices"),  items: [
        { id: "spi-101", name: "Cardamom 20g", cat: "spices",  price: 8 },
        { id: "spi-102", name: "Cinnamon",     cat: "spices",  price: 4 } ] },
  ]
}

# ── Meet a stall the supplier has no prior key for ───────────────────────────
fn meet(supplier :: Str, stall_url :: Str, dash :: Str, cpolicy :: consent.ConsentPolicy, now_ms :: Int) -> [net, io] Option[sess.PeerSession] {
  let resp := http_get(str.concat(stall_url, "/a2a/bootstrap-blob"))
  let b64  := extract_blob_b64(resp)
  if str.is_empty(b64) { let _ := io.print(str.join(["[", supplier, "] stall unreachable"], "")); None } else {
    let _ := notify(dash, str.join(["{\"kind\":\"qr_meet\",\"supplier\":\"", supplier, "\",\"blob\":", json_str(b64), "}"], ""))
    let _ := notify(dash, str.join(["{\"kind\":\"a2a_call\",\"from\":\"", supplier, "\",\"to\":\"stall\",\"skill\":\"handshake\"}"], ""))
    match boot.decode(b64) {
      Err(_) => None,
      Ok(blob) => {
        let s := sess.open_session(hs.run(blob, cpolicy, now_ms), supplier, now_ms + 300000)
        let ok := match s { Some(_) => "true", None => "false" }
        let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"stall\",\"to\":\"", supplier, "\",\"skill\":\"handshake\",\"ok\":", ok, "}"], ""))
        s
      },
    }
  }
}

# ── Deliver one item: append provenance to the chain, then A2A restock ───────
# Returns the new chain head (this delivery's event id).
fn deliver(session :: sess.PeerSession, supplier :: Str, stall :: Str, it :: Item, dash :: Str, log :: trail.Log, parent :: Str, now_ms :: Int) -> [net, io, sql, time] Str {
  let payload := str.join(["{\"supplier\":\"", supplier, "\",\"stall\":\"", stall, "\",\"item\":\"", it.id, "\",\"name\":\"", it.name, "\",\"price\":", int.to_str(it.price), "}"], "")
  let par := if str.is_empty(parent) { None } else { Some(parent) }
  let head := match trail.append(log, "supply", par, payload) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
  let _ := notify(dash, str.join(["{\"kind\":\"provenance\",\"supplier\":\"", supplier, "\",\"stall\":\"", stall, "\",\"item\":\"", it.name, "\",\"id\":", json_str(str.slice(head, 0, 10)), ",\"parent\":", json_str(str.slice(parent, 0, 10)), "}"], ""))
  let args := str.join(["{\"supplier\":\"", supplier, "\",\"item_id\":\"", it.id, "\",\"name\":\"", it.name, "\",\"category\":\"", it.cat, "\",\"price\":", int.to_str(it.price), "}"], "")
  let _ := notify(dash, str.join(["{\"kind\":\"a2a_call\",\"from\":\"", supplier, "\",\"to\":\"", stall, "\",\"skill\":\"restock\"}"], ""))
  match sess.invoke_skill(session, { skill: "restock", args_json: args }, now_ms) {
    (SkillOk(body), _) => {
      let _ := io.print(str.join(["[", supplier, "] delivered ", it.name, " → ", stall, ": ", body], ""))
      let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"", stall, "\",\"to\":\"", supplier, "\",\"skill\":\"restock\",\"ok\":true,\"body\":", json_str(body), "}"], ""))
      head
    },
    (SkillDenied(why), _) => { let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"", stall, "\",\"to\":\"", supplier, "\",\"skill\":\"restock\",\"ok\":false,\"body\":", json_str(why), "}"], "")); head },
    (SkillFailed(why), _) => { let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"", stall, "\",\"to\":\"", supplier, "\",\"skill\":\"restock\",\"ok\":false,\"body\":", json_str(why), "}"], "")); head },
  }
}

# ── Entry point ──────────────────────────────────────────────────────────────
fn run() -> [env, net, io, sql, time, fs_write] Unit {
  let dash := match env.get("LOG_DASH_URL") { None => "http://localhost:8900", Some(u) => u }
  let now  := time.now_ms()
  let cpolicy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 30, max_budget_ms: 120000 }

  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   LOGISTICS  ·  suppliers restock the bazaar (A2A + provenance)")
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := notify(dash, "{\"kind\":\"logistics_start\"}")

  # Human-in-the-loop gate: the operator must authorise the supply run before any
  # supplier delivers. Scripted via LOGI_APPROVE, else ask the operator and block.
  let approval := match env.get("LOGI_APPROVE") {
    Some(v) => v,
    None    => hgoal.ask_goal(dash, "operator", "Authorise today's bazaar restock run? (type 'yes' to dispatch the suppliers)"),
  }
  let approved := str.contains(approval, "yes") or str.contains(approval, "YES") or str.contains(approval, "Yes") or str.trim(approval) == "y"
  if not approved {
    let _ := notify(dash, "{\"kind\":\"gate\",\"approved\":false}")
    let _ := notify(dash, "{\"kind\":\"done\",\"result\":\"restock declined by operator\"}")
    io.print("[logistics] operator declined the restock run")
  } else {
  let _ := notify(dash, "{\"kind\":\"gate\",\"approved\":true}")
  match trail.open("/tmp/lex-logistics.db") {
    Err(e) => io.print(str.concat("[logistics] trail open failed: ", e)),
    Ok(log) => {
      # Each supplier delivers its batch; the chain head threads across all
      # deliveries so the whole supply run is one tamper-evident provenance chain.
      let _final := list.fold(suppliers(), "", fn (parent :: Str, sup :: Supplier) -> [net, io, sql, time] Str {
        let _ := io.print(str.join(["[", sup.name, "] driving to ", sup.stall, " ..."], ""))
        let _ := notify(dash, str.join(["{\"kind\":\"drive\",\"supplier\":\"", sup.name, "\",\"stall\":\"", sup.stall, "\"}"], ""))
        match meet(sup.name, sup.url, dash, cpolicy, now) {
          None => parent,
          Some(session) => list.fold(sup.items, parent, fn (p :: Str, it :: Item) -> [net, io, sql, time] Str {
            deliver(session, sup.name, sup.stall, it, dash, log, p, now)
          }),
        }
      })
      let _ := notify(dash, "{\"kind\":\"done\",\"result\":\"bazaar restocked — provenance recorded\"}")
      io.print("\n[logistics] all suppliers delivered; provenance chain written to /tmp/lex-logistics.db")
    },
  }
  }
  io.print("══════════════════════════════════════════════════════")
}
