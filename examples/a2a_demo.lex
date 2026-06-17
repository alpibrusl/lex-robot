# examples/a2a_demo.lex — End-to-end A2A handshake + session demo.
#
# Drives the full flow in a single process against the sim sidecar acting as
# the peer robot:
#
#   1. register_cards       sign local cards and push pre-signed blobs to sidecar
#   2. bootstrap blob       build a CachedChannel blob pointing at the sidecar
#   3. run_audited          fetch + verify card, consent, nonce-check, full trail
#   4. open_session         convert handshake outcome to a PeerSession
#   5. execute_plan_audited send a plan via the hybrid LLM fallback (grant-gated)
#
# The sim sidecar plays the peer robot: once step 1 runs, it serves signed cards
# at GET /a2a/public-card and /a2a/extended-card without doing any crypto itself.
#
# Run:
#   python3 sidecar/sim_sidecar.py &
#   lex run --allow-effects net,io,sql,fs_write,sense,time examples/a2a_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.time" as time

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-trail/src/log" as tlog

import "../src/a2a_card" as card

import "../src/a2a_handshake" as hs

import "../src/a2a_audit" as audit

import "../src/a2a_session" as sess

import "../src/a2a_llm_fallback" as llm

import "../src/a2a_server" as a2a_server

# ── Display helpers ────────────────────────────────────────────────────────────
fn outcome_str(o :: hs.HandshakeOutcome) -> Str {
  match o {
    PublicOnly(rc) => str.concat("PublicOnly  peer=", rc.name),
    Escalated(pub, _ext) => str.concat("Escalated   peer=", pub.name),
    Rejected(why) => str.concat("Rejected    ", why),
    Failed(why) => str.concat("Failed      ", why),
  }
}

fn result_str(r :: sess.SkillResult) -> Str {
  match r {
    SkillOk(out) => str.concat("ok:     ", out),
    SkillDenied(why) => str.concat("denied: ", why),
    SkillFailed(why) => str.concat("failed: ", why),
  }
}

# ── Demo entry point ───────────────────────────────────────────────────────────
fn run() -> [net, io, sql, fs_write, sense, time] Unit {
  let sidecar_url := "http://localhost:8900"
  let trail_path := "/tmp/lex-a2a-demo.db"
  let secret := bytes.from_str("lex-a2a-demo-seed-00000000000000")
  match crypto.ed25519_public_key(secret) {
    Err(e) => io.print(str.concat("[demo] keypair error: ", e)),
    Ok(pk) => {
      let pubkey_b64 := crypto.base64url_encode(pk)
      let pub_skills := [{ name: "move_to", description: "Move end-effector to xyz" }, { name: "grasp", description: "Close gripper with force" }]
      let ext_skills := list.concat(pub_skills, [{ name: "run_policy", description: "Run a named LeRobot policy" }, { name: "record_episode", description: "Record a LeRobot dataset episode" }])
      let pub_card := { name: "demo-robot", endpoint: sidecar_url, pubkey_b64: pubkey_b64, tier: card.Public, skills: pub_skills, supports_extended: true }
      let ext_card := { name: "demo-robot", endpoint: sidecar_url, pubkey_b64: pubkey_b64, tier: card.Extended, skills: ext_skills, supports_extended: true }
      let __1 := io.print("[demo] 1. registering cards with sidecar ...")
      match a2a_server.register_cards(sidecar_url, pub_card, ext_card, secret) {
        Err(e) => io.print(str.concat("[demo] register_cards: ", e)),
        Ok(_) => {
          let __2 := io.print("[demo]    cards registered (GET /a2a/public-card ready)")
          match tlog.open(trail_path) {
            Err(e) => io.print(str.concat("[demo] trail: ", e)),
            Ok(log) => {
              match tlog.append(log, "a2a_demo_start", None, "{}") {
                Err(e) => io.print(str.concat("[demo] trail root: ", e)),
                Ok(root) => {
                  let now := time.now_ms()
                  let blob := { endpoint: sidecar_url, ephemeral_token: "demo-token", peer_pubkey: pubkey_b64, nonce: "demo-nonce-001", expires_at: now + 300000 }
                  let __3 := io.print("[demo] 3. running audited handshake ...")
                  let policy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 10, max_budget_ms: 30000 }
                  match audit.run_audited(blob, policy, now, log, root.id, []) {
                    (outcome, p1, _used) => {
                      let __4 := io.print(str.concat("[demo]    ", outcome_str(outcome)))
                      match sess.open_session(outcome, "demo-session-001", now + 60000) {
                        None => io.print("[demo] session not opened (handshake rejected or failed)"),
                        Some(session) => {
                          let __5 := io.print(str.join(["[demo] 4. session open  peer=", session.peer_name, "  skills=", str.join(session.grant.skills, ",")], ""))
                          let __6 := io.print("[demo] 5. executing plan (fast path: move_to) ...")
                          match llm.execute_plan_audited("move_to target", session, now, log, p1) {
                            (results, _sess2, p2) => {
                              let step0 := match list.head(results) {
                                None => "(no steps)",
                                Some(r) => result_str(r),
                              }
                              let __7 := io.print(str.concat("[demo]    step 0 → ", step0))
                              io.print(str.join(["[demo] done  steps=", int.to_str(list.len(results)), "  trail=", p2], ""))
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

