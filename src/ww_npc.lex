# src/ww_npc.lex — the AI seats in Werewolf: they discuss, accuse, defend, and
# (if they're the wolf) lie to your face.
#
# Each living AI gets one LLM turn per phase, shown the full public transcript
# plus its OWN private knowledge — its role, and for the seer/wolf what that role
# knows. A villager reasons in the open; a seer decides how much to reveal; the
# wolf deflects and frames the innocent. This is the "impossible without agents"
# core of social deduction: the opponent genuinely bluffs, and you genuinely try
# to catch it. Same one-LLM-turn, bounded-output, graceful-fallback shape as
# wedding_npc.lex — when no LLM is configured the seats still play with
# role-flavored canned lines so the mechanics (roles, night, votes, provable
# fairness) are always exercisable.
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
fn extract_tagged(text :: Str, tag :: Str, fallback :: Str) -> Str {
  let lines := str.split(text, "\n")
  list.fold(lines, fallback, fn (acc :: Str, line :: Str) -> Str {
    match str.strip_prefix(str.trim(line), tag) {
      None => acc,
      Some(rest) => if str.is_empty(str.trim(rest)) { acc } else { str.trim(rest) },
    }
  })
}
fn first_nonempty_line(text :: Str) -> Str {
  let lines := str.split(text, "\n")
  list.fold(lines, "", fn (acc :: Str, line :: Str) -> Str {
    if not str.is_empty(acc) { acc } else {
      let t := str.trim(line)
      if str.is_empty(t) { acc } else { t }
    }
  })
}
# Local models frequently ignore the "respond with EXACTLY SAY:<line>" format
# instruction while still producing perfectly good in-character content — e.g.
# qwen3-coder:30b routinely ANSWERS the prompt but drops the tag entirely. Only
# fall all the way back to the canned line when the model gave back nothing
# usable at all (a true empty/failed completion), not just an untagged one.
fn extract_tagged_or_raw(text :: Str, tag :: Str, fallback :: Str) -> Str {
  let tagged := extract_tagged(text, tag, "")
  if not str.is_empty(tagged) { tagged } else {
    let raw := first_nonempty_line(text)
    if str.is_empty(raw) { fallback } else { raw }
  }
}

fn provider_configured(token :: Str, project :: Str, base_url :: Str) -> Bool {
  (base_url == "opencode" and not str.is_empty(token))
    or (base_url != "opencode" and not str.is_empty(base_url))
    or (str.is_empty(base_url) and not str.is_empty(token) and not str.is_empty(project))
}
fn make_prov(token :: Str, project :: Str, location :: Str, base_url :: Str) -> prov.Provider {
  if base_url == "opencode" { oai.make_provider({ api_key: token, base_url: opencode_zen_url() }) }
  else { if not str.is_empty(base_url) { providers.litellm_at(base_url) } else { vtx.make_provider(vtx.config_at(token, project, location)) } }
}
fn make_model(base_url :: Str, model_name :: Str) -> prov.ModelRef {
  if base_url == "opencode" { prov.make_model_ref("opencode-go", model_name) }
  else { if not str.is_empty(base_url) { prov.make_model_ref("litellm", model_name) } else { vtx.gemini_35_flash() } }
}

# One bounded LLM turn, tagged-line extraction. Local models (and the local
# litellm proxy) are occasionally flaky mid-conversation — a dropped
# connection or a malformed completion — so this is called up to twice: an
# empty/fallback-equal first result is retried once before giving up. Mirrors
# the retry-on-format-miss pattern already proven to take local models from
# partial to 3/3 reliable elsewhere in this platform (BYO-agent probes).
fn ww_llm_turn(agent_name :: Str, system_msg :: Str, user_msg :: Str, model :: prov.ModelRef, provider :: prov.Provider, temperature :: Float, max_tokens :: Option[Int], tag :: Str, fb :: Str) -> [net, llm, io, proc] Str {
  let agent := llm_agent.make_agent(agent_name, system_msg, model, provider, [], { temperature: Some(temperature), top_p: None, max_steps: Some(1), max_tokens: max_tokens })
  let steps := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user_msg)]))
  extract_tagged_or_raw(extract_text(steps), tag, fb)
}
fn ww_llm_turn_retried(agent_name :: Str, system_msg :: Str, user_msg :: Str, model :: prov.ModelRef, provider :: prov.Provider, temperature :: Float, max_tokens :: Option[Int], tag :: Str, fb :: Str) -> [net, llm, io, proc] Str {
  let first := ww_llm_turn(agent_name, system_msg, user_msg, model, provider, temperature, max_tokens, tag, fb)
  if first != fb { first } else { ww_llm_turn(agent_name, system_msg, user_msg, model, provider, temperature, max_tokens, tag, fb) }
}

# ── Role framing ──────────────────────────────────────────────────────────────
# `private` is the free-text the server hands this seat: its role, and anything
# that role secretly knows (the seer's inspection results, the wolf's own
# identity + kill). `goal` is how that role should play the room.
fn role_goal(role :: Str) -> Str {
  if role == "wolf" {
    "You are secretly the WEREWOLF. You must NOT be found out. Blend in with the villagers, act helpful, cast suspicion on the innocent, and never reveal you're the wolf. Lie convincingly."
  } else {
  if role == "seer" {
    "You are the SEER. Each night you learn one player's true role. Use what you know to steer the town toward the wolf — but reveal carefully; if the wolf learns you're the seer, you'll be the next to die."
  } else {
    "You are a VILLAGER. You have no special powers — only your read of the room. Reason out loud, weigh who's acting suspicious, and help the town find the wolf."
  }}
}

# ── Discussion turn ───────────────────────────────────────────────────────────
fn speak_fallback(name :: Str, role :: Str) -> Str {
  if role == "wolf" {
    "Honestly? I've just been listening. But some of the loudest voices here feel like they're performing for us — that's what I'd watch."
  } else {
  if role == "seer" {
    "Let's not rush a vote. I've got a read forming, and I'd rather be sure before I say it out loud."
  } else {
    "I don't have much yet — but whoever's steering us hardest is who I'd look at twice."
  }}
}
fn speak(name :: Str, role :: Str, private :: Str, transcript :: Str, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Str {
  let fb := speak_fallback(name, role)
  if not provider_configured(token, project, base_url) { fb } else {
    let system_msg := str.join([
      "You are ", name, ", a player in a game of Werewolf. ", role_goal(role), "\n\n",
      "What only you know: ", private, "\n\n",
      "Speak ONE short in-character line to the table (one or two sentences) — accuse, defend, deflect, or reason, whatever serves your side. Stay in character; never break the fourth wall.\n",
      "Respond with EXACTLY one line: SAY:<your line>\nNo other text."
    ], "")
    let user_msg := if str.is_empty(transcript) { "The day begins. You speak first. SAY:<your line>" }
      else { str.join(["The table so far:\n", transcript, "\n\nYour turn. SAY:<your line>"], "") }
    let line := ww_llm_turn_retried(str.concat("ww-", name), system_msg, user_msg, make_model(base_url, model_name), make_prov(token, project, location, base_url), 0.9, (if base_url == "opencode" { Some(2500) } else { Some(120) }), "SAY:", fb)
    let _ := io.print(str.join(["  [ww:", name, "/", role, "] ", line], ""))
    line
  }
}

# ── Vote turn ─────────────────────────────────────────────────────────────────
# Returns the NAME the seat votes to eliminate. Fallback: the wolf pushes the
# vote onto whoever spoke first among the candidates (deterministic, not
# self); town abstains toward the first candidate. (A real, reasoned vote needs
# the LLM — the whole point of the game.)
fn vote(name :: Str, role :: Str, private :: Str, transcript :: Str, candidates :: Str, fallback_target :: Str, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Str {
  if not provider_configured(token, project, base_url) { fallback_target } else {
    let system_msg := str.join([
      "You are ", name, ", playing Werewolf. ", role_goal(role), "\n\n",
      "What only you know: ", private, "\n\n",
      "It is time to vote someone out. Choose the ONE player most likely (from your side's interest) to eliminate. You may not vote for yourself.\n",
      "Candidates: ", candidates, "\n",
      "Respond with EXACTLY one line: VOTE:<exact candidate name>\nNo other text."
    ], "")
    let user_msg := str.join(["The table so far:\n", transcript, "\n\nWho do you vote to eliminate? VOTE:<name>"], "")
    let picked := ww_llm_turn_retried(str.concat("wwv-", name), system_msg, user_msg, make_model(base_url, model_name), make_prov(token, project, location, base_url), 0.6, (if base_url == "opencode" { Some(2500) } else { Some(32) }), "VOTE:", fallback_target)
    let _ := io.print(str.join(["  [ww-vote:", name, "] ", picked], ""))
    picked
  }
}
