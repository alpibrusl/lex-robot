# lex-robot/examples/bazaar_visit_demo.lex — a robot visits a bazaar run by
# strangers (epic #115, issue #120, use case 2).
#
# The discovery/trust half of this scenario already exists in this
# codebase: examples/peer_meet.lex proves a robot with NO prior key for a
# peer can scan its bootstrap blob, verify its SIGNED card via
# a2a_handshake.lex's PULL model, open a session (a2a_session.lex), and
# transact — reused here unmodified via examples/peer_provider.lex as the
# stall. What's new is the physical half: before any of that identity
# verification happens, the visiting robot has to actually walk into a
# space it shares with a stall-robot it has never met.
#
# The point of this demo is the SPLIT, not the mechanism:
#   SAFETY (fleet_traffic.lex / fleet_arbiter_server.lex)    — claim the
#     approach space. No signed card, no consent policy, no prior
#     relationship. Honored purely because nothing else occupies it.
#   AUTHORITY (a2a_bootstrap/a2a_handshake/a2a_session/a2a_consent)  —
#     verify the stall's identity and negotiate a purchase. Fully
#     signature-checked, tiered, policy-gated.
# A failure in one must not touch the other: losing a commerce negotiation
# should never strand a robot mid-corridor, and a bazaar stranger's
# collision-avoidance claim is honored exactly as readily as a fleet
# member's (fleet_traffic.lex has no notion of "fleet member" at all).
#
# Run: examples/bazaar_visit_demo_run.sh (starts the arbiter + the stall,
# runs this, tears both down).

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "std.http" as http

import "std.map" as map

import "std.time" as time

import "../src/types" as t

import "../src/a2a_bootstrap" as boot

import "../src/a2a_handshake" as hs

import "../src/a2a_session" as sess

import "../src/a2a_consent" as consent

import "../src/a2a_card" as card

import "../src/fleet_traffic" as ft

import "../src/fleet_client" as fleet

# ── HTTP helpers (mirrors examples/peer_meet.lex's) ─────────────────────────
fn http_err_str(err :: HttpError) -> Str {
  match err {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => m,
    DecodeError(m) => m,
  }
}

fn http_get(url :: Str) -> [net] Str {
  let req0 := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: None }
  let req := http.with_timeout_ms(req0, 10000)
  match http.send(req) {
    Err(err) => str.join(["{\"error\":\"", http_err_str(err), "\"}"], ""),
    Ok(r) => match bytes.to_str(r.body) {
      Err(_) => "{\"error\":\"bad-utf8\"}",
      Ok(s) => s,
    },
  }
}

fn extract_blob_b64(resp :: Str) -> Str {
  match list.head(list.tail(str.split(resp, "\"blob\":\""))) {
    None => "",
    Some(rest) => match list.head(str.split(rest, "\"")) {
      Some(v) => v,
      None => "",
    },
  }
}

# The bazaar's shared approach space — a 1m box outside the stall, deliberately
# a single fixed cell any visitor claims (real deployments would derive this
# from the stall's own advertised location; hardcoded here keeps the demo
# self-contained).
fn approach_cell() -> ft.Cell {
  { ws_min: { x: 4.0, y: 4.0, z: 0.0 }, ws_max: { x: 5.0, y: 5.0, z: 1.0 } }
}

fn approach_point() -> t.Vec3 {
  { x: 4.5, y: 4.5, z: 0.0 }
}

# ── Step 1: SAFETY — claim the approach space, no trust required ───────────
fn claim_approach(arbiter_url :: Str, robot_id :: Str, now_ms :: Int) -> [net, io] Option[Str] {
  match fleet.claim(arbiter_url, robot_id, approach_cell(), now_ms, now_ms + 120000) {
    Err(e) => {
      let __p := io.print(str.join(["[visitor] approach space DENIED: ", e], ""))
      None
    },
    Ok(claim_id) => {
      let __p := io.print(str.join(["[visitor] approach space claimed (", claim_id, ") — no card, no consent policy, nothing but 'is anyone else here'"], ""))
      Some(claim_id)
    },
  }
}

# ── Step 2: AUTHORITY — verify the stall's signed identity, unmodified from
# examples/peer_meet.lex's meet_peer (no dashboard notifications here — this
# demo's point is the safety/authority split, not the UI). ──────────────────
fn meet_stall(stall_url :: Str, cpolicy :: consent.ConsentPolicy, now_ms :: Int) -> [net, io] Option[sess.PeerSession] {
  let __p := io.print(str.join(["[visitor] approaching stall at ", stall_url, " — no prior key for it"], ""))
  let resp := http_get(str.concat(stall_url, "/a2a/bootstrap-blob"))
  let b64 := extract_blob_b64(resp)
  if str.is_empty(b64) {
    let __q := io.print("[visitor] no bootstrap blob — stall not reachable")
    None
  } else {
    match boot.decode(b64) {
      Err(e) => {
        let __q := io.print(str.join(["[visitor] blob decode error: ", e], ""))
        None
      },
      Ok(blob) => {
        let session_opt := sess.open_session(hs.run(blob, cpolicy, now_ms), "bazaar-visit", now_ms + 300000)
        let tag := match session_opt {
          Some(_) => "[OK] verified the stall's signed card",
          None => "[FAIL] could not verify the stall",
        }
        let __q := io.print(str.join(["[visitor] handshake ", tag], ""))
        session_opt
      },
    }
  }
}

fn bazaar_consent_policy() -> consent.ConsentPolicy {
  { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 20, max_budget_ms: 120000 }
}

fn run() -> [env, net, io, time] Unit {
  let arbiter_url := match env.get("BAZAAR_ARBITER_URL") {
    None => "http://localhost:18920",
    Some(u) => u,
  }
  let stall_url := match env.get("BAZAAR_STALL_URL") {
    None => "http://localhost:9100",
    Some(u) => u,
  }
  let now := time.now_ms()
  let visitor_id := "visitor-robot"
  let __0 := io.print("══════════════════════════════════════════════════════")
  let __1 := io.print("   BAZAAR VISIT  ·  a robot among strangers")
  let __2 := io.print("══════════════════════════════════════════════════════")
  let __3 := io.print("")
  let __4 := io.print("── SAFETY: claim the physical approach space ──")
  let claim_id := claim_approach(arbiter_url, visitor_id, now)
  let __5 := io.print("")
  let __6 := io.print("── AUTHORITY: verify the stall's identity, negotiate ──")
  let session_opt := meet_stall(stall_url, bazaar_consent_policy(), now)
  let __7 := match session_opt {
    None => io.print("[visitor] no session — cannot transact with an unverified stall"),
    Some(session) => match sess.invoke_skill(session, { skill: "charge_battery", args_json: "{\"units\":1}" }, now) {
      (SkillOk(body), _) => io.print(str.concat("[visitor] stall responded: ", body)),
      (SkillDenied(why), _) => io.print(str.concat("[visitor] stall denied: ", why)),
      (SkillFailed(why), _) => io.print(str.concat("[visitor] stall call failed: ", why)),
    },
  }
  let __8 := io.print("")
  let __9 := io.print("── proving the split: the approach claim outlives the negotiation ──")
  match fleet.check(arbiter_url, visitor_id, approach_point()) {
    Err(e) => io.print(str.concat("[visitor] could not verify claim: ", e)),
    Ok(false) => io.print("BUG: approach claim was lost — safety should be independent of authority outcome"),
    Ok(true) => io.print("[visitor] approach claim still held, regardless of how the stall negotiation went — safety and authority are genuinely independent layers here."),
  }
}

