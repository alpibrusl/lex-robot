# src/haggle.lex — multi-round price negotiation between two LLM agents.
#
# Where seller_llm.quote_price is a single quote, this is a back-and-forth: the
# seller opens with an ASK, the buyer counters with an OFFER, and they alternate
# until someone ACCEPTs, someone WALKs, or the ranges cross (a deal). Each side
# has a goal in tension — the seller maximises price above its base cost; the
# buyer minimises price under a secret max budget — and a sale beats no sale.
#
# Deterministic convergence guards (offer ≥ ask → deal; ask ≤ offer → deal; a
# round cap → impasse) guarantee the loop terminates regardless of the models.
#
# Provider-agnostic: pass any lex-llm provider + model (local via LiteLLM or
# Vertex). Reuses seller_llm's personalities + reply parser.
#
# Effects: [net, llm, io, proc]

import "std.str"  as str
import "std.int"  as int
import "std.iter" as iter
import "std.io"   as io

import "lex-llm/src/agent"     as llm_agent
import "lex-llm/src/message"   as msg
import "lex-llm/src/provider"  as prov

import "./seller_llm" as sllm

type SellerMove = SAsk(Int) | SAccept | SWalk
type BuyerMove  = BOffer(Int) | BAccept | BWalk
type Deal = { closed :: Bool, price :: Int, rounds :: Int, reason :: Str }

# ── one LLM turn (no tools, one short reply) ──────────────────────────────────
fn one_turn(provider :: prov.Provider, model :: prov.ModelRef, system_msg :: Str, user_msg :: Str) -> [net, llm, io, proc] Str {
  let opts  := { temperature: Some(0.6), top_p: None, max_steps: Some(1), max_tokens: Some(64) }
  let agent := llm_agent.make_agent("haggle", system_msg, model, provider, [], opts)
  let steps := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user_msg)]))
  sllm.extract_text(steps)
}

# Pull the integer after a lowercase tag (e.g. "ask:") from a one-line reply.
fn tagged_int(text_lower :: Str, tag :: Str, fallback :: Int) -> Int {
  let lines := str.split(text_lower, "\n")
  list.fold(lines, fallback, fn (acc :: Int, line :: Str) -> Int {
    match str.strip_prefix(str.trim(line), tag) {
      None => acc,
      Some(rest) => match str.to_int(str.trim(rest)) { Some(n) => if n >= 0 { n } else { acc }, None => acc },
    }
  })
}

fn parse_seller(text :: Str, prev :: Int) -> SellerMove {
  let lo := str.to_lower(text)
  if str.contains(lo, "accept") { SAccept } else {
  if str.contains(lo, "walk")   { SWalk }   else { SAsk(tagged_int(lo, "ask:", prev)) }}
}

fn parse_buyer(text :: Str, prev :: Int) -> BuyerMove {
  let lo := str.to_lower(text)
  if str.contains(lo, "accept") { BAccept } else {
  if str.contains(lo, "walk")   { BWalk }   else { BOffer(tagged_int(lo, "offer:", prev)) }}
}

# ── the two negotiators ───────────────────────────────────────────────────────
fn seller_system(persona :: Str) -> Str {
  str.join([persona, "\n\n",
    "You are haggling over ONE item. Reply with EXACTLY one line and nothing else:\n",
    "  ASK:<int>   to name/counter your price (never below your base cost)\n",
    "  ACCEPT      to take the buyer's current offer\n",
    "  WALK        to refuse the sale\n",
    "Each round, move your ASK DOWN toward the buyer's offer to close the gap — never repeat your previous number. ",
    "ACCEPT as soon as the offer clears your cost; a modest margin secured beats holding out for one more credit."], "")
}

fn seller_turn(provider :: prov.Provider, model :: prov.ModelRef, persona :: Str, item :: Str, base :: Int, offer :: Int, prev_ask :: Int) -> [net, llm, io, proc] SellerMove {
  let u := if offer < 0 {
    str.join(["Item: \"", item, "\". Your base cost: ", int.to_str(base), ". The buyer hasn't offered yet — state your opening ASK:<int>."], "")
  } else {
    str.join(["Item: \"", item, "\". Your base cost: ", int.to_str(base), ". The buyer's current offer is ", int.to_str(offer), ". Respond ASK:<int> / ACCEPT / WALK."], "")
  }
  parse_seller(one_turn(provider, model, seller_system(persona), u), prev_ask)
}

fn buyer_system() -> Str {
  str.join([
    "You are a thrifty shopper haggling for ONE item you genuinely want.\n",
    "Your secret max budget is fixed — NEVER reveal it and NEVER offer above it.\n",
    "Reply with EXACTLY one line and nothing else:\n",
    "  OFFER:<int>  a counter at or below your budget\n",
    "  ACCEPT       to pay the seller's current ask\n",
    "  WALK         to leave empty-handed\n",
    "Each round, raise your OFFER toward the seller's ask to close — never repeat your previous number. ",
    "You genuinely want the item: ACCEPT a fair ask that sits well within budget rather than lose the deal over a credit or two."], "")
}

fn buyer_turn(provider :: prov.Provider, model :: prov.ModelRef, item :: Str, budget :: Int, ask :: Int, prev_offer :: Int) -> [net, llm, io, proc] BuyerMove {
  let u := str.join(["Item: \"", item, "\". Your secret max budget: ", int.to_str(budget), ". The seller's current ask is ", int.to_str(ask), ". Respond OFFER:<int> / ACCEPT / WALK."], "")
  parse_buyer(one_turn(provider, model, buyer_system(), u), prev_offer)
}

# ── the negotiation loop ──────────────────────────────────────────────────────
# Good-faith concession protocol: each round the buyer's offer rises by at least
# 1 (never above the ask or its budget) and the seller's ask drops by at least 1
# (never below its base cost or the live offer). The LLMs still choose how far to
# concede and when to ACCEPT/WALK, but the bargaining gap shrinks ≥2 per round, so
# an overlapping zone always closes within the round cap.
fn mn(a :: Int, b :: Int) -> Int { if a < b { a } else { b } }
fn mx(a :: Int, b :: Int) -> Int { if a > b { a } else { b } }
fn lohi(v :: Int, lo :: Int, hi :: Int) -> Int { if v < lo { lo } else { if v > hi { hi } else { v } } }

fn loop(provider :: prov.Provider, model :: prov.ModelRef, persona :: Str, item :: Str, base :: Int, budget :: Int, max_rounds :: Int, ask :: Int, last_offer :: Int, round :: Int) -> [net, llm, io, proc] Deal {
  if round > max_rounds {
    { closed: false, price: 0, rounds: round - 1, reason: "impasse — no deal after the round cap" }
  } else {
    let bm := buyer_turn(provider, model, item, budget, ask, mx(last_offer, 0))
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
      let sm := seller_turn(provider, model, persona, item, base, eff_offer, ask)
      let seller_walk := match sm { SWalk => true, _ => false }
      let seller_take := match sm { SAccept => true, _ => false }
      let raw_ask  := match sm { SAsk(a) => a, _ => ask }
      let floor_a := mx(base, eff_offer)
      let ceil_a  := mx(ask - 1, floor_a)
      let eff_ask := lohi(raw_ask, floor_a, ceil_a)
      let _sl := io.print(str.join(["  round ", int.to_str(round), " · seller: ",
        match sm { SAccept => str.concat("ACCEPT @ ", int.to_str(eff_offer)), SWalk => "WALK", SAsk(_) => str.concat("ASK ", int.to_str(eff_ask)) }], ""))
      if seller_walk {
        { closed: false, price: 0, rounds: round, reason: "seller walked away" }
      } else { if seller_take {
        { closed: true, price: eff_offer, rounds: round, reason: "seller accepted the buyer's offer" }
      } else { if eff_ask <= eff_offer {
        { closed: true, price: eff_ask, rounds: round, reason: "seller met the offer" }
      } else {
        loop(provider, model, persona, item, base, budget, max_rounds, eff_ask, eff_offer, round + 1)
      }}}
    }}}
  }
}

# Negotiate one item at one stall. `stall` selects the seller's personality.
fn negotiate(provider :: prov.Provider, model :: prov.ModelRef, stall :: Str, item :: Str, base :: Int, budget :: Int, max_rounds :: Int) -> [net, llm, io, proc] Deal {
  let persona := sllm.stall_personality(stall)
  let _ := io.print(str.join(["── haggle: \"", item, "\" at ", stall, "  (base cost ", int.to_str(base), ", buyer max ", int.to_str(budget), ", ≤", int.to_str(max_rounds), " rounds) ──"], ""))
  let open := seller_turn(provider, model, persona, item, base, 0 - 1, base)
  match open {
    SWalk    => { closed: false, price: 0, rounds: 0, reason: "seller refused to open" },
    SAccept  => loop(provider, model, persona, item, base, budget, max_rounds, base, 0 - 1, 1),
    SAsk(a)  => {
      let a0 := if a < base { base } else { a }
      let _ := io.print(str.join(["  round 0 · seller opens: ASK ", int.to_str(a0)], ""))
      loop(provider, model, persona, item, base, budget, max_rounds, a0, 0 - 1, 1)
    },
  }
}
