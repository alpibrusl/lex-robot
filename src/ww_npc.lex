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
  if role == "doctor" {
    "You are the DOCTOR. Each night you may protect one player from the wolf's attack, including yourself. You have no way to know who the wolf is except by watching the room — reason like a villager in public, and don't reveal your role unless it truly helps."
  } else {
    "You are a VILLAGER. You have no special powers — only your read of the room. Reason out loud, weigh who's acting suspicious, and help the town find the wolf."
  }}}
}

# ── Discussion turn ───────────────────────────────────────────────────────────
fn speak_fallback(name :: Str, role :: Str) -> Str {
  if role == "wolf" {
    "Honestly? I've just been listening. But some of the loudest voices here feel like they're performing for us — that's what I'd watch."
  } else {
  if role == "seer" {
    "Let's not rush a vote. I've got a read forming, and I'd rather be sure before I say it out loud."
  } else {
  if role == "doctor" {
    "I don't have any special read — but I've been keeping a close eye on things, and I'll do what I can to keep us safe."
  } else {
    "I don't have much yet — but whoever's steering us hardest is who I'd look at twice."
  }}}
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

# ── Player's private advisor ─────────────────────────────────────────────────
# NOT one of the five seats — a strategy sounding board for the human player,
# scoped to exactly what the player already knows (public transcript + their
# own private role knowledge), so it can't leak information the player
# couldn't otherwise have. Free-flowing, so `history` is the running Q&A so
# far rather than a strict single-line format.
fn advisor_fallback() -> Str {
  "I don't have a strong read yet — watch how people react when someone gets accused, that's usually where the tells show up."
}
fn advise(private :: Str, transcript :: Str, history :: Str, question :: Str, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Str {
  let fb := advisor_fallback()
  if not provider_configured(token, project, base_url) { fb } else {
    let system_msg := str.join([
      "You are the human player's private strategy advisor in a game of Werewolf. You are NOT one of the five seated players and you have no hidden agenda of your own — you're a sharp, honest ally helping the human think.\n\n",
      "You know exactly what the player knows, nothing more: the public table transcript below, and the player's own private role knowledge. Never invent or assume information the player doesn't have access to.\n\n",
      "What the player privately knows: ", private, "\n\n",
      "Give real analysis and a direct opinion when asked — who seems suspicious and why, what to say next, or who to vote for. 1-3 sentences, conversational, no bullet points or hedging disclaimers.\n",
      "Respond with EXACTLY: ADVICE:<your answer>\nNo other text."
    ], "")
    let convo := if str.is_empty(history) { "" } else { str.join(["Earlier in our conversation:\n", history, "\n\n"], "") }
    let user_msg := str.join([convo, "The table so far:\n", transcript, "\n\nMy question: ", question, "\nADVICE:<your answer>"], "")
    let answer := ww_llm_turn_retried("ww-advisor", system_msg, user_msg, make_model(base_url, model_name), make_prov(token, project, location, base_url), 0.7, (if base_url == "opencode" { Some(2500) } else { Some(220) }), "ADVICE:", fb)
    let _ := io.print(str.join(["  [ww-advisor] Q: ", question, " -> ", answer], ""))
    answer
  }
}

# ── Post-game reveal ─────────────────────────────────────────────────────────
# Once the game is over, each AI seat confesses — in the first person, with
# full hindsight — how it actually played: the wolf owns up to how it deflected,
# the seer reveals what it knew and how it steered, villagers admit who they
# suspected and whether they were fooled. This is the payoff of a bluffing game:
# "the wolf fooled everyone" becomes "here is exactly how it lied to you."
fn reveal_fallback(role :: Str, won :: Bool) -> Str {
  if role == "wolf" {
    if won { "I just kept quiet and let the loudest voices hang themselves. You were all watching each other — never me." }
    else { "You got me. I pushed a little too hard on the wrong person and the table finally smelled it." }
  } else {
  if role == "seer" {
    if won { "I knew more than I let on — I fed the town just enough to swing the vote without painting a target on my own back." }
    else { "I had a read but I couldn't get anyone to believe me in time. They came for me before I could prove it." }
  } else {
  if role == "doctor" {
    if won { "I saved the right person at the right moment — quietly, no one even noticed, but it bought us the round we needed." }
    else { "I couldn't cover everyone, and in the end my saves weren't enough." }
  } else {
    if won { "Honestly? I mostly followed my gut about who felt like they were performing — and this time it paid off." }
    else { "I trusted the wrong voice at the wrong moment. In hindsight the tells were right there." }
  }}}
}
fn reveal(name :: Str, role :: Str, won :: Bool, transcript :: Str, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Str {
  let fb := reveal_fallback(role, won)
  if not provider_configured(token, project, base_url) { fb } else {
    let outcome := if won { "Your side WON." } else { "Your side LOST." }
    let lens := if role == "wolf" {
      "Confess how you stayed hidden: who you deflected suspicion onto, your smoothest lie, and your riskiest moment."
    } else {
    if role == "seer" {
      "Reveal what your inspections told you and how you tried to steer the town toward the wolf without exposing yourself."
    } else {
    if role == "doctor" {
      "Reveal who you protected each night and whether you ever guessed right and saved the wolf's actual target."
    } else {
      "Admit who you suspected and why, and whether the wolf fooled you."
    }}}
    let system_msg := str.join([
      "You are ", name, ", and a game of Werewolf has just ended. You were the ", role, ". ", outcome, "\n\n",
      "Speak now with full hindsight, breaking character to give the table an honest post-game confession. ", lens, "\n",
      "1-2 sentences, first person, candid — a little smug if you won, a little rueful if you lost. Refer to the other players by name where it lands.\n",
      "Respond with EXACTLY: REVEAL:<your confession>\nNo other text."
    ], "")
    let user_msg := str.join(["The full game, as it played out:\n", transcript, "\n\nYour confession now that it's over. REVEAL:<your confession>"], "")
    let line := ww_llm_turn_retried(str.concat("wwr-", name), system_msg, user_msg, make_model(base_url, model_name), make_prov(token, project, location, base_url), 0.85, (if base_url == "opencode" { Some(2500) } else { Some(160) }), "REVEAL:", fb)
    let _ := io.print(str.join(["  [ww-reveal:", name, "/", role, "] ", line], ""))
    line
  }
}
