# examples/bazaar_two_sided.lex — both sides agents in one session.
#
# Increment 6 of the Governed Agent Bazaar (#45): an LLM BUYER shops a market
# whose prices are set by LLM SELLERS. First each seller LLM quotes its item by
# personality (src/seller_llm: Karim fair, Lena max-profit, Spice premium) against
# the buyer's revealed ceiling. Then an LLM buyer reasons over that catalog —
# value vs the agent-set price — and buys under its capability-bounded budget.
# Greedy sellers price themselves out: a quote over the buyer's per-transaction
# cap is refused by lex-guard's gate, and a smart buyer avoids bad value anyway.
# Same hash-chained trail, verified by gbazaar.
#
# Env: BOT_MODEL (opencode-go model, default glm-5.1), OPENCODE_API_KEY (required),
#      BAZAAR_TRAIL (default bazaar_two_sided_trail.jsonl), BUYER_TURNS (default 8)
# Run: OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) \
#        lex run --allow-effects crypto,env,fs_write,io,llm,net,proc,sql,time \
#        examples/bazaar_two_sided.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.iter" as iter

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.env" as env

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-guard/src/models" as models

import "lex-guard/src/gate" as gate

import "lex-guard/src/x402_mock_exec" as x402m

import "lex-games/src/arena/trail_file" as tf

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/message" as msg

import "lex-llm/src/delta" as d

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers/openai" as oai

import "../src/seller_llm" as sllm

# A stall: `kind` selects the seller's pricing personality; `base` is its cost;
# `value` is the buyer's private utility; `price` is filled by the seller LLM.
type Stall = { kind :: Str, merchant :: Str, pay_to :: Str, item :: Str, base :: Int, value :: Int, price :: Int }

fn seed_stalls() -> List[Stall] {
  [{ kind: "pottery", merchant: "pottery.bazaar", pay_to: "PotterySoLAddr11111111111111111111111111111", item: "hand-thrown bowl", base: 1500, value: 20, price: 0 }, { kind: "textile", merchant: "textile.bazaar", pay_to: "TextileSoLAddr22222222222222222222222222222", item: "woven scarf", base: 1800, value: 24, price: 0 }, { kind: "spices", merchant: "spice.bazaar", pay_to: "SpiceSoLAddr33333333333333333333333333333333", item: "rare saffron", base: 1200, value: 18, price: 0 }, { kind: "books", merchant: "books.bazaar", pay_to: "BooksSoLAddr55555555555555555555555555555555", item: "illuminated codex", base: 900, value: 14, price: 0 }]
}

fn revealed_ceiling() -> Int {
  4000
}

fn buyer_policy() -> models.Policy {
  { token_id: "tok_two_sided", agent_id: "shopper", currency: "USDC", cap_total: 6000, cap_per_day: 6000, cap_per_transaction: 2500, merchants_allow: ["pottery.bazaar", "textile.bazaar", "spice.bazaar", "books.bazaar"], categories_allow: ["goods", "saas"], max_tx_per_hour: 50, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "ShopperSoLAddr666666666666666666666666666666" }
}

fn usdc_mint() -> Str {
  "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}

fn opencode_zen_url() -> Str {
  "https://opencode.ai/zen/go/v1/chat/completions"
}

fn budget_opened_json(p :: models.Policy) -> Str {
  let allow := str.join(list.map(p.merchants_allow, fn (m :: Str) -> Str {
    str.join(["\"", m, "\""], "")
  }), ",")
  str.join(["{\"agent\":\"", p.agent_id, "\",\"currency\":\"USDC\",\"cap_total\":", int.to_str(p.cap_total), ",\"cap_per_transaction\":", int.to_str(p.cap_per_transaction), ",\"merchants_allow\":[", allow, "]}"], "")
}

fn intent_for(s :: Stall) -> models.SpendIntent {
  { merchant: s.merchant, amount: s.price, currency: "USDC", category: "goods", memo: s.item }
}

# ── quote phase: each seller LLM prices its own item ─────────────────────────
fn quote_all(key :: Str, model :: Str, stalls :: List[Stall]) -> [io, llm, net, proc] List[Stall] {
  list.map(stalls, fn (s :: Stall) -> [io, llm, net, proc] Stall {
    let q := sllm.quote_price(s.kind, s.item, s.item, s.base, revealed_ceiling(), key, "", "", "opencode", model)
    { kind: s.kind, merchant: s.merchant, pay_to: s.pay_to, item: s.item, base: s.base, value: s.value, price: q }
  })
}

# ── list helpers ─────────────────────────────────────────────────────────────
fn nth_stall(xs :: List[Stall], i :: Int) -> Stall {
  match list.head(xs) {
    None => { kind: "", merchant: "", pay_to: "", item: "", base: 0, value: 0, price: 0 },
    Some(h) => if i <= 0 {
      h
    } else {
      nth_stall(list.tail(xs), i - 1)
    },
  }
}

fn nth_bool(xs :: List[Bool], i :: Int) -> Bool {
  match list.head(xs) {
    None => false,
    Some(h) => if i <= 0 {
      h
    } else {
      nth_bool(list.tail(xs), i - 1)
    },
  }
}

fn set_nth_bool(xs :: List[Bool], i :: Int, v :: Bool) -> List[Bool] {
  match list.head(xs) {
    None => [],
    Some(h) => if i <= 0 {
      list.concat([v], list.tail(xs))
    } else {
      list.concat([h], set_nth_bool(list.tail(xs), i - 1, v))
    },
  }
}

# ── prompt + reply parsing (the buyer side) ──────────────────────────────────
type Idx = { i :: Int, acc :: Str }

fn list_items(cat :: List[Stall], owned :: List[Bool]) -> Str {
  let r := list.fold(cat, { i: 0, acc: "" }, fn (a :: Idx, s :: Stall) -> Idx {
    let tag := if nth_bool(owned, a.i) {
      " (BOUGHT)"
    } else {
      ""
    }
    let line := str.join(["  ", int.to_str(a.i), ": ", s.merchant, " — ", s.item, " — price ", int.to_str(s.price), ", value ", int.to_str(s.value), tag, "\n"], "")
    { i: a.i + 1, acc: str.join([a.acc, line], "") }
  })
  r.acc
}

fn build_prompt(cat :: List[Stall], owned :: List[Bool], spent :: Int, cap :: Int, history :: Str) -> Str {
  str.join(["You are a buyer agent at a bazaar. Budget: ", int.to_str(cap), " USDC; spent so far ", int.to_str(spent), " (", int.to_str(cap - spent), " left).\n\nStalls (index: merchant — item — price — value). Prices were set by the sellers themselves:\n", list_items(cat, owned), "\nBuy the best value for money you can afford. Note: your payment token may refuse certain merchants or amounts — if a purchase is DENIED, pick something else.\n", "Reply with EXACTLY one line: PICK:<index> to buy that stall, or PICK:STOP when you're done."], "")
}

fn extract_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDone(m) => match m {
        AssistantMsg(text, _) => text,
        _ => acc,
      },
      _ => acc,
    }
  })
}

fn parse_pick(text :: Str) -> Int {
  let lo := str.to_lower(text)
  list.fold(str.split(lo, "\n"), 0 - 1, fn (acc :: Int, line :: Str) -> Int {
    match str.strip_prefix(str.trim(line), "pick:") {
      None => acc,
      Some(rest) => {
        let r := str.trim(rest)
        if str.starts_with(r, "stop") {
          0 - 1
        } else {
          match str.to_int(r) {
            Some(n) => n,
            None => acc,
          }
        }
      },
    }
  })
}

fn short_reason(r :: Str) -> Str {
  if str.contains(r, "total cap") {
    "exceeds total budget"
  } else {
    if str.contains(r, "merchant") or str.contains(r, "predicate") {
      "over per-purchase cap / merchant not allowed"
    } else {
      r
    }
  }
}

# ── the buyer's shopping loop ────────────────────────────────────────────────
fn shop(pol :: models.Policy, log :: trail.Log, agent :: llm_agent.AgentLoop, cat :: List[Stall], owned :: List[Bool], spent :: Int, history :: Str, turn :: Int, maxt :: Int) -> [io, sql, time, net, crypto, llm, proc, fs_write] Nil {
  if turn >= maxt {
    io.print("  (turn limit reached)")
  } else {
    let steps := iter.to_list(llm_agent.run_loop(agent, [UserMsg(build_prompt(cat, owned, spent, pol.cap_total, history))]))
    let pick := parse_pick(extract_text(steps))
    if pick < 0 or pick >= list.len(cat) {
      io.print("  buyer is done.")
    } else {
      if nth_bool(owned, pick) {
        shop(pol, log, agent, cat, owned, spent, str.join([history, "  (already owns ", int.to_str(pick), ")\n"], ""), turn + 1, maxt)
      } else {
        let s := nth_stall(cat, pick)
        let exec := x402m.make(signer(), s.pay_to, usdc_mint())
        match gate.spend(pol, log, exec, intent_for(s)) {
          Err(e) => io.print(str.concat("  gate error: ", e)),
          Ok(o) => if o.approved {
            let __d1 := io.print(str.join(["  ✓ bought ", s.merchant, " (", s.item, ") ", int.to_str(s.price), " USDC — settled"], ""))
            shop(pol, log, agent, cat, set_nth_bool(owned, pick, true), spent + s.price, str.join([history, "  ✓ ", s.merchant, " ", int.to_str(s.price), " (value ", int.to_str(s.value), ")\n"], ""), turn + 1, maxt)
          } else {
            let __d2 := io.print(str.join(["  ✗ ", s.merchant, " ", int.to_str(s.price), " — DENIED: ", short_reason(o.denial_reason)], ""))
            shop(pol, log, agent, cat, owned, spent, str.join([history, "  ✗ ", s.merchant, " ", int.to_str(s.price), " DENIED (over cap / not allowed)\n"], ""), turn + 1, maxt)
          },
        }
      }
    }
  }
}

fn run() -> [io, sql, time, net, crypto, llm, proc, fs_write, env] Nil {
  let model_name := match env.get("BOT_MODEL") {
    Some(v) => v,
    None => "glm-5.1",
  }
  let key := match env.get("OPENCODE_API_KEY") {
    Some(v) => v,
    None => "",
  }
  let trail_path := match env.get("BAZAAR_TRAIL") {
    Some(v) => v,
    None => "bazaar_two_sided_trail.jsonl",
  }
  let maxt := match env.get("BUYER_TURNS") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 8,
    },
    None => 8,
  }
  if str.is_empty(key) {
    io.print("[bazaar] OPENCODE_API_KEY is required")
  } else {
    let __lex_discard_1 := io.print(str.join(["=== Magentic Bazaar — LLM sellers price, an LLM buyer shops (model=", model_name, ") ===\n"], ""))
    match trail.open_memory() {
      Err(e) => io.print(str.concat("trail open failed: ", e)),
      Ok(log) => {
        let pol := buyer_policy()
        let _b := match trail.append(log, "budget.opened", None, budget_opened_json(pol)) {
          Err(e) => io.print(str.concat("budget.opened write failed: ", e)),
          Ok(_) => io.print(str.join(["buyer per-purchase cap = ", int.to_str(pol.cap_per_transaction), " USDC; sellers were told the ceiling is ", int.to_str(revealed_ceiling()), "\n"], "")),
        }
        let _q := io.print("— sellers quote —")
        let cat := quote_all(key, model_name, seed_stalls())
        let _ql := list.fold(cat, 0, fn (n :: Int, s :: Stall) -> [io] Int {
          let __lex_discard_2 := io.print(str.join(["  ", s.merchant, ": ", int.to_str(s.price), " (base ", int.to_str(s.base), ")"], ""))
          n + 1
        })
        let _sh := io.print("\n— buyer shops —")
        let provider := oai.make_provider({ api_key: key, base_url: opencode_zen_url() })
        let model := prov.make_model_ref("opencode-go", model_name)
        let opts := { temperature: Some(0.3), top_p: None, max_steps: Some(1), max_tokens: Some(2500) }
        let system := str.join(["You are a shrewd buyer agent in a bazaar. Prices are set by the sellers (some greedy). ", "Buy the best value for money within a capability-bounded budget token that may refuse some merchants or amounts. ", "Adapt when denied; stop when nothing is worth buying. Always answer EXACTLY: PICK:<index> or PICK:STOP."], "")
        let agent := llm_agent.make_agent("llm-buyer", system, model, provider, [], opts)
        let _shop := shop(pol, log, agent, cat, [false, false, false, false], 0, "", 0, maxt)
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

