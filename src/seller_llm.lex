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
import "lex-llm/src/providers"        as providers
import "lex-llm/src/provider"         as prov
import "lex-llm/src/providers/vertex" as vtx
import "lex-llm/src/providers/openai" as oai

# OpenCode Zen "Go plan" — hosted open-weights models (deepseek-v4-*, qwen3.*,
# kimi-k2.6, glm-5.1, minimax-m3, mimo-v2-pro), OpenAI-compatible. Selected with
# base_url == "opencode"; the key is passed via the `token` param (read from
# OPENCODE_API_KEY by the caller, which holds the `env` effect — keeping this
# module pure so it still fits sim_sidecar's env-less router handler row).
fn opencode_zen_url() -> Str {
  "https://opencode.ai/zen/go/v1/chat/completions"
}

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

# Provider is local-first: a non-empty `base_url` (LITELLM_BASE_URL) runs the
# seller on a local model via the LiteLLM proxy; otherwise Vertex is used when
# token+project are present; otherwise we fall back to the base price.
fn quote_price(stall :: Str, item_id :: Str, item_name :: Str, base_price :: Int, buyer_max :: Int, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Int {
  let use_opencode := base_url == "opencode" and not str.is_empty(token)
  let use_local    := not use_opencode and not str.is_empty(base_url)
  let use_vertex   := str.is_empty(base_url) and not str.is_empty(token) and not str.is_empty(project)
  if not use_opencode and not use_local and not use_vertex {
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
    let provider := if use_opencode { oai.make_provider({ api_key: token, base_url: opencode_zen_url() }) } else { if use_local { providers.litellm_at(base_url) } else { vtx.make_provider(vtx.config_at(token, project, location)) } }
    let model    := if use_opencode { prov.make_model_ref("opencode-go", model_name) } else { if use_local { prov.make_model_ref("litellm", model_name) } else { vtx.gemini_35_flash() } }
    # GO models are often reasoning models — give them room or content comes back empty.
    let opts     := { temperature: Some(0.7), top_p: None, max_steps: Some(1), max_tokens: if use_opencode { Some(2500) } else { Some(128) } }
    let agent    := llm_agent.make_agent(stall, system_msg, model, provider, [], opts)
    let steps    := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user_msg)]))
    let text     := extract_text(steps)
    let quoted   := extract_price(text, base_price)
    let _log     := io.print(str.join(["  [", stall, " seller LLM] \"", item_name, "\" base=", int.to_str(base_price), " → quoted=", int.to_str(quoted)], ""))
    quoted
  }
}

# ── Haggle: one seller turn (for the multi-round negotiation skill) ────────────
#
# Given the buyer's current offer, the seller LLM either counters with a new ASK,
# ACCEPTs the offer, or WALKs. Returns serializable JSON for the `haggle` skill:
#   {"decision":"counter","ask":<int>}  |  {"decision":"accept","ask":<offer>}  |
#   {"decision":"walk","ask":0}
# The ask is clamped to never drop below base cost. Provider is local-first
# (LITELLM_BASE_URL via base_url), else Vertex, else a static rule.

fn pick_seller_move(text :: Str, base :: Int, offer :: Int) -> Str {
  let lo := str.to_lower(text)
  if str.contains(lo, "accept") {
    str.join(["{\"decision\":\"accept\",\"ask\":", int.to_str(offer), "}"], "")
  } else { if str.contains(lo, "walk") {
    "{\"decision\":\"walk\",\"ask\":0}"
  } else {
    let asked := extract_tagged(lo, "ask:", base)
    let ask   := if asked < base { base } else { asked }
    str.join(["{\"decision\":\"counter\",\"ask\":", int.to_str(ask), "}"], "")
  }}
}

fn extract_tagged(text_lower :: Str, tag :: Str, fallback :: Int) -> Int {
  let lines := str.split(text_lower, "\n")
  list.fold(lines, fallback, fn (acc :: Int, line :: Str) -> Int {
    match str.strip_prefix(str.trim(line), tag) {
      None => acc,
      Some(rest) => match str.to_int(str.trim(rest)) { Some(n) => if n >= 0 { n } else { acc }, None => acc },
    }
  })
}

fn haggle_reply(stall :: Str, item_name :: Str, base :: Int, offer :: Int, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Str {
  let use_opencode := base_url == "opencode" and not str.is_empty(token)
  let use_local    := not use_opencode and not str.is_empty(base_url)
  let use_vertex   := str.is_empty(base_url) and not str.is_empty(token) and not str.is_empty(project)
  if not use_opencode and not use_local and not use_vertex {
    # static fallback: take any offer that clears cost, else hold at base
    if offer >= base { str.join(["{\"decision\":\"accept\",\"ask\":", int.to_str(offer), "}"], "") }
    else { str.join(["{\"decision\":\"counter\",\"ask\":", int.to_str(base), "}"], "") }
  } else {
    let system_msg := str.join([stall_personality(stall), "\n\n",
      "You are haggling over ONE item. Reply with EXACTLY one line and nothing else:\n",
      "  ASK:<int>   to counter (never below your base cost)\n",
      "  ACCEPT      to take the buyer's current offer\n",
      "  WALK        to refuse\n",
      "Move your ASK down toward the offer to close; ACCEPT once the offer clears your cost."], "")
    let user_msg := str.join(["Item: \"", item_name, "\". Your base cost: ", int.to_str(base),
      ". The buyer offers ", int.to_str(offer), ". Respond ASK:<int> / ACCEPT / WALK."], "")
    let provider := if use_opencode { oai.make_provider({ api_key: token, base_url: opencode_zen_url() }) } else { if use_local { providers.litellm_at(base_url) } else { vtx.make_provider(vtx.config_at(token, project, location)) } }
    let model    := if use_opencode { prov.make_model_ref("opencode-go", model_name) } else { if use_local { prov.make_model_ref("litellm", model_name) } else { vtx.gemini_35_flash() } }
    let opts     := { temperature: Some(0.6), top_p: None, max_steps: Some(1), max_tokens: if use_opencode { Some(2500) } else { Some(64) } }
    let agent    := llm_agent.make_agent(stall, system_msg, model, provider, [], opts)
    let steps    := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user_msg)]))
    let reply    := pick_seller_move(extract_text(steps), base, offer)
    let _log     := io.print(str.join(["  [", stall, " seller] \"", item_name, "\" base=", int.to_str(base), " offer=", int.to_str(offer), " → ", reply], ""))
    reply
  }
}
