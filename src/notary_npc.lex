# src/notary_npc.lex — an unscripted NPC for the Stamp of Destiny adventure.
#
# Bosun Kettle isn't a dialogue tree: when an LLM is configured, his plea to
# Milo Quill (the accidental Notary) is generated fresh each time from a
# persona + scene prompt, so his exact wording — and how hard he pushes for
# the out-of-license shortcut — varies. The mechanical puzzle (which chit
# categories the license actually covers) stays fixed and server-enforced;
# only the performance is unpredictable. Same one-LLM-turn, bounded-output
# shape as src/seller_llm.lex's quote_price, with the same graceful static
# fallback when no LLM is configured.
#
# Effects: [net, llm, io, proc]

import "std.str"  as str
import "std.list" as list
import "std.iter" as iter
import "std.io"   as io

import "lex-llm/src/agent"            as llm_agent
import "lex-llm/src/message"          as msg
import "lex-llm/src/delta"            as d
import "lex-llm/src/providers"        as providers
import "lex-llm/src/provider"         as prov
import "lex-llm/src/providers/vertex" as vtx
import "lex-llm/src/providers/openai" as oai

fn opencode_zen_url() -> Str { "https://opencode.ai/zen/go/v1/chat/completions" }

fn extract_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step { StepDone(m) => match m { AssistantMsg(text, _) => text, _ => acc }, _ => acc }
  })
}

fn extract_say(text :: Str, fallback :: Str) -> Str {
  let lines := str.split(text, "\n")
  list.fold(lines, fallback, fn (acc :: Str, line :: Str) -> Str {
    match str.strip_prefix(str.trim(line), "SAY:") {
      None => acc,
      Some(rest) => if str.is_empty(str.trim(rest)) { acc } else { str.trim(rest) },
    }
  })
}

# One LLM turn: given a persona and the current scene, return Bosun's one-line,
# in-character plea. Falls back to a static line if no LLM is configured or the
# model gives no parseable SAY: line — the puzzle stays playable either way.
fn plea(persona :: Str, scene :: Str, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Str {
  let fallback := "Look, friend — new Notary, right? Slow week, I bet. I've got a barrel here that just needs... the RIGHT paperwork. Say, a protected-species exemption? Or if that's above your stamp, I'll take a plain goods certificate. Filleted haddock. That's all I'm asking."
  let use_opencode := base_url == "opencode" and not str.is_empty(token)
  let use_local    := not use_opencode and not str.is_empty(base_url)
  let use_vertex   := str.is_empty(base_url) and not str.is_empty(token) and not str.is_empty(project)
  if not use_opencode and not use_local and not use_vertex {
    fallback
  } else {
    let system_msg := str.join([
      persona, "\n\n",
      "You are speaking to Milo Quill, the harbor's brand-new (and clueless) Notary. ",
      "You want your barrel notarized in your favour, and you'll push for the boldest wording ",
      "you think you can get away with. Stay in character, be persuasive, maybe a little shifty.\n",
      "Respond with EXACTLY one line: SAY:<your in-character plea, one or two sentences>\n",
      "No other text."
    ], "")
    let user_msg := str.join(["Scene: ", scene, "\n\nWhat do you say to Milo? Respond: SAY:<your line>"], "")
    let provider := if use_opencode { oai.make_provider({ api_key: token, base_url: opencode_zen_url() }) } else { if use_local { providers.litellm_at(base_url) } else { vtx.make_provider(vtx.config_at(token, project, location)) } }
    let model    := if use_opencode { prov.make_model_ref("opencode-go", model_name) } else { if use_local { prov.make_model_ref("litellm", model_name) } else { vtx.gemini_35_flash() } }
    let opts     := { temperature: Some(0.9), top_p: None, max_steps: Some(1), max_tokens: if use_opencode { Some(2500) } else { Some(128) } }
    let agent    := llm_agent.make_agent("bosun-kettle", system_msg, model, provider, [], opts)
    let steps    := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user_msg)]))
    let text     := extract_text(steps)
    let line     := extract_say(text, fallback)
    let _log     := io.print(str.join(["  [bosun-kettle LLM] ", line], ""))
    line
  }
}
