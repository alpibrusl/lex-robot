# src/seller_llm.lex — Autonomous seller agent for bazaar stall sidecars.
#
# Each stall has a distinct pricing personality. When SELLER_LLM=1, the
# stall sidecar calls quote_price on every query_stock hit so the seller
# actively decides what to charge based on the buyer's budget.
#
# The seller runs a single LLM turn (no tools, max_tokens=128) so it can't
# stall the response — it either answers with PRICE:<n> or we fall back to
# the base price.
#
# Effects: [net, llm, io, proc]

import "std.str"  as str
import "std.list" as list
import "std.int"  as int
import "std.iter" as iter
import "std.io"   as io

import "lex-llm/src/agent"            as llm_agent
import "lex-llm/src/message"          as msg
import "lex-llm/src/delta"            as d
import "lex-llm/src/providers/vertex" as vtx

# ── Seller personalities ──────────────────────────────────────────────────────

fn stall_personality(stall :: Str) -> Str {
  if stall == "pottery" or stall == "clay" {
    "You are Master Karim, the artisan potter of Pottery Palace. Your handcrafted ceramics reflect skill and care. You price fairly — slightly above cost to honour your craft. You won't undersell quality work, but you avoid exploiting buyers."
  } else {
  if stall == "textile" or stall == "fabric" {
    "You are Merchant Lena of Textile Traders. You are a sharp businessperson focused on maximum profit. You know buyers compare stalls, so you price high but stay within reach — typically capturing 80-90 percent of the buyer's stated budget."
  } else {
  if stall == "spices" or stall == "herb" {
    "You are the Exotic Spice Trader of Spice Garden, dealer in rare commodities. You project exclusivity and price accordingly — 20-40 percent above base price when the buyer has budget for it. A sale is good, but undervaluing your goods is a waste."
  } else {
    "You are a bazaar vendor. Price your goods to maximise profit while ensuring a sale."
  }}}
}

# ── Response parsing ──────────────────────────────────────────────────────────

fn extract_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDone(m) => match m { AssistantMsg(text, _) => text, _ => acc },
      _ => acc,
    }
  })
}

fn extract_price(text :: Str, fallback :: Int) -> Int {
  let lines := str.split(text, "\n")
  list.fold(lines, fallback, fn (acc :: Int, line :: Str) -> Int {
    let trimmed := str.trim(line)
    match str.strip_prefix(trimmed, "PRICE:") {
      None => acc,
      Some(rest) => match str.to_int(str.trim(rest)) {
        None => acc,
        Some(n) => if n >= 1 { n } else { acc },
      },
    }
  })
}

# ── Pricing decision ──────────────────────────────────────────────────────────
#
# Makes one LLM turn to decide the asking price for an item.
# Falls back to base_price if the token is missing or the model gives no price.

fn quote_price(stall :: Str, item_id :: Str, item_name :: Str, base_price :: Int, buyer_max :: Int, token :: Str, project :: Str, location :: Str) -> [net, llm, io, proc] Int {
  if str.is_empty(token) or str.is_empty(project) {
    base_price
  } else {
    let personality := stall_personality(stall)
    let system_msg  := str.join([
      personality, "\n\n",
      "When asked to price an item, respond with EXACTLY one line: PRICE:<integer>\n",
      "Example: PRICE:11\n",
      "No other text."
    ], "")
    let user_msg := str.join([
      "Item: \"", item_name, "\"  (ID: ", item_id, ")\n",
      "Your base cost: ", int.to_str(base_price), " credits\n",
      "Buyer's budget ceiling: ", int.to_str(buyer_max), " credits\n\n",
      "What is your asking price? (Must be ≥ 1. If above the buyer's ceiling they won't buy.)\n",
      "Respond: PRICE:<integer>"
    ], "")
    let provider := vtx.make_provider(vtx.config_at(token, project, location))
    let model    := vtx.gemini_35_flash()
    let opts     := { temperature: Some(0.7), top_p: None, max_steps: Some(1), max_tokens: Some(128) }
    let agent    := llm_agent.make_agent(stall, system_msg, model, provider, [], opts)
    let steps    := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user_msg)]))
    let text     := extract_text(steps)
    let quoted   := extract_price(text, base_price)
    let _log     := io.print(str.join(["  [", stall, " seller LLM] \"", item_name, "\" base=", int.to_str(base_price), " → quoted=", int.to_str(quoted)], ""))
    quoted
  }
}
