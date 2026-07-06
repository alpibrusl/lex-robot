# src/wedding_npc.lex — the unscripted negotiation for The Wedding Broker.
#
# Three guests each get one LLM turn, IN SEQUENCE, each one shown the full
# transcript so far — so Kamala can needle Deb, and Jonah can get visibly
# more anxious watching the room tense up. This is the "impossible without
# agents" mechanic: a fixed dialogue tree could never produce a different,
# genuinely surprising round of scheming each playthrough the way three
# live, context-aware LLM turns can. Same one-LLM-turn, bounded-output,
# graceful-fallback shape as src/notary_npc.lex's plea() (itself modeled on
# src/seller_llm.lex's quote_price) — reliability over free-form flourish.
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

fn guest_persona(id :: Str) -> Str {
  if id == "deb" {
    "You are Deb, the groom's mother — polished, passive-aggressive, quietly convinced everything would run better if she were in charge. You want your table moved to the prime spot and Table 3 (your ex-husband's new wife's table) moved to the back, and you're not shy about mentioning how much you've contributed to this wedding."
  } else {
  if id == "kamala" {
    "You are Aunt Kamala, self-appointed family peacekeeper — warm, sweet, and secretly delighted by drama. You want a speech slot to share a 'loving' story about the groom that everyone privately knows will mortify him. You love commenting on whatever the last person said, usually while pretending to smooth things over."
  } else {
    "You are Jonah, the best man — anxious, oversharing, one drink from blurting out something he shouldn't. You still owe the groom money and think a longer speech is your chance to publicly make it right, which would be excruciating for everyone. The tenser the room gets, the more you ramble."
  }}
}

fn guest_fallback(id :: Str) -> Str {
  if id == "deb" {
    "I simply think it makes sense for Table 3 to move to the back — and for us to have the spot up front, given everything we've put into this wedding."
  } else {
  if id == "kamala" {
    "Oh, don't mind Deb, she just wants everyone comfortable! Speaking of comfort — I really think a LITTLE toast about Dax's college years would just delight everyone."
  } else {
    "Yeah, so — could I maybe get a few extra minutes for my speech? There's, uh, some stuff I really need to say. To Dax. Publicly. It's fine."
  }}
}

# ── Memory openers ────────────────────────────────────────────────────────────
# A guest who has dealt with this broker before opens colored by history. The
# grudge string is phrased to follow "how you ___" (e.g. "refused to move that
# table"), written by the sidecar's fallout logic.
fn guest_cold_opener(id :: Str, grudge :: Str) -> Str {
  if id == "deb" {
    str.join(["Oh. It's you again. I haven't forgotten how you ", grudge, " at the last one — so let's do better this time."], "")
  } else {
  if id == "kamala" {
    str.join(["Well, look who they hired again. I'm still a teeny bit hurt you ", grudge, " last time — not that I'd ever hold a grudge."], "")
  } else {
    str.join(["Oh — hey. It's, uh, you. No hard feelings about how you ", grudge, " last time. Mostly. Anyway—"], "")
  }}
}
fn guest_warm_opener(id :: Str) -> Str {
  if id == "deb" {
    "Oh, good — it's you. You did right by us last time, so I'll keep this civil."
  } else {
  if id == "kamala" {
    "Oh, wonderful, it's you again! Always such a pleasure working with someone who listens."
  } else {
    "Hey, it's you! Last one went great — thanks again, really. So, um—"
  }}
}
# The static fallback, now colored by memory when there is any.
fn memory_fallback(id :: Str, regard :: Int, grudge :: Str) -> Str {
  let base := guest_fallback(id)
  if regard < 0 { str.join([guest_cold_opener(id, grudge), " ", base], "") } else {
  if regard > 0 { str.join([guest_warm_opener(id), " ", base], "") } else { base }}
}
# The history note handed to the LLM so it opens in-character for the relationship.
fn memory_note(regard :: Int, grudge :: Str) -> Str {
  if regard < 0 {
    str.join(["\n\nHISTORY WITH THIS PLANNER: it went BADLY before. You are cold and pointed with them. You have not forgotten that they ", grudge, ". Let that edge show immediately."], "")
  } else {
  if regard > 0 {
    "\n\nHISTORY WITH THIS PLANNER: they treated you well before. You greet them warmly and give them the benefit of the doubt."
  } else { "" }}
}

# One LLM turn for one guest: given their persona, their fixed request, the
# transcript so far, and their memory of this broker (regard + any grudge),
# produce their one-line in-character contribution. Falls back to a static —
# but still memory-colored — line if no LLM is configured or nothing parses.
fn line_for(id :: Str, request :: Str, transcript_so_far :: Str, regard :: Int, grudge :: Str, token :: Str, project :: Str, location :: Str, base_url :: Str, model_name :: Str) -> [net, llm, io, proc] Str {
  let fallback := memory_fallback(id, regard, grudge)
  let use_opencode := base_url == "opencode" and not str.is_empty(token)
  let use_local    := not use_opencode and not str.is_empty(base_url)
  let use_vertex   := str.is_empty(base_url) and not str.is_empty(token) and not str.is_empty(project)
  if not use_opencode and not use_local and not use_vertex {
    fallback
  } else {
    let system_msg := str.join([
      guest_persona(id), "\n\nYour request: ", request,
      memory_note(regard, grudge), "\n\n",
      "You're negotiating with the wedding planner (a stand-in, not a professional) in front of the other family members. ",
      "React to whatever was just said if anything was said — agree, undercut it, pile on, whatever's in character. ",
      "Stay in character, one or two sentences, a little pointed or funny is good.\n",
      "Respond with EXACTLY one line: SAY:<your in-character line>\nNo other text."
    ], "")
    let user_msg := if str.is_empty(transcript_so_far) {
      "You're the first to speak. What do you say? Respond: SAY:<your line>"
    } else {
      str.join(["So far, this has been said:\n", transcript_so_far, "\n\nWhat do you say? Respond: SAY:<your line>"], "")
    }
    let provider := if use_opencode { oai.make_provider({ api_key: token, base_url: opencode_zen_url() }) } else { if use_local { providers.litellm_at(base_url) } else { vtx.make_provider(vtx.config_at(token, project, location)) } }
    let model    := if use_opencode { prov.make_model_ref("opencode-go", model_name) } else { if use_local { prov.make_model_ref("litellm", model_name) } else { vtx.gemini_35_flash() } }
    let opts     := { temperature: Some(0.9), top_p: None, max_steps: Some(1), max_tokens: if use_opencode { Some(2500) } else { Some(128) } }
    let agent    := llm_agent.make_agent(str.concat("wedding-", id), system_msg, model, provider, [], opts)
    let steps    := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user_msg)]))
    let text     := extract_text(steps)
    let line     := extract_say(text, fallback)
    let _log     := io.print(str.join(["  [wedding:", id, " LLM] ", line], ""))
    line
  }
}
