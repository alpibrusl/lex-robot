# examples/bazaar_market.lex — the Magentic Bazaar (governed agent commerce).
#
# A buyer agent shops across seller stalls. Every purchase is gated by a signed
# budget POLICY (per-transaction cap, total cap, merchant allow-list) and, when
# allowed, settled over the x402 Solana `exact` rail (mock facilitator) — and
# EVERY step is attested to a hash-chained lex-trail. So the session is a
# tamper-evident, independently verifiable record of governed transactions.
#
# This is the core of the Governed Agent Bazaar epic (#45): not the negotiation
# cleverness, but the GOVERNANCE + VERIFIABILITY of the transaction. Concurrency
# and LLM-driven haggling layer on top later. The emitted trail is replayed and
# ranked by lex-games' gbazaar verifier (examples/bazaar_verify.lex).
#
# Env: BAZAAR_TRAIL (trail output path, default bazaar_trail.jsonl)
# Run: lex run --allow-effects io,sql,time,net,crypto,fs_write,env examples/bazaar_market.lex run

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

# A stall = a seller the buyer can pay. `merchant` is the policy identity (what
# the allow-list and trail key on); `pay_to` is its Solana settlement address.
type Stall = { merchant :: Str, pay_to :: Str, category :: Str, item :: Str, amount :: Int }

# What the buyer tries to buy, in order. A scripted shopper for this slice —
# an LLM buyer is a later increment; the point here is the governance wall.
fn shopping_list() -> List[Stall] {
  [{ merchant: "pottery.bazaar", pay_to: "PotterySoLAddr11111111111111111111111111111", category: "goods", item: "hand-thrown bowl", amount: 1800 }, { merchant: "textile.bazaar", pay_to: "TextileSoLAddr22222222222222222222222222222", category: "goods", item: "woven scarf", amount: 2600 }, { merchant: "data.bazaar", pay_to: "DataSoLAddr444444444444444444444444444444444", category: "saas", item: "1M embeddings", amount: 1200 }, { merchant: "scam.bazaar", pay_to: "ScamSoLAddr555555555555555555555555555555555", category: "goods", item: "too-good-to-be-true rug", amount: 500 }, { merchant: "spice.bazaar", pay_to: "SpiceSoLAddr33333333333333333333333333333333", category: "goods", item: "saffron tin", amount: 3400 }, { merchant: "pottery.bazaar", pay_to: "PotterySoLAddr11111111111111111111111111111", category: "goods", item: "second bowl", amount: 1800 }]
}

# The buyer's signed budget. merchants_allow deliberately EXCLUDES scam.bazaar
# (an unknown seller) and spice.bazaar; caps are tight so the wall is visible.
fn buyer_policy() -> models.Policy {
  { token_id: "tok_bazaar", agent_id: "shopper-agent", currency: "USDC", cap_total: 6000, cap_per_day: 6000, cap_per_transaction: 3000, merchants_allow: ["pottery.bazaar", "textile.bazaar", "data.bazaar"], categories_allow: ["goods", "saas"], max_tx_per_hour: 50, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "ShopperSoLAddr666666666666666666666666666666" }
}

fn usdc_mint() -> Str {
  "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}

# The policy snapshot recorded as the first trail event, so the verifier can
# re-check every settlement against the SAME budget the buyer committed to —
# self-contained governance, tamper-evident with the rest of the trail.
fn budget_opened_json(p :: models.Policy) -> Str {
  let allow := str.join(list.map(p.merchants_allow, fn (m :: Str) -> Str {
    str.join(["\"", m, "\""], "")
  }), ",")
  str.join(["{\"agent\":\"", p.agent_id, "\",\"currency\":\"", p.currency, "\",\"cap_total\":", int.to_str(p.cap_total), ",\"cap_per_transaction\":", int.to_str(p.cap_per_transaction), ",\"merchants_allow\":[", allow, "]}"], "")
}

fn intent_for(s :: Stall) -> models.SpendIntent {
  { merchant: s.merchant, amount: s.amount, currency: "USDC", category: s.category, memo: s.item }
}

# Attempt one purchase through the gate; print + return the outcome line.
fn buy(pol :: models.Policy, log :: trail.Log, s :: Stall) -> [io, sql, time, net] Str {
  let exec := x402m.make(signer(), s.pay_to, usdc_mint())
  match gate.spend(pol, log, exec, intent_for(s)) {
    Err(e) => str.join(["  ✗ ", s.merchant, " ", int.to_str(s.amount), " — ERROR ", e], ""),
    Ok(o) => if o.approved {
      str.join(["  ✓ ", s.merchant, " ", int.to_str(s.amount), " USDC — settled tx=", str.slice(o.executor_ref, 0, 16), "…"], "")
    } else {
      str.join(["  ✗ ", s.merchant, " ", int.to_str(s.amount), " USDC — DENIED: ", o.denial_reason], "")
    },
  }
}

fn run() -> [io, sql, time, net, crypto, fs_write, env] Nil {
  let trail_path := match env.get("BAZAAR_TRAIL") {
    Some(v) => v,
    None => "bazaar_trail.jsonl",
  }
  let __lex_discard_1 := io.print("=== Magentic Bazaar — governed agent commerce (x402 mock settlement) ===")
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let pol := buyer_policy()
      let _b := match trail.append(log, "budget.opened", None, budget_opened_json(pol)) {
        Err(e) => io.print(str.concat("budget.opened write failed: ", e)),
        Ok(_) => io.print(str.join(["budget: agent=", pol.agent_id, " cap_total=", int.to_str(pol.cap_total), " per-tx=", int.to_str(pol.cap_per_transaction), " allow=", str.join(pol.merchants_allow, ",")], "")),
      }
      let _h := io.print("")
      let _walk := list.fold(shopping_list(), 0, fn (n :: Int, s :: Stall) -> [io, sql, time, net] Int {
        let _line := io.print(buy(pol, log, s))
        n + 1
      })
      match trail.range(log, 0, 9999999999999) {
        Err(e) => io.print(str.concat("trail read failed: ", e)),
        Ok(evs) => {
          let jsonl := tf.to_jsonl(list.map(evs, tf.from_event))
          let _w := io.write(trail_path, jsonl)
          io.print(str.join(["\nwrote ", int.to_str(list.len(evs)), " trail events → ", trail_path], ""))
        },
      }
    },
  }
}

