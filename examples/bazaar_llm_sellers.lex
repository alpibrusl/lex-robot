# examples/bazaar_llm_sellers.lex — both sides are agents: LLM-priced sellers.
#
# Increment 5 of the Governed Agent Bazaar (#45). Until now sellers had fixed
# prices. Here each seller is an LLM with a pricing PERSONALITY (src/seller_llm:
# Master Karim prices fair near-cost, Merchant Lena grabs most of the buyer's
# stated budget, the Spice Trader charges a premium). The buyer reveals a budget
# CEILING to the sellers — but its real signed token has a LOWER per-transaction
# cap. So when a greedy seller quotes above that cap, lex-guard's spend gate
# DENIES the purchase: governance protects the buyer from being gouged, even
# against an adversarial pricing agent. Affordable, allow-listed quotes settle
# over x402 (mock) onto the hash-chained trail, verified by gbazaar as before.
#
# Env: BOT_MODEL (opencode-go model, default glm-5.1), OPENCODE_API_KEY (required),
#      BAZAAR_TRAIL (trail output, default bazaar_llm_sellers_trail.jsonl)
# Run: OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) \
#        lex run --allow-effects crypto,env,fs_write,io,llm,net,proc,sql,time \
#        examples/bazaar_llm_sellers.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.env" as env

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-guard/src/models" as models

import "lex-guard/src/gate" as gate

import "lex-guard/src/x402_mock_exec" as x402m

import "lex-games/src/arena/trail_file" as tf

import "../src/seller_llm" as sllm

# A seller stall. `kind` selects the LLM pricing personality (pottery=Karim,
# textile=Lena, spices=Spice Trader); `base` is its private cost.
type Stall = { kind :: Str, merchant :: Str, pay_to :: Str, item_id :: Str, item_name :: Str, base :: Int }

fn stalls() -> List[Stall] {
  [{ kind: "pottery", merchant: "pottery.bazaar", pay_to: "PotterySoLAddr11111111111111111111111111111", item_id: "bowl-1", item_name: "hand-thrown bowl", base: 1500 }, { kind: "textile", merchant: "textile.bazaar", pay_to: "TextileSoLAddr22222222222222222222222222222", item_id: "scarf-1", item_name: "woven scarf", base: 1800 }, { kind: "spices", merchant: "spice.bazaar", pay_to: "SpiceSoLAddr33333333333333333333333333333333", item_id: "saffron-1", item_name: "rare saffron", base: 1200 }]
}

# The buyer reveals this ceiling to sellers — but its token's real per-transaction
# cap is lower, so a greedy quote above the cap is refused by the gate.
fn revealed_ceiling() -> Int {
  4000
}

fn buyer_policy() -> models.Policy {
  { token_id: "tok_llm_market", agent_id: "shopper", currency: "USDC", cap_total: 8000, cap_per_day: 8000, cap_per_transaction: 2500, merchants_allow: ["pottery.bazaar", "textile.bazaar", "spice.bazaar"], categories_allow: ["goods", "saas"], max_tx_per_hour: 50, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "ShopperSoLAddr666666666666666666666666666666" }
}

fn usdc_mint() -> Str {
  "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}

fn budget_opened_json(p :: models.Policy) -> Str {
  let allow := str.join(list.map(p.merchants_allow, fn (m :: Str) -> Str {
    str.join(["\"", m, "\""], "")
  }), ",")
  str.join(["{\"agent\":\"", p.agent_id, "\",\"currency\":\"USDC\",\"cap_total\":", int.to_str(p.cap_total), ",\"cap_per_transaction\":", int.to_str(p.cap_per_transaction), ",\"merchants_allow\":[", allow, "]}"], "")
}

fn persona(kind :: Str) -> Str {
  if kind == "pottery" {
    "Master Karim (fair)"
  } else {
    if kind == "textile" {
      "Merchant Lena (max profit)"
    } else {
      "Spice Trader (premium)"
    }
  }
}

# One trade: the seller LLM quotes, then the buyer tries to pay under its policy.
fn trade(pol :: models.Policy, log :: trail.Log, key :: Str, model :: Str, s :: Stall) -> [io, sql, time, net, crypto, llm, proc] Int {
  let quote := sllm.quote_price(s.kind, s.item_id, s.item_name, s.base, revealed_ceiling(), key, "", "", "opencode", model)
  let exec := x402m.make(signer(), s.pay_to, usdc_mint())
  let intent := { merchant: s.merchant, amount: quote, currency: "USDC", category: "goods", memo: s.item_name }
  match gate.spend(pol, log, exec, intent) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("  gate error: ", e))
      0
    },
    Ok(o) => if o.approved {
      let __lex_discard_2 := io.print(str.join(["  ", persona(s.kind), " quoted ", int.to_str(quote), " (base ", int.to_str(s.base), ") → BOUGHT — settled"], ""))
      1
    } else {
      let __lex_discard_3 := io.print(str.join(["  ", persona(s.kind), " quoted ", int.to_str(quote), " (base ", int.to_str(s.base), ") → DENIED: over the buyer's ", int.to_str(pol.cap_per_transaction), " per-purchase cap"], ""))
      0
    },
  }
}

fn run() -> [io, sql, time, net, crypto, llm, proc, fs_write, env] Nil {
  let model := match env.get("BOT_MODEL") {
    Some(v) => v,
    None => "glm-5.1",
  }
  let key := match env.get("OPENCODE_API_KEY") {
    Some(v) => v,
    None => "",
  }
  let trail_path := match env.get("BAZAAR_TRAIL") {
    Some(v) => v,
    None => "bazaar_llm_sellers_trail.jsonl",
  }
  if str.is_empty(key) {
    io.print("[bazaar] OPENCODE_API_KEY is required")
  } else {
    let __lex_discard_4 := io.print(str.join(["=== Magentic Bazaar — LLM-priced sellers vs a governed buyer (model=", model, ") ===\n", "buyer reveals a ", int.to_str(revealed_ceiling()), " ceiling, but its token caps each purchase at 2500 —\n", "a seller that prices above that is refused by the gate, not by trust.\n"], ""))
    match trail.open_memory() {
      Err(e) => io.print(str.concat("trail open failed: ", e)),
      Ok(log) => {
        let pol := buyer_policy()
        let _b := match trail.append(log, "budget.opened", None, budget_opened_json(pol)) {
          Err(e) => io.print(str.concat("budget.opened write failed: ", e)),
          Ok(_) => io.print(""),
        }
        let _trades := list.fold(stalls(), 0, fn (n :: Int, s :: Stall) -> [io, sql, time, net, crypto, llm, proc] Int {
          n + trade(pol, log, key, model, s)
        })
        match trail.range(log, 0, 9999999999999) {
          Err(e) => io.print(str.concat("trail read failed: ", e)),
          Ok(evs) => {
            let _w := io.write(trail_path, tf.to_jsonl(list.map(evs, tf.from_event)))
            io.print(str.join(["\nwrote ", int.to_str(list.len(evs)), " trail events → ", trail_path], ""))
          },
        }
      },
    }
  }
}

