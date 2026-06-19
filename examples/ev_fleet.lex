# examples/ev_fleet.lex — an EV fleet that charges under a shared budget.
#
# Two fleet vehicles (EV-1, EV-2) need charge. Three charging stations (Standard
# 2cr/kWh, Fast 5cr/kWh, Premium 9cr/kWh) each run their own A2A agent
# (examples/ev_charger.lex) — the vehicles have NO prior key for any of them and
# meet each one only via its bootstrap blob (rendered as a QR).
#
# Every charge is paid under ONE shared fleet budget token (lex-guard): a
# per-transaction cap AND a fleet-wide total cap enforced across both vehicles
# from the shared attestation trail. The run shows:
#   1. EV-1 tries Premium fast-charge → over the per-tx cap → ⛔ DENIED → falls
#      back to Standard → ✓ approved → drives there → charges.
#   2. EV-2 charges at Fast → ✓ approved (fleet total still under cap).
#   3. EV-2 tries a top-up → would breach the FLEET total cap → ⛔ DENIED.
#
# Env: EV_DASH_URL (default http://localhost:8900)
#      EV_STD_URL / EV_FAST_URL / EV_PREM_URL (charger endpoints)
# Run via examples/ev_fleet_run.sh

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.list"  as list
import "std.bytes" as bytes
import "std.http"  as http
import "std.map"   as map
import "std.time"  as time

import "lex-schema/json_value" as jv

import "../src/human_goal"    as hgoal

import "../src/a2a_bootstrap" as boot
import "../src/a2a_handshake" as hs
import "../src/a2a_session"   as sess
import "../src/a2a_consent"   as consent
import "../src/a2a_card"      as card

import "lex-guard/src/gate"     as guard
import "lex-guard/src/models"   as gmod
import "lex-guard/src/executor" as gexec
import "lex-guard/src/token"    as gtok

import "lex-trail/log" as trail

# ── HTTP helpers ─────────────────────────────────────────────────────────────
fn http_err_str(err :: HttpError) -> Str {
  match err { TimeoutError => "timeout", TlsError(m) => str.concat("tls: ", m), NetworkError(m) => m, DecodeError(m) => m }
}
fn http_get(url :: Str) -> [net] Str {
  let req := http.with_timeout_ms({ method: "GET", url: url, headers: map.new(), body: None, timeout_ms: None }, 10000)
  match http.send(req) {
    Err(err) => str.join(["{\"error\":\"", http_err_str(err), "\"}"], ""),
    Ok(r)    => match bytes.to_str(r.body) { Err(_) => "{\"error\":\"bad-utf8\"}", Ok(s) => s },
  }
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
  match list.head(list.tail(str.split(resp, "\"blob\":\""))) {
    None => "", Some(rest) => match list.head(str.split(rest, "\"")) { Some(v) => v, None => "" },
  }
}
fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) { Some(v) => match jv.as_int(v) { Some(n) => n, None => 0 }, None => 0 }
}
fn cap100(n :: Int) -> Int { if n > 100 { 100 } else { n } }

# ── Meet a charger the vehicle has no prior key for ──────────────────────────
fn meet(charger_url :: Str, vehicle :: Str, dash :: Str, cpolicy :: consent.ConsentPolicy, now_ms :: Int) -> [net, io] Option[sess.PeerSession] {
  let resp := http_get(str.concat(charger_url, "/a2a/bootstrap-blob"))
  let b64  := extract_blob_b64(resp)
  if str.is_empty(b64) {
    let _ := io.print(str.join(["[", vehicle, "] charger unreachable at ", charger_url], ""))
    None
  } else {
    let _ := notify(dash, str.join(["{\"kind\":\"qr_meet\",\"vehicle\":\"", vehicle, "\",\"charger_url\":", json_str(charger_url), ",\"blob\":", json_str(b64), "}"], ""))
    let _ := notify(dash, str.join(["{\"kind\":\"a2a_call\",\"from\":\"", vehicle, "\",\"to\":\"charger\",\"skill\":\"handshake\"}"], ""))
    match boot.decode(b64) {
      Err(e) => { let _ := io.print(str.join(["[", vehicle, "] blob decode: ", e], "")); None },
      Ok(blob) => {
        let s := sess.open_session(hs.run(blob, cpolicy, now_ms), vehicle, now_ms + 300000)
        let ok := match s { Some(_) => "true", None => "false" }
        let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"charger\",\"to\":\"", vehicle, "\",\"skill\":\"handshake\",\"ok\":", ok, "}"], ""))
        s
      },
    }
  }
}

# Ask the station its per-kWh rate (real A2A skill call).
fn get_rate(session :: sess.PeerSession, now_ms :: Int) -> [net] Int {
  match sess.invoke_skill(session, { skill: "quote", args_json: "{}" }, now_ms) {
    (SkillOk(body), _) => match jv.parse_into_errors(body) { Ok(j) => jint(j, "rate"), Err(_) => 0 },
    (SkillDenied(_), _) => 0,
    (SkillFailed(_), _) => 0,
  }
}

# ── A guarded charge attempt. Returns (approved, battery_after). ─────────────
fn try_charge(session :: sess.PeerSession, vehicle :: Str, kwh :: Int, rate :: Int, dash :: Str, log :: trail.Log, gpolicy :: gmod.Policy, now_ms :: Int, battery :: Int) -> [net, io, sql, time] (Bool, Int) {
  let charger := session.peer_name
  let price := kwh * rate
  let _ := io.print(str.join(["[", vehicle, "] wants ", int.to_str(kwh), " kWh @ ", charger, " (", int.to_str(price), "cr) — lex-guard ..."], ""))
  let _ := notify(dash, str.join(["{\"kind\":\"spend_check\",\"vehicle\":\"", vehicle, "\",\"charger\":", json_str(charger), ",\"kwh\":", int.to_str(kwh), ",\"amount\":", int.to_str(price), "}"], ""))
  let intent := { merchant: charger, amount: price, currency: "EUR", category: "energy", memo: str.join([int.to_str(kwh), " kWh"], ""), idempotency_key: str.join([vehicle, "-", int.to_str(now_ms), "-", int.to_str(kwh)], "") }
  match guard.spend(gpolicy, log, gexec.mock, intent) {
    Err(e) => {
      let _ := notify(dash, str.join(["{\"kind\":\"spend_denied\",\"vehicle\":\"", vehicle, "\",\"amount\":", int.to_str(price), ",\"reason\":", json_str(e), "}"], ""))
      (false, battery)
    },
    Ok(out) => if out.approved {
      let _ := io.print(str.join(["[", vehicle, "] APPROVED ", int.to_str(price), "cr"], ""))
      let _ := notify(dash, str.join(["{\"kind\":\"spend_ok\",\"vehicle\":\"", vehicle, "\",\"charger\":", json_str(charger), ",\"amount\":", int.to_str(price), ",\"ref\":", json_str(out.executor_ref), "}"], ""))
      let _ := notify(dash, str.join(["{\"kind\":\"a2a_call\",\"from\":\"", vehicle, "\",\"to\":\"charger\",\"skill\":\"charge\"}"], ""))
      match sess.invoke_skill(session, { skill: "charge", args_json: str.join(["{\"kwh\":", int.to_str(kwh), "}"], "") }, now_ms) {
        (SkillOk(body), _) => {
          let _ := io.print(str.join(["[", vehicle, "] charged: ", body], ""))
          let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"charger\",\"to\":\"", vehicle, "\",\"skill\":\"charge\",\"ok\":true,\"body\":", json_str(body), "}"], ""))
          let lvl := cap100(battery + kwh * 3)
          let _ := notify(dash, str.join(["{\"kind\":\"battery\",\"vehicle\":\"", vehicle, "\",\"level\":", int.to_str(lvl), "}"], ""))
          (true, lvl)
        },
        (SkillDenied(why), _) => { let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"charger\",\"to\":\"", vehicle, "\",\"skill\":\"charge\",\"ok\":false,\"body\":", json_str(why), "}"], "")); (false, battery) },
        (SkillFailed(why), _) => { let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"charger\",\"to\":\"", vehicle, "\",\"skill\":\"charge\",\"ok\":false,\"body\":", json_str(why), "}"], "")); (false, battery) },
      }
    } else {
      let _ := io.print(str.join(["[", vehicle, "] DENIED ", int.to_str(price), "cr: ", out.denial_reason], ""))
      let _ := notify(dash, str.join(["{\"kind\":\"spend_denied\",\"vehicle\":\"", vehicle, "\",\"amount\":", int.to_str(price), ",\"reason\":", json_str(out.denial_reason), "}"], ""))
      (false, battery)
    },
  }
}

# Drive the vehicle (on the dashboard map) to a charger, then meet + charge it.
fn drive_meet_charge(charger_url :: Str, charger_label :: Str, vehicle :: Str, kwh :: Int, dash :: Str, cpolicy :: consent.ConsentPolicy, log :: trail.Log, gpolicy :: gmod.Policy, now_ms :: Int, battery :: Int) -> [net, io, sql, time] (Bool, Int) {
  let _ := notify(dash, str.join(["{\"kind\":\"drive\",\"vehicle\":\"", vehicle, "\",\"charger\":", json_str(charger_label), "}"], ""))
  match meet(charger_url, vehicle, dash, cpolicy, now_ms) {
    None => (false, battery),
    Some(session) => {
      let rate := get_rate(session, now_ms)
      try_charge(session, vehicle, kwh, rate, dash, log, gpolicy, now_ms, battery)
    },
  }
}

# ── Budget token: control plane signs the fleet allowance; the fleet verifies it.
fn issuer_seed() -> Bytes { bytes.from_str("ffffffffffffffffffffffffffffffff") }
fn fleet_policy(cap_total :: Int) -> gmod.Policy {
  { token_id: "tok-fleet", agent_id: "ev-fleet", currency: "EUR",
    cap_total: cap_total, cap_per_day: cap_total, cap_per_transaction: 50,
    merchants_allow: ["Standard", "Fast", "Premium"], categories_allow: ["energy"],
    max_tx_per_hour: 0, expires_at: 0, not_before: 0, require_memo: false, policy_version: 1 }
}
fn verified_policy(dash :: Str, cap_total :: Int) -> [net] gmod.Policy {
  match gtok.issue(issuer_seed(), fleet_policy(cap_total)) {
    Err(_) => fleet_policy(cap_total),
    Ok(tok) => match gtok.public_key(issuer_seed()) {
      Err(_) => fleet_policy(cap_total),
      Ok(pk) => match gtok.verify(pk, tok) {
        Err(_) => fleet_policy(cap_total),
        Ok(bt) => { let _ := notify(dash, str.join(["{\"kind\":\"budget_token\",\"cap_tx\":50,\"cap_total\":", int.to_str(cap_total), ",\"currency\":\"EUR\"}"], "")); bt.policy },
      },
    },
  }
}

# ── Entry point ──────────────────────────────────────────────────────────────
fn run() -> [env, net, io, sql, time, fs_write] Unit {
  let dash := match env.get("EV_DASH_URL")  { None => "http://localhost:8900", Some(u) => u }
  let std_url  := match env.get("EV_STD_URL")  { None => "http://localhost:9201", Some(u) => u }
  let fast_url := match env.get("EV_FAST_URL") { None => "http://localhost:9202", Some(u) => u }
  let prem_url := match env.get("EV_PREM_URL") { None => "http://localhost:9203", Some(u) => u }
  let now := time.now_ms()

  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   EV FLEET  ·  charging under a shared budget (lex-guard)")
  let _ := io.print("══════════════════════════════════════════════════════")
  # The fleet budget (cap_total) is set by the human, not hardcoded: use EV_BUDGET
  # if scripted, otherwise ask the operator via the dashboard and block.
  let cap_total := match env.get("EV_BUDGET") {
    Some(v) => match str.to_int(str.trim(v)) { Some(n) => n, None => 100 },
    None    => match str.to_int(str.trim(hgoal.ask_goal(dash, "fleet", "Set the fleet charging budget — total credits the fleet may spend (e.g. 100)"))) { Some(n) => n, None => 100 },
  }
  let _ := notify(dash, str.join(["{\"kind\":\"fleet_start\",\"ev1\":22,\"ev2\":40,\"cap_total\":", int.to_str(cap_total), "}"], ""))

  let gpolicy := verified_policy(dash, cap_total)
  let cpolicy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 20, max_budget_ms: 120000 }

  match trail.open("/tmp/lex-ev-fleet.db") {
    Err(e) => io.print(str.concat("[fleet] trail open failed: ", e)),
    Ok(log) => {
      # EV-1: Premium fast-charge is over the per-tx cap → denied → fall back to Standard.
      let _ := io.print("[EV-1] --- needs 15 kWh; tries Premium first ---")
      let r1 := drive_meet_charge(prem_url, "Premium", "EV-1", 15, dash, cpolicy, log, gpolicy, now, 22)
      let ev1a := match r1 { (ok, b) => if ok { b } else {
        let _ := io.print("[EV-1] falling back to Standard")
        match drive_meet_charge(std_url, "Standard", "EV-1", 15, dash, cpolicy, log, gpolicy, now + 1, 22) { (_, b2) => b2 }
      } }

      # EV-2: charges at Fast (within the fleet total) ...
      let _ := io.print("[EV-2] --- needs 8 kWh at Fast ---")
      let r2 := drive_meet_charge(fast_url, "Fast", "EV-2", 8, dash, cpolicy, log, gpolicy, now + 2, 40)
      let ev2a := match r2 { (_, b) => b }

      # ... then a top-up that would breach the FLEET total cap → denied.
      let _ := io.print("[EV-2] --- top-up would breach the fleet cap ---")
      let _ := drive_meet_charge(fast_url, "Fast", "EV-2", 8, dash, cpolicy, log, gpolicy, now + 3, ev2a)

      let result := str.join(["EV-1 ", int.to_str(ev1a), "%  EV-2 ", int.to_str(ev2a), "%  (fleet budget enforced)"], "")
      let _ := notify(dash, str.join(["{\"kind\":\"done\",\"result\":", json_str(result), "}"], ""))
      let _ := io.print(str.concat("\n[ev_fleet] ", result))
    },
  }
  io.print("══════════════════════════════════════════════════════")
}
