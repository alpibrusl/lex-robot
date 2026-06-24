# examples/peer_meet.lex — two peer robots that never met before.
#
# Robot A (this program) is low on battery. Robot B is a charging peer running
# its own A2A agent (a sim_sidecar identity, distinct keypair) on another port.
# A has NO prior knowledge of B's key. It "meets" B by scanning B's bootstrap
# blob (rendered as a QR on the dashboard), runs the full A2A handshake to verify
# B's signed card, opens a session, and buys charge.
#
# Every payment A makes is gated by lex-guard: A holds a signed budget token; the
# gate checks the policy BEFORE any charge. A first asks for more charge than its
# per-transaction cap allows (⛔ GRANT DENIED, attested), then an affordable
# amount (✓ approved, attested) — proving the spend wall is real.
#
# Env:
#   PEER_DASH_URL   dashboard sidecar (default http://localhost:8900)
#   PEER_B_URL      Robot B's endpoint (default http://localhost:9100)
#
# Run via examples/peer_meet_run.sh

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

# ── HTTP helpers ────────────────────────────────────────────────────────────
fn http_err_str(err :: HttpError) -> Str {
  match err {
    TimeoutError    => "timeout",
    TlsError(m)     => str.concat("tls: ", m),
    NetworkError(m) => m,
    DecodeError(m)  => m,
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

fn notify(dash :: Str, json :: Str) -> [net] Unit {
  if str.is_empty(dash) { () } else {
    let url := str.concat(dash, "/event")
    let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }
    let req := http.with_header(http.with_timeout_ms(req0, 1000), "Content-Type", "application/json")
    let _ := http.send(req)
    ()
  }
}

fn extract_blob_b64(resp :: Str) -> Str {
  match list.head(list.tail(str.split(resp, "\"blob\":\""))) {
    None       => "",
    Some(rest) => match list.head(str.split(rest, "\"")) { Some(v) => v, None => "" },
  }
}

# ── Meeting: scan B's bootstrap blob → handshake → session ───────────────────
fn meet_peer(b_url :: Str, dash :: Str, cpolicy :: consent.ConsentPolicy, now_ms :: Int) -> [net, io] Option[sess.PeerSession] {
  let _ := io.print(str.join(["[A] approaching unknown peer at ", b_url, " ..."], ""))
  let resp := http_get(str.concat(b_url, "/a2a/bootstrap-blob"))
  let b64  := extract_blob_b64(resp)
  if str.is_empty(b64) {
    let _ := io.print("[A] no bootstrap blob — peer not reachable")
    None
  } else {
    # The QR IS the meeting: A had no prior key for B; this blob (endpoint +
    # peer pubkey + nonce) is the only thing exchanged.
    let _ := notify(dash, str.join(["{\"kind\":\"qr_meet\",\"customer\":\"Robot A\",\"stall\":\"Robot B\",\"blob\":", json_str(b64), "}"], ""))
    let _ := notify(dash, "{\"kind\":\"a2a_call\",\"from\":\"Robot A\",\"to\":\"Robot B\",\"skill\":\"handshake\"}")
    match boot.decode(b64) {
      Err(e) => {
        let _ := io.print(str.join(["[A] blob decode error: ", e], ""))
        None
      },
      Ok(blob) => {
        let session_opt := sess.open_session(hs.run(blob, cpolicy, now_ms), "robot-a", now_ms + 300000)
        let ok_str := match session_opt { Some(_) => "true", None => "false" }
        let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"Robot B\",\"to\":\"Robot A\",\"skill\":\"handshake\",\"ok\":", ok_str, "}"], ""))
        let tag := match session_opt { Some(_) => "[OK] verified Robot B's signed card", None => "[FAIL] could not verify peer" }
        let _ := io.print(str.join(["[A] handshake ", tag], ""))
        session_opt
      },
    }
  }
}

# ── Guarded purchase: lex-guard gate BEFORE asking B to deliver ──────────────
# Returns the new battery level (unchanged when the spend is denied).
fn buy_charge(session :: sess.PeerSession, units :: Int, dash :: Str, log :: trail.Log, gpolicy :: gmod.Policy, now_ms :: Int, battery :: Int) -> [net, io, sql, time] Int {
  let price := units * 4
  let _ := io.print(str.join(["[A] want ", int.to_str(units), " units of charge (", int.to_str(price), "cr) — asking lex-guard ..."], ""))
  let _ := notify(dash, str.join(["{\"kind\":\"spend_check\",\"units\":", int.to_str(units), ",\"amount\":", int.to_str(price), "}"], ""))
  let intent := { merchant: session.peer_name, amount: price, currency: "EUR", category: "energy", memo: str.join([int.to_str(units), " charge units"], "") }
  match guard.spend(gpolicy, log, gexec.mock, intent) {
    Err(e) => {
      let _ := io.print(str.join(["[A] gate system error: ", e], ""))
      let _ := notify(dash, str.join(["{\"kind\":\"spend_denied\",\"amount\":", int.to_str(price), ",\"reason\":", json_str(e), "}"], ""))
      battery
    },
    Ok(out) => if out.approved {
      let _ := io.print(str.join(["[A] lex-guard APPROVED ", int.to_str(price), "cr (ref ", out.executor_ref, ")"], ""))
      let _ := notify(dash, str.join(["{\"kind\":\"spend_ok\",\"amount\":", int.to_str(price), ",\"ref\":", json_str(out.executor_ref), "}"], ""))
      # Paid — now ask B to actually deliver the charge.
      let _ := notify(dash, "{\"kind\":\"a2a_call\",\"from\":\"Robot A\",\"to\":\"Robot B\",\"skill\":\"charge_battery\"}")
      let args := str.join(["{\"units\":", int.to_str(units), "}"], "")
      match sess.invoke_skill(session, { skill: "charge_battery", args_json: args }, now_ms) {
        (SkillOk(body), _) => {
          let _ := io.print(str.concat("[A] B delivered: ", body))
          let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"Robot B\",\"to\":\"Robot A\",\"skill\":\"charge_battery\",\"ok\":true,\"body\":", json_str(body), "}"], ""))
          let lvl := battery + units
          let _ := notify(dash, str.join(["{\"kind\":\"battery\",\"level\":", int.to_str(lvl), "}"], ""))
          lvl
        },
        (SkillDenied(why), _) => {
          let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"Robot B\",\"to\":\"Robot A\",\"skill\":\"charge_battery\",\"ok\":false,\"body\":", json_str(why), "}"], ""))
          battery
        },
        (SkillFailed(why), _) => {
          let _ := notify(dash, str.join(["{\"kind\":\"a2a_resp\",\"from\":\"Robot B\",\"to\":\"Robot A\",\"skill\":\"charge_battery\",\"ok\":false,\"body\":", json_str(why), "}"], ""))
          battery
        },
      }
    } else {
      let _ := io.print(str.join(["[A] lex-guard DENIED ", int.to_str(price), "cr: ", out.denial_reason], ""))
      let _ := notify(dash, str.join(["{\"kind\":\"spend_denied\",\"amount\":", int.to_str(price), ",\"reason\":", json_str(out.denial_reason), "}"], ""))
      battery
    },
  }
}

# ── Budget token: a control plane signs A's allowance; A verifies & holds it ──
fn issuer_seed() -> Bytes {
  bytes.from_str("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}

fn a_policy() -> gmod.Policy {
  { token_id: "tok-peer-a", agent_id: "robot-a", currency: "EUR",
    cap_total: 200, cap_per_day: 200, cap_per_transaction: 50,
    merchants_allow: ["Robot B"], categories_allow: ["energy"],
    max_tx_per_hour: 0, expires_at: 0, require_memo: false, policy_version: 1 }
}

# Issue + verify the budget token, returning the verified policy (or the demo
# policy if crypto is unavailable). Exercises lex-guard's signed-token path.
fn verified_policy(dash :: Str) -> [net] gmod.Policy {
  match gtok.issue(issuer_seed(), a_policy()) {
    Err(_) => a_policy(),
    Ok(tok) => match gtok.public_key(issuer_seed()) {
      Err(_) => a_policy(),
      Ok(pk) => match gtok.verify(pk, tok) {
        Err(_) => a_policy(),
        Ok(bt) => {
          let _ := notify(dash, "{\"kind\":\"budget_token\",\"agent\":\"Robot A\",\"cap_tx\":50,\"currency\":\"EUR\"}")
          bt.policy
        },
      },
    },
  }
}

# ── Entry point ──────────────────────────────────────────────────────────────
fn run() -> [env, net, io, sql, time, fs_write] Unit {
  let dash  := match env.get("PEER_DASH_URL") { None => "http://localhost:8900", Some(u) => u }
  let b_url := match env.get("PEER_B_URL")    { None => "http://localhost:9100", Some(u) => u }
  let now   := time.now_ms()

  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   PEER MEET  ·  Robot A (low battery) seeks a charging peer")
  let _ := io.print("══════════════════════════════════════════════════════")

  let battery0 := 18
  let _ := notify(dash, str.join(["{\"kind\":\"peer_start\",\"a\":\"Robot A\",\"b\":\"Robot B\",\"battery\":", int.to_str(battery0), "}"], ""))

  # A's budget allowance (signed token, verified in-process).
  let gpolicy := verified_policy(dash)

  # Open the lex-guard attestation trail (every spend decision is recorded).
  match trail.open("/tmp/lex-peer-guard.db") {
    Err(e) => io.print(str.concat("[A] trail open failed: ", e)),
    Ok(log) => {
      let cpolicy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 20, max_budget_ms: 120000 }
      match meet_peer(b_url, dash, cpolicy, now) {
        None => {
          let _ := notify(dash, "{\"kind\":\"done\",\"result\":\"could not meet peer\"}")
          io.print("[A] could not meet Robot B")
        },
        Some(session) => {
          # The charge amount is set by the human (PEER_UNITS env if scripted, else
          # ask the operator). lex-guard caps each charge at 50cr (12 units @ 4cr):
          # if the operator asks for more it's denied, and A falls back to the
          # largest affordable charge.
          let desired := match env.get("PEER_UNITS") {
            Some(v) => match str.to_int(str.trim(v)) { Some(n) => n, None => 18 },
            None    => match str.to_int(str.trim(hgoal.ask_goal(dash, "Robot A", "How much charge does Robot A need? (units — note the budget caps each charge at 50cr)"))) { Some(n) => n, None => 18 },
          }
          let _ := io.print(str.join(["[A] operator wants ", int.to_str(desired), " units"], ""))
          let b1 := buy_charge(session, desired, dash, log, gpolicy, now, battery0)
          let b2 := if b1 == battery0 {
            let _ := io.print("[A] over the per-charge cap — falling back to the largest affordable charge (12 units)")
            buy_charge(session, 12, dash, log, gpolicy, now + 1, battery0)
          } else { b1 }
          let result := str.join(["battery ", int.to_str(b2), "% after guarded charge"], "")
          let _ := notify(dash, str.join(["{\"kind\":\"done\",\"result\":", json_str(result), "}"], ""))
          io.print(str.concat("\n[peer_meet] result: ", result))
        },
      }
    },
  }
  io.print("══════════════════════════════════════════════════════")
}
