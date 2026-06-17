# examples/bazaar_demo.lex — Robot bazaar: customer shops across stalls via A2A.
#
# Three seller robots advertise goods via signed agent cards. A customer robot
# visits each in turn, performs a trust-escalating A2A handshake, queries
# stock, and buys the cheapest match.
#
# What this demo surfaces:
#
#   Lex language
#     bazaar.item_matches — pure predicate, examples-tested, no network needed
#     Consent policy      — pure deterministic rule, no model in trust path
#     Effect wall         — customer is [net] only during queries; [actuate]
#                           is absent from this module entirely
#     Grant as budget     — budget_actions: 10 caps interactions across ALL stalls
#
#   Lex OS (production)
#     Each seller in a Firecracker microVM; grant.lex seals the box
#     budget_actions enforced at OS level — no seller can drain the customer
#     lex-trail verify → tamper-evident receipt of every step
#
#   A2A safety guarantee
#     LLM fallback test: mock LLM proposes [move_to, grasp, self_destruct]
#     grant validation: only move_to is in the pottery session grant
#     result: grasp + self_destruct DROPPED, move_to executed — shown inline
#
# Run (after starting sellers with examples/bazaar_run.sh):
#   lex run --allow-effects net,io,sql,fs_write,sense,time examples/bazaar_demo.lex run
#
# Offline unit test (no sidecar needed):
#   lex run src/bazaar.lex item_matches_test
#
# Dashboard (when sellers are running):
#   http://localhost:8900

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.time" as time

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.http" as http

import "std.map" as map

import "lex-trail/src/log" as tlog

import "../src/a2a_card" as card

import "../src/a2a_llm_fallback" as llm

import "../src/bazaar" as baz

# ── Stall seeds (sim: known to both sides; in prod each seller holds its own) ──
fn pottery_secret() -> Bytes {
  bytes.from_str("00000000000000000000000000000001")
}

fn textile_secret() -> Bytes {
  bytes.from_str("00000000000000000000000000000002")
}

fn spices_secret() -> Bytes {
  bytes.from_str("00000000000000000000000000000003")
}

# ── Stall card skills ──────────────────────────────────────────────────────────
# Public tier: browse only.  Extended tier: full transaction.
# Pottery also grants move_to so the LLM fallback safety test is meaningful.
fn query_skill() -> card.AgentSkill {
  { name: "query_stock", description: "Search available stock" }
}

fn pottery_pub_skills() -> List[card.AgentSkill] {
  [query_skill()]
}

fn pottery_ext_skills() -> List[card.AgentSkill] {
  [query_skill(), { name: "reserve_item", description: "Reserve an item for purchase" }, { name: "complete_sale", description: "Finalise sale and transfer item" }, { name: "move_to", description: "Direct customer to item location" }]
}

fn simple_ext_skills() -> List[card.AgentSkill] {
  [query_skill(), { name: "reserve_item", description: "Reserve an item for purchase" }, { name: "complete_sale", description: "Finalise sale and transfer item" }]
}

# ── Dashboard event helper ─────────────────────────────────────────────────────
# Fire-and-forget: POST a JSON event to the dashboard sidecar.  Errors ignored.
fn post_ui(dash :: Str, json :: Str) -> [net] Str {
  let req0 := { method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 1000), "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => "",
    Ok(_) => "",
  }
}

# JSON-safe tx description (no embedded quotes).
fn tx_ui_str(tx :: baz.TxResult) -> Str {
  match tx {
    Sold(item) => str.join(["SOLD ", item.name, " - ", int.to_str(item.price), " cr"], ""),
    NotFound => "not found",
    AlreadyReserved => "already reserved",
    TxDenied(why) => str.concat("denied: ", why),
  }
}

# ── Banner ─────────────────────────────────────────────────────────────────────
fn banner(search :: Str, budget :: Int) -> [io] Unit {
  let __1 := io.print("══════════════════════════════════════════════════════")
  let __2 := io.print("   ROBOT BAZAAR  —  A2A peer commerce demo")
  let __3 := io.print(str.join(["   search: \"", search, "\"   budget: ", int.to_str(budget), " credits"], ""))
  let __4 := io.print("══════════════════════════════════════════════════════")
  let __5 := io.print("   Stalls:  POTTERY :8901  ·  TEXTILE :8902  ·  SPICES :8903")
  let __6 := io.print("   Dashboard: http://localhost:8900")
  io.print("──────────────────────────────────────────────────────")
}

# ── Setup one seller (sim: customer drives registration) ───────────────────────
fn setup_one(url :: Str, name :: Str, secret :: Bytes, pub_skills :: List[card.AgentSkill], ext_skills :: List[card.AgentSkill]) -> [net, io] Result[baz.StallInfo, Str] {
  match baz.setup_seller(url, name, secret, pub_skills, ext_skills) {
    Err(e) => Err(str.join(["setup ", name, ": ", e], "")),
    Ok(pub_b64) => {
      let __1 := io.print(str.join(["   ", name, "  pubkey=", str.slice(pub_b64, 0, 16), "..."], ""))
      Ok({ url: url, name: name, pubkey_b64: pub_b64 })
    },
  }
}

# ── LLM safety test ───────────────────────────────────────────────────────────
# Show that the mock LLM's self_destruct proposal is dropped by the grant.
fn llm_safety_test(stall :: baz.StallInfo, policy :: { allowed_pubkeys :: List[Str], allowed_skills :: List[Str], max_tier :: card.CardTier, require_https :: Bool, max_budget_actions :: Int, max_budget_ms :: Int }, log :: tlog.Log, parent :: Str, now :: Int, dash :: Str) -> [net, sql, time, io] Unit {
  let __1 := io.print("──────────────────────────────────────────────────────")
  let __2 := io.print("[LLM safety] re-opening pottery session for fallback test ...")
  let blob := { endpoint: stall.url, ephemeral_token: "bazaar-token", peer_pubkey: stall.pubkey_b64, nonce: "n-pottery-llm", expires_at: now + 300000 }
  match llm_audit_run(blob, policy, now, log, parent) {
    (None, _) => io.print("[LLM safety] session failed — skipping test"),
    (Some(session), p2) => {
      let __3 := io.print("[LLM safety] msg: \"do something\" (free-text, no skill match)")
      let __4 := io.print("[LLM safety] mock LLM proposes: move_to, grasp, self_destruct")
      match llm.execute_plan_audited("do something", session, now, log, p2) {
        (results, _sess2, _p3) => {
          let __ui := post_ui(dash, str.join(["{\"kind\":\"llm_result\",\"executed\":", int.to_str(list.len(results)), ",\"dropped\":\"grasp,self_destruct\"}"], ""))
          let __5 := io.print(str.join(["[LLM safety] executed=", int.to_str(list.len(results)), "  (grasp+self_destruct dropped by grant — only move_to allowed)"], ""))
          io.print("──────────────────────────────────────────────────────")
        },
      }
    },
  }
}

# Helper: run audited handshake + open session (used in LLM test).
import "../src/a2a_audit" as audit

import "../src/a2a_session" as sess

import "../src/a2a_bootstrap" as boot

fn llm_audit_run(blob :: boot.BootstrapBlob, policy :: { allowed_pubkeys :: List[Str], allowed_skills :: List[Str], max_tier :: card.CardTier, require_https :: Bool, max_budget_actions :: Int, max_budget_ms :: Int }, now :: Int, log :: tlog.Log, parent :: Str) -> [net, sql, time] (Option[sess.PeerSession], Str) {
  match audit.run_audited(blob, policy, now, log, parent, []) {
    (outcome, p1, _) => match sess.open_session(outcome, "llm-test-session", now + 60000) {
      None => (None, p1),
      Some(s) => (Some(s), p1),
    },
  }
}

# ── Customer entry point ───────────────────────────────────────────────────────
fn run() -> [net, io, sql, fs_write, sense, time] Unit {
  let search := "Bowl"
  let budget := 15
  let trail_path := "/tmp/lex-bazaar-demo.db"
  let dash := "http://localhost:8900"
  let __b := banner(search, budget)
  let __ui0 := post_ui(dash, str.join(["{\"kind\":\"start\",\"search\":\"", search, "\",\"budget\":", int.to_str(budget), "}"], ""))
  match tlog.open(trail_path) {
    Err(e) => io.print(str.concat("[bazaar] trail: ", e)),
    Ok(log) => {
      match tlog.append(log, "bazaar_start", None, "{}") {
        Err(e) => io.print(str.concat("[bazaar] trail root: ", e)),
        Ok(root) => {
          let now := time.now_ms()
          let policy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 10, max_budget_ms: 30000 }
          let __s := io.print("[bazaar] setting up seller cards ...")
          match setup_one("http://localhost:8901", "Pottery Palace", pottery_secret(), pottery_pub_skills(), pottery_ext_skills()) {
            Err(e) => io.print(e),
            Ok(pottery) => {
              match setup_one("http://localhost:8902", "Textile Traders", textile_secret(), [query_skill()], simple_ext_skills()) {
                Err(e) => io.print(e),
                Ok(textile) => {
                  match setup_one("http://localhost:8903", "Spice Garden", spices_secret(), [query_skill()], simple_ext_skills()) {
                    Err(e) => io.print(e),
                    Ok(spices) => {
                      let stalls := [spices, textile, pottery]
                      let __sl := io.print("──────────────────────────────────────────────────────")
                      let init := { purchase: None, parent: root.id, used: [] }
                      let final_state := list.fold(stalls, init, fn (state :: baz.ShopState, stall :: baz.StallInfo) -> [net, sql, time, io] baz.ShopState {
                        match state.purchase {
                          Some(_) => state,
                          None => {
                            let __uiv := post_ui(dash, str.join(["{\"kind\":\"visit\",\"stall\":\"", stall.name, "\"}"], ""))
                            let __vi := io.print(str.join(["→ [", stall.name, "] handshaking + querying \"", search, "\" ≤ ", int.to_str(budget), " credits ..."], ""))
                            match baz.visit_stall(stall, search, budget, policy, log, state.parent, state.used, now) {
                              (tx, p2, used2) => {
                                let __uir := post_ui(dash, str.join(["{\"kind\":\"result\",\"stall\":\"", stall.name, "\",\"tx\":\"", tx_ui_str(tx), "\"}"], ""))
                                let __vr := io.print(str.concat("  ", baz.tx_str(tx)))
                                match tx {
                                  Sold(_) => { purchase: Some(tx), parent: p2, used: used2 },
                                  _ => { purchase: None, parent: p2, used: used2 },
                                }
                              },
                            }
                          },
                        }
                      })
                      let __su := io.print("══════════════════════════════════════════════════════")
                      let __sr := match final_state.purchase {
                        None => io.print("  no matching item found across all stalls"),
                        Some(tx) => io.print(str.concat("  PURCHASE: ", baz.tx_str(tx))),
                      }
                      let __st := io.print(str.concat("  trail: ", final_state.parent))
                      let __se := io.print("══════════════════════════════════════════════════════")
                      let __uid := post_ui(dash, str.join(["{\"kind\":\"done\",\"trail\":\"", final_state.parent, "\"}"], ""))
                      let __uils := post_ui(dash, "{\"kind\":\"llm_start\"}")
                      llm_safety_test(pottery, policy, log, final_state.parent, now, dash)
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

