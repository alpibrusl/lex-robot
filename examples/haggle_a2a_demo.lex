# haggle_a2a_demo — DISTRIBUTED multi-round haggle: the buyer LLM runs here, the
# seller LLM runs inside a stall sidecar, and they negotiate over the wire.
#
# Each round the buyer (this process) picks an OFFER, POSTs it to the stall's
# `haggle` skill (POST <stall>/skill/haggle {name, base, offer}), and the stall's
# seller LLM replies {"decision":"counter|accept|walk","ask":N}. The buyer's
# good-faith concession (offer rises ≥1, capped at the ask/budget) guarantees an
# overlapping zone closes. This is the real auto_bazaar wiring — the same `haggle`
# skill the customer agent calls — exercised end to end with one stall.
#
# Run via examples/haggle_a2a_demo_run.sh (boots a pottery stall, no physics).

import "std.env"  as env
import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list

import "../src/client" as client
import "../src/haggle" as h

import "lex-llm/src/providers" as providers
import "lex-llm/src/provider"  as prov

fn mn(a :: Int, b :: Int) -> Int { if a < b { a } else { b } }
fn mx(a :: Int, b :: Int) -> Int { if a > b { a } else { b } }
fn lohi(v :: Int, lo :: Int, hi :: Int) -> Int { if v < lo { lo } else { if v > hi { hi } else { v } } }

# Pull the integer after "ask": from the stall's JSON reply (split, not regex).
fn first(parts :: List[Str], dflt :: Str) -> Str { match list.head(parts) { Some(x) => x, None => dflt } }
fn resp_ask(body :: Str, fallback :: Int) -> Int {
  match list.head(list.tail(str.split(body, "\"ask\":"))) {
    None => fallback,
    Some(rest) => {
      let a := first(str.split(rest, "}"), rest)       # drop trailing }
      let b := first(str.split(a, ","), a)             # drop any trailing fields
      match str.to_int(str.trim(b)) { Some(n) => n, None => fallback }
    },
  }
}
fn resp_decision(body :: Str) -> Str {
  let lo := str.to_lower(body)
  if str.contains(lo, "\"accept\"") { "accept" } else {
  if str.contains(lo, "\"walk\"")   { "walk" }   else { "counter" }}
}

fn loop(provider :: prov.Provider, model :: prov.ModelRef, url :: Str, item :: Str, base :: Int, budget :: Int, max_rounds :: Int, ask :: Int, last_offer :: Int, round :: Int) -> [net, llm, io, proc] h.Deal {
  if round > max_rounds {
    { closed: false, price: 0, rounds: round - 1, reason: "impasse — no deal after the round cap" }
  } else {
    let bm := h.buyer_turn(provider, model, item, budget, ask, mx(last_offer, 0))
    let buyer_walk := match bm { BWalk => true, _ => false }
    let buyer_take := match bm { BAccept => ask <= budget, _ => false }
    let raw_offer  := match bm { BOffer(o) => o, _ => 0 }
    let hi_o    := mn(ask, budget)
    let floor_o := if last_offer < 0 { 1 } else { mn(last_offer + 1, hi_o) }
    let eff_offer := lohi(raw_offer, floor_o, hi_o)
    let _bl := io.print(str.join(["  round ", int.to_str(round), " · buyer: ",
      match bm { BAccept => str.concat("ACCEPT @ ", int.to_str(ask)), BWalk => "WALK", BOffer(_) => str.concat("OFFER ", int.to_str(eff_offer)) }], ""))
    if buyer_walk {
      { closed: false, price: 0, rounds: round, reason: "buyer walked away" }
    } else { if buyer_take {
      { closed: true, price: ask, rounds: round, reason: "buyer accepted the seller's ask" }
    } else { if eff_offer >= ask {
      { closed: true, price: ask, rounds: round, reason: "buyer met the ask" }
    } else {
      # ── over the wire: ask the remote stall's seller LLM ──
      let body := match client.call(url, "haggle", str.join(["{\"name\":\"", item, "\",\"base\":", int.to_str(base), ",\"offer\":", int.to_str(eff_offer), "}"], "")) {
        Ok(b)  => b,
        Err(e) => str.concat("{\"decision\":\"walk\",\"ask\":0,\"err\":\"", e),
      }
      let dec  := resp_decision(body)
      let sask := resp_ask(body, base)
      let new_ask := if sask < base { base } else { sask }
      let _sl := io.print(str.join(["  round ", int.to_str(round), " · seller(", url, "): ",
        if dec == "accept" { str.concat("ACCEPT @ ", int.to_str(eff_offer)) } else { if dec == "walk" { "WALK" } else { str.concat("ASK ", int.to_str(new_ask)) } }], ""))
      if dec == "accept" {
        { closed: true, price: eff_offer, rounds: round, reason: "seller accepted the buyer's offer" }
      } else { if dec == "walk" {
        { closed: false, price: 0, rounds: round, reason: "seller walked away" }
      } else { if new_ask <= eff_offer {
        { closed: true, price: new_ask, rounds: round, reason: "seller met the offer" }
      } else {
        loop(provider, model, url, item, base, budget, max_rounds, new_ask, eff_offer, round + 1)
      }}}
    }}}
  }
}

fn run() -> [env, io, llm, net, proc] Int {
  let url    := match env.get("STALL_URL") { None => "http://localhost:8901", Some(v) => if str.is_empty(v) { "http://localhost:8901" } else { v } }
  let model_name := match env.get("LITELLM_MODEL") { None => "qwen3-coder:30b", Some(v) => if str.is_empty(v) { "qwen3-coder:30b" } else { v } }
  let provider := providers.litellm()
  let model    := prov.make_model_ref("litellm", model_name)
  let item := "Bowl"
  let base := 8
  let budget := 20
  let _ := io.print(str.join(["=== distributed haggle: buyer (here) ↔ seller (", url, ") on ", model_name, " ===\n",
    "Item \"", item, "\": base cost ", int.to_str(base), ", buyer secret max ", int.to_str(budget), ".\n"], ""))
  # Heuristic opening ask (the buyer's belief before the first offer); the real
  # asks come from the remote seller inside the loop.
  let open_ask := base + mx(2, (budget - base) / 3)
  let _o := io.print(str.join(["  round 0 · opening ask ~", int.to_str(open_ask), " (buyer will probe the seller)"], ""))
  let deal := loop(provider, model, url, item, base, budget, 8, open_ask, 0 - 1, 1)
  let _f := if deal.closed {
    io.print(str.join(["\n  ✓ DEAL at ", int.to_str(deal.price), " — ", deal.reason, " (", int.to_str(deal.rounds), " rounds)"], ""))
  } else {
    io.print(str.join(["\n  ✗ NO DEAL — ", deal.reason], ""))
  }
  0
}
