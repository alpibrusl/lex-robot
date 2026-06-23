# haggle_demo — multi-round buyer↔seller price negotiation on a LOCAL model.
#
# Two LLM agents haggle over one item: the seller (a bazaar personality, base
# cost 8) wants the highest price; the buyer (secret max budget 20) wants the
# lowest. They alternate ASK / OFFER until one ACCEPTs, one WALKs, or the ranges
# cross. This is the multi-round successor to seller_pricing_demo's single quote.
#
# Run:  LITELLM_BASE_URL=http://localhost:4000 LITELLM_MODEL=mistral-small:latest \
#         lex run --allow-effects env,fs_write,io,llm,net,proc,sql,time examples/haggle_demo.lex run

import "std.env" as env
import "std.io"  as io
import "std.str" as str
import "std.int" as int

import "lex-llm/src/providers" as providers
import "lex-llm/src/provider"  as prov

import "../src/haggle" as haggle

fn show(d :: haggle.Deal) -> [io] Unit {
  if d.closed {
    io.print(str.join(["  ✓ DEAL at ", int.to_str(d.price), " credits — ", d.reason, " (", int.to_str(d.rounds), " rounds)\n"], ""))
  } else {
    io.print(str.join(["  ✗ NO DEAL — ", d.reason, "\n"], ""))
  }
}

fn run() -> [env, io, llm, net, proc] Int {
  let model_name := match env.get("LITELLM_MODEL") {
    None => "qwen3-coder:30b", Some(v) => if str.is_empty(v) { "qwen3-coder:30b" } else { v },
  }
  let provider := providers.litellm()                       # reads LITELLM_BASE_URL (default :4000)
  let model    := prov.make_model_ref("litellm", model_name)

  let _ := io.print(str.join(["=== multi-round haggling on a LOCAL model (", model_name, ") ===\n",
    "Item \"Bowl\": seller base cost 8, buyer secret max 20.\n"], ""))

  let d1 := haggle.negotiate(provider, model, "textile", "Bowl", 8, 20, 8)   # Merchant Lena — sharp
  let _1 := show(d1)
  let d2 := haggle.negotiate(provider, model, "pottery", "Bowl", 8, 20, 8)   # Master Karim — fair
  let _2 := show(d2)
  0
}
