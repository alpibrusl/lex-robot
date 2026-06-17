# examples/bazaar_rush.lex — Robot bazaar rush hour: 3 customers, 6 stalls.
#
# Three customer robots shop sequentially across six seller stalls that carry
# competing goods at different prices.  The A2A grant layer enforces every
# interaction; Gemini 3.5 Flash drives each customer's decisions.
#
# Stall layout:
#   :8901  Pottery Palace  — pottery (Red Ceramic Bowl 8cr, Blue Glazed Vase 12cr …)
#   :8902  Textile Traders — textile (Silk Scarf 15cr, Linen Tablecloth 30cr)
#   :8903  Spice Garden    — spices  (Saffron 10g 5cr, Vanilla Pods 9cr, Star Anise 4cr)
#   :8904  Clay Corner     — clay    (Stoneware Bowl 10cr, Terracotta Jug 7cr)
#   :8905  Fabric House    — fabric  (Cotton Scarf 12cr, Velvet Ribbon 8cr)
#   :8906  Herb Garden     — herb    (Premium Saffron 6cr, Dried Lavender 3cr, Cardamom 4cr)
#
# Customers (sequential):
#   Alice  — "Bowl"    ≤ 15 cr  → buys Red Ceramic Bowl at Pottery Palace (8cr)
#   Bob    — "Bowl"    ≤ 15 cr  → pottery sold out; buys Stoneware Bowl at Clay Corner (10cr)
#   Carlos — "Saffron" ≤  8 cr  → buys Saffron 10g at Spice Garden (5cr)
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

import "lex-llm/src/message" as msg

import "lex-trail/src/log" as tlog

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers/vertex" as vtx

import "../src/a2a_card" as card

import "../src/a2a_consent" as consent

import "../src/bazaar" as baz

import "../src/bazaar_llm" as bll

# ── Stall secrets (sim: fixed; in prod each seller holds its own) ──────────────
fn pottery_secret() -> Bytes { bytes.from_str("00000000000000000000000000000001") }
fn textile_secret() -> Bytes { bytes.from_str("00000000000000000000000000000002") }
fn spices_secret()  -> Bytes { bytes.from_str("00000000000000000000000000000003") }
fn clay_secret()    -> Bytes { bytes.from_str("00000000000000000000000000000004") }
fn fabric_secret()  -> Bytes { bytes.from_str("00000000000000000000000000000005") }
fn herb_secret()    -> Bytes { bytes.from_str("00000000000000000000000000000006") }

# ── Skill lists ────────────────────────────────────────────────────────────────
fn query_skill() -> card.AgentSkill {
  { name: "query_stock", description: "Search available stock" }
}

fn full_skills() -> List[card.AgentSkill] {
  [query_skill(), { name: "reserve_item", description: "Reserve an item for purchase" }, { name: "complete_sale", description: "Finalise sale and transfer item" }]
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

fn tx_ui_str(tx :: baz.TxResult) -> Str {
  match tx {
    Sold(item) => str.join(["SOLD ", item.name, " - ", int.to_str(item.price), " cr"], ""),
    NotFound => "not found",
    AlreadyReserved => "already reserved",
    TxDenied(why) => str.concat("denied: ", why),
  }
}

fn json_esc(s :: Str) -> Str {
  msg.json_escape(s)
}

# ── Stall setup helper ─────────────────────────────────────────────────────────
fn setup_one(url :: Str, name :: Str, secret :: Bytes) -> [net, io] Result[baz.StallInfo, Str] {
  match baz.setup_seller(url, name, secret, [query_skill()], full_skills()) {
    Err(e) => Err(str.join(["setup ", name, ": ", e], "")),
    Ok(pub_b64) => {
      let _p := io.print(str.join(["   ", name, "  pubkey=", str.slice(pub_b64, 0, 16), "..."], ""))
      Ok({ url: url, name: name, pubkey_b64: pub_b64 })
    },
  }
}

# ── Per-customer shopping run ──────────────────────────────────────────────────
# goal             — free-form natural-language goal (e.g. "Find a Bowl ≤ 15 cr")
# ask_human_enabled — whether the LLM may pause to ask the operator questions
fn shop_customer(name :: Str, goal :: Str, stalls :: List[baz.StallInfo], policy :: consent.ConsentPolicy, log :: tlog.Log, root_id :: Str, now :: Int, provider :: prov.Provider, model :: prov.ModelRef, dash :: Str, ask_human_enabled :: Bool) -> [net, sql, time, llm, io, proc] Unit {
  let _cs := post_ui(dash, str.join(["{\"kind\":\"customer_start\",\"customer\":\"", name, "\",\"goal\":\"", json_esc(goal), "\"}"], ""))
  let _pb := io.print(str.join(["── ", name, ": ", goal, " ──────────────────────────"], ""))
  let init := { purchase: None, parent: root_id, used: [] }
  let final_state := list.fold(stalls, init, fn (state :: baz.ShopState, stall :: baz.StallInfo) -> [net, sql, time, llm, io, proc] baz.ShopState {
    match state.purchase {
      Some(_) => state,
      None => {
        let _uiv := post_ui(dash, str.join(["{\"kind\":\"visit\",\"customer\":\"", name, "\",\"stall\":\"", stall.name, "\"}"], ""))
        let _vi := io.print(str.join(["  [", name, "] → ", stall.name], ""))
        match bll.shop_with_llm(stall, goal, policy, log, state.parent, state.used, now, provider, model, dash, name, ask_human_enabled) {
          (tx, p2, used2) => {
            let _uir := post_ui(dash, str.join(["{\"kind\":\"result\",\"customer\":\"", name, "\",\"stall\":\"", stall.name, "\",\"tx\":\"", tx_ui_str(tx), "\"}"], ""))
            let _vr := io.print(str.join(["  [", name, "] ← ", baz.tx_str(tx)], ""))
            let _sl := time.sleep_ms(1000)
            match tx {
              Sold(_) => { purchase: Some(tx), parent: p2, used: used2 },
              _ => { purchase: None, parent: p2, used: used2 },
            }
          },
        }
      },
    }
  })
  let result_str := match final_state.purchase {
    None => "none",
    Some(tx) => tx_ui_str(tx),
  }
  let _cd := post_ui(dash, str.join(["{\"kind\":\"customer_done\",\"customer\":\"", name, "\",\"result\":\"", result_str, "\"}"], ""))
  let _pf := io.print(str.join(["── ", name, " done: ", result_str, " ──────────────────────────────────────────────"], ""))
  ()
}

# ── Entry point ────────────────────────────────────────────────────────────────
fn run() -> [net, io, sql, fs_write, sense, time, env, llm, proc] Unit {
  let trail_path := "/tmp/lex-bazaar-rush.db"
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
  let _p2 := io.print("   ROBOT BAZAAR RUSH HOUR  —  3 customers, 6 stalls")
  let _p3 := io.print("   Alice:  Bowl    ≤ 15 cr")
  let _p4 := io.print("   Bob:    Bowl    ≤ 15 cr  (competes with Alice!)")
  let _p5 := io.print("   Carlos: Saffron ≤  8 cr")
  let _p6 := io.print("   Dashboard: http://localhost:8900")
  let _p7 := io.print("══════════════════════════════════════════════════════")

  let _ui0 := post_ui(dash, "{\"kind\":\"start\",\"customers\":[\"Alice\",\"Bob\",\"Carlos\"],\"stalls\":6}")

  match tlog.open(trail_path) {
    Err(e) => io.print(str.concat("[rush] trail: ", e)),
    Ok(log) => {
      match tlog.append(log, "rush_start", None, "{}") {
        Err(e) => io.print(str.concat("[rush] trail root: ", e)),
        Ok(root) => {
          let now := time.now_ms()
          let policy := { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 20, max_budget_ms: 60000 }

          let _ps := io.print("[rush] setting up 6 stalls ...")
          match setup_one("http://localhost:8901", "Pottery Palace", pottery_secret()) {
            Err(e) => io.print(e),
            Ok(pottery) => {
              match setup_one("http://localhost:8902", "Textile Traders", textile_secret()) {
                Err(e) => io.print(e),
                Ok(textile) => {
                  match setup_one("http://localhost:8903", "Spice Garden", spices_secret()) {
                    Err(e) => io.print(e),
                    Ok(spices) => {
                      match setup_one("http://localhost:8904", "Clay Corner", clay_secret()) {
                        Err(e) => io.print(e),
                        Ok(clay) => {
                          match setup_one("http://localhost:8905", "Fabric House", fabric_secret()) {
                            Err(e) => io.print(e),
                            Ok(fabric) => {
                              match setup_one("http://localhost:8906", "Herb Garden", herb_secret()) {
                                Err(e) => io.print(e),
                                Ok(herb) => {
                                  let _sl0 := time.sleep_ms(1000)

                                  # Visit order: bowl shoppers hit pottery first, then clay
                                  let bowl_stalls := [pottery, clay, textile, fabric, spices, herb]
                                  # Spice shoppers hit their stalls first
                                  let spice_stalls := [spices, herb, pottery, clay, textile, fabric]

                                  # Alice shops first for a bowl
                                  let _sa := shop_customer("Alice", "Find and buy a Bowl for at most 15 credits", bowl_stalls, policy, log, root.id, now, provider, model, dash, false)
                                  let _sl1 := time.sleep_ms(2000)

                                  # Bob shops second — pottery bowl sold out, lands on clay
                                  let _sb := shop_customer("Bob", "Find and buy a Bowl for at most 15 credits", bowl_stalls, policy, log, root.id, now, provider, model, dash, false)
                                  let _sl2 := time.sleep_ms(2000)

                                  # Carlos shops for saffron (different product, no competition)
                                  let _sc := shop_customer("Carlos", "Find Saffron for at most 8 credits", spice_stalls, policy, log, root.id, now, provider, model, dash, false)
                                  let _sl3 := time.sleep_ms(3000)

                                  let _done := post_ui(dash, "{\"kind\":\"done\"}")
                                  let _pf1 := io.print("══════════════════════════════════════════════════════")
                                  io.print("   RUSH HOUR COMPLETE  —  check http://localhost:8900")
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
