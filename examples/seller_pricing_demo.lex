# seller_pricing_demo — the bazaar seller LLMs, running on a LOCAL model.
#
# Each stall is an autonomous seller agent with a distinct pricing personality
# (see src/seller_llm.lex). This calls quote_price for the SAME item against the
# SAME buyer budget for three personalities, so you can watch a local model price
# differently per persona: the fair potter near cost, the textile trader near the
# buyer's ceiling, the spice trader at a premium. It is the negotiation core of
# auto_bazaar without the full A2A marketplace.
#
# Run:  LITELLM_BASE_URL=http://localhost:4000 LITELLM_MODEL=mistral-small:latest \
#         lex run --allow-effects env,io,llm,net,proc examples/seller_pricing_demo.lex run
#
# Run on hosted open-weights models (OpenCode Zen "Go plan"):
#   LITELLM_BASE_URL=opencode LITELLM_MODEL=kimi-k2.6 \
#   OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) \
#     lex run --allow-effects env,io,llm,net,proc examples/seller_pricing_demo.lex run

import "std.env" as env
import "std.io"  as io
import "std.str" as str
import "std.int" as int

import "../src/seller_llm" as sllm

fn run() -> [env, io, llm, net, proc] Int {
  let base := match env.get("LITELLM_BASE_URL") {
    None    => "http://localhost:4000",
    Some(v) => if str.is_empty(v) { "http://localhost:4000" } else { v },
  }
  let model := match env.get("LITELLM_MODEL") {
    None    => "qwen3-coder:30b",
    Some(v) => if str.is_empty(v) { "qwen3-coder:30b" } else { v },
  }
  # `base == "opencode"` selects the OpenCode Zen Go plan; the key (read here,
  # where we hold `env`) is threaded to quote_price via its `token` param.
  let opencode_key := if base == "opencode" {
    match env.get("OPENCODE_API_KEY") { None => "", Some(v) => v }
  } else { "" }
  let label := if base == "opencode" { "hosted open-weights (OpenCode Zen)" } else { "a LOCAL model" }
  let base_cost := 8
  let budget    := 20
  let _ := io.print(str.join([
    "=== bazaar sellers on ", label, " (", model, ") ===\n",
    "Same item \"Bowl\" (base cost ", int.to_str(base_cost),
    "), same buyer budget ceiling ", int.to_str(budget), " — three personalities quote:"], ""))

  # quote_price logs "[<stall> seller LLM] \"Bowl\" base=8 → quoted=N" for each.
  let p1 := sllm.quote_price("pottery", "bowl-1", "Bowl", base_cost, budget, opencode_key, "", "", base, model)
  let p2 := sllm.quote_price("textile", "bowl-1", "Bowl", base_cost, budget, opencode_key, "", "", base, model)
  let p3 := sllm.quote_price("spices",  "bowl-1", "Bowl", base_cost, budget, opencode_key, "", "", base, model)

  let _ := io.print(str.join([
    "\nquotes — Master Karim (fair potter): ", int.to_str(p1),
    "   |  Merchant Lena (max profit): ", int.to_str(p2),
    "   |  Spice Trader (premium): ", int.to_str(p3),
    "\n(a rational buyer takes the cheapest in-budget quote — the seller goals are in tension)"], ""))
  0
}
