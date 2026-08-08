# lex-robot/llm_planner.lex — a REAL agentic LLM loop over the robot's own
# governed A2A endpoint: the piece the "how does an agentic LLM act on
# 'bring me a beer'" discussion identified as still conceptual, not built.
#
# ARCHITECTURE — why the planner never gets [sense, actuate]:
#
#   Each Tool the model can call is a thin A2A CLIENT wrapper around
#   a2a_robot_server.lex's ALREADY-DEPLOYED tasks/send endpoint — the exact
#   same wire path any third-party A2A client (ADK/LangGraph/CrewAI/AutoGen)
#   already uses to drive this robot. The model's "tool call" is JUDGMENT
#   (a proposal); the grant/budget/trail checks inside
#   a2a_robot_server.lex's dispatch_skill are AUTHORITY — the same split
#   DESIGN.md draws everywhere else in this repo. A planner that
#   hallucinates, or is prompt-injected into proposing an out-of-grant
#   move, gets exactly the same "denied: ..." response any other A2A
#   caller would, because it goes through exactly the same code path. This
#   module never imports skills.lex and never declares [sense]/[actuate] —
#   the ONLY crossing into physical authority anywhere in this file is an
#   HTTP POST to a server that independently enforces the grant.
#
#   This also sidesteps a real effect-system wall: lex-llm's Tool.execute
#   is fixed at `(Json) -> [net, io, proc] Result[...]` (tool.lex) — too
#   narrow to carry [sense, actuate] even if we wanted to call skills.*
#   directly, the SAME reason mcp_server.lex / a2a_robot_server.lex
#   hand-roll their own dispatch instead of using lex-agent's fixed-row
#   Skill.handle. Here the fix is architectural, not a workaround: route
#   through the A2A front door that already solved this, instead of
#   trying to widen a row that's fixed on purpose.
#
#   One more narrow-row wall, solved the same way: lex-agent's own
#   `client.send_task` needs `[net, crypto, random]` (it can auto-generate
#   a message id) — crypto/random aren't in Tool.execute's fixed
#   `[net, io, proc]` either. So call_robot_skill() below reuses every
#   PURE piece of client.lex (build_send_params, build_envelope,
#   parse_response_body — all real wire-format code, not reimplemented)
#   and does its own bare [net] http.post, supplying a pre-built message
#   id instead of asking client.lex to mint one.
#
# SAFETY NOTE: this is judgment, not authority, end to end. Nothing here
# can expand what the robot's A2A server is willing to do. The worst a
# broken or adversarial model can do is get "denied:"/"killed:" back on
# every call, or waste the run's budget on refused actions — never bypass
# the grant. Tool RESULTS carry denial/kill/stall text back to the model
# as ordinary Ok(...) content (not an Err) — a refusal is real, useful
# information for the model to reason about, not a plumbing failure.
#
# Provider: OpenCode Zen (opencode.ai/zen "Go plan"), OpenAI-compatible —
# the same integration lex-robot's bazaar/game NPCs already use (see
# seller_llm.lex's use_opencode path). MODEL CATALOG CAVEAT: OpenCode's
# Go-plan lineup moves fast (point releases like glm-5.1 vs 5.2, or
# qwen3.6 vs 3.8, supersede each other on a timescale of weeks) and this
# repo has no live way to query it. kimi-k2.6 was the one name that
# stayed consistent across everything checked while writing this — still,
# confirm the CURRENT catalog (`opencode models`, or opencode.ai/docs/zen)
# before depending on this default in production; override with an
# explicit model_name rather than trusting it blindly.
#
# api_key is a plain Str parameter, not read from an env var in here —
# same reasoning seller_llm.lex documents: the CALLER (which holds the
# [env] effect) reads OPENCODE_API_KEY and passes it in, keeping this
# module's own effect row free of [env].
#
# Run: `proc` is required even though nothing here calls it directly —
# lex-llm's Tool type declares [net, io, proc] on execute's fixed row
# (tool.lex); the toolchain validates the whole imported module graph,
# not just the call path exercised (same reason mcp_server.lex's Run
# comment lists llm/proc it never calls).
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#       src/llm_planner.lex run

import "std.str" as str

import "std.list" as list

import "std.iter" as iter

import "std.http" as http

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/agent" as ag

import "lex-llm/src/tool" as t

import "lex-llm/src/delta" as d

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers/openai" as oai

import "lex-agent/src/protocol" as proto

import "lex-agent/src/client" as a2a_client

import "lex-trail/log" as trail

import "./a2a_robot_server" as srv

import "./a2a_card" as card

# ── OpenCode Zen provider ────────────────────────────────────────────────
fn opencode_zen_url() -> Str {
  "https://opencode.ai/zen/go/v1/chat/completions"
}

# See the MODEL CATALOG CAVEAT in the module doc above before trusting
# this in production.
fn default_model() -> Str {
  "kimi-k2.6"
}

fn opencode_provider(api_key :: Str) -> prov.Provider {
  oai.make_provider({ api_key: api_key, base_url: opencode_zen_url() })
}

fn opencode_model(model_name :: Str) -> prov.ModelRef {
  prov.make_model_ref("opencode-go", model_name)
}

# ── Robot tool calls: a thin A2A client — no [sense, actuate] anywhere ───
# Dig the reply DataPart's "result" string out of a tasks/send response —
# the exact shape a2a_robot_server.lex's handle_tasks_send produces
# (message.parts[0].data.result; see task.lex's task_to_json).
fn task_result_text(tj :: jv.Json) -> Str {
  match jv.get_field(tj, "message") {
    None => "",
    Some(mj) => match jv.get_field(mj, "parts") {
      Some(JList(parts)) => match list.head(parts) {
        None => "",
        Some(p) => match jv.get_field(p, "data") {
          None => "",
          Some(dj) => match jv.get_field(dj, "result") {
            Some(JStr(s)) => s,
            _ => "",
          },
        },
      },
      _ => "",
    },
  }
}

# ── Session establishment (a2a_robot_server.lex's session/open) ─────────
# The planner authenticates like any other A2A caller — there is no special
# unauthenticated path for the robot's own trusted software; the operator's
# ConsentPolicy simply needs to accept this identity (examples/
# a2a_robot_demo.lex's policy is open by design, precisely so this needs no
# pre-shared setup — see that file's comment). The keypair is deterministic
# from `session_id` (same "no [random] needed" reasoning identity.lex
# documents for its own keypairs), so the same session_id always presents
# the same identity to the server.
fn planner_skill_names() -> List[Str] {
  ["move_base", "move_arm", "grasp_arm", "locate_object", "transform_to_arm", "read_base", "speak"]
}

fn planner_card_json(pubkey_b64 :: Str) -> Str {
  card.card_to_json({ name: "xlerobot-planner", endpoint: "https://xlerobot-planner.internal", pubkey_b64: pubkey_b64, tier: card.Extended, supports_extended: false, skills: list.map(planner_skill_names(), fn (n :: Str) -> card.AgentSkill {
    { name: n, description: "" }
  }) })
}

# Open a session and return the real contextId to use for every subsequent
# tasks/send call. On ANY failure (network error, bad response shape, a
# refused card) this falls back to the raw `session_id` string — every
# following tool call then gets a clean, visible "no active session" error
# from the server instead of a crash here, same category of outcome the
# model already has to handle for a denied/killed/stalled skill result.
fn open_client_session(peer_url :: Str, session_id :: Str) -> [net, crypto] Str {
  let secret := crypto.sha256(bytes.from_str(str.concat("xlerobot-planner:", session_id)))
  match crypto.ed25519_public_key(secret) {
    Err(_) => session_id,
    Ok(pk) => {
      let cj := planner_card_json(crypto.base64url_encode(pk))
      match card.sign_card(cj, secret) {
        Err(_) => session_id,
        Ok(sig) => {
          let body := a2a_client.build_envelope("session/open", JObj([("card_json", JStr(cj)), ("sig_b64", JStr(sig))]), IdStr("session-open"))
          match http.post(peer_url, bytes.from_str(body), "application/json") {
            Err(_) => session_id,
            Ok(resp) => match bytes.to_str(resp.body) {
              Err(_) => session_id,
              Ok(s) => match a2a_client.parse_response_body(s) {
                Err(_) => session_id,
                Ok(rj) => match jv.get_field(rj, "contextId") {
                  Some(JStr(cid)) => cid,
                  _ => session_id,
                },
              },
            },
          }
        },
      }
    },
  }
}

# Call one skill on the robot's own A2A server over tasks/send — see the
# module doc above for why this reuses client.lex's pure wire builders
# instead of client.send_task itself.
fn call_robot_skill(peer_url :: Str, skill_name :: Str, session_id :: Str, args :: jv.Json) -> [net] Result[Str, Str] {
  let m := { message_id: str.concat(session_id, "-msg"), role: RoleUser, parts: [DataPart(args)], context_id: session_id }
  let opts := { task_id: str.join([session_id, "-", skill_name], ""), context_id: session_id, skill: skill_name }
  let params := a2a_client.build_send_params(m, opts)
  let body := a2a_client.build_envelope(proto.method_tasks_send(), params, IdStr(opts.task_id))
  match http.post(peer_url, bytes.from_str(body), "application/json") {
    Err(herr) => Err(str.concat("a2a http error calling ", str.concat(skill_name, str.concat(": ", a2a_client.http_err_str(herr))))),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => Err(str.concat("a2a response body decode failed for ", skill_name)),
      Ok(s) => match a2a_client.parse_response_body(s) {
        Err(rpcerr) => Err(str.concat("a2a rpc error calling ", str.concat(skill_name, str.concat(": ", rpcerr.message)))),
        Ok(tj) => Ok(task_result_text(tj)),
      },
    },
  }
}

# Wrap one robot Capability (from a2a_robot_server.lex — the SAME value
# that already drives the AgentCard and the MCP/A2A tool listings; one
# schema, now a third consumer) as a lex-llm Tool. A network/RPC failure
# is a genuine Err (the model gets "One or more tools returned errors...
# try again"); a real "denied:"/"killed:"/"stalled:" outcome is Ok content
# — the tool call succeeded at getting a real answer from the robot, the
# answer just wasn't "reached".
fn robot_tool(peer_url :: Str, session_id :: Str, capability :: cap.Capability) -> t.Tool {
  t.define(capability.name, capability.description, capability.params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    match call_robot_skill(peer_url, capability.name, session_id, args) {
      Err(msg) => Err(e.single("a2a", e.code_custom(), msg)),
      Ok(result_text) => Ok(JStr(result_text)),
    }
  })
}

# The XLeRobot's natural-language-drivable vocabulary: move + perceive +
# grasp + speak. Deliberately excludes the depot/EV-charger capabilities
# (move_to/grasp/connect_charger/read_joints/read_camera) — a narrower
# tool list is also a more RELIABLE one; a model picks the right tool more
# often from seven well-differentiated choices than from twelve.
fn xlerobot_tools(peer_url :: Str, session_id :: Str) -> List[t.Tool] {
  list.map([srv.move_base_cap(), srv.move_arm_cap(), srv.grasp_arm_cap(), srv.locate_object_cap(), srv.transform_to_arm_cap(), srv.read_base_cap(), srv.speak_cap()], fn (c :: cap.Capability) -> t.Tool {
    robot_tool(peer_url, session_id, c)
  })
}

# ── Agent construction ───────────────────────────────────────────────────
fn planner_goal() -> Str {
  str.join(["You control a real robot (XLeRobot: a dual-arm mobile base) through a ", "fixed set of tools. Every tool call you make is independently checked ", "by a safety grant on the SERVER before it does anything -- you have no ", "authority beyond what that grant allows, so propose the plan you think ", "is right and let the server tell you if it's refused.\n\n", "Rules:\n", "1) To fetch a named object, first call locate_object to find its real ", "position -- never guess coordinates.\n", "2) After driving the base, call transform_to_arm with the object's ", "world position (the 'world' field locate_object returned) to get a ", "fresh arm-frame target -- the base moving invalidates any earlier ", "arm-frame offset, only the world position stays valid.\n", "3) If a tool call comes back denied/killed/stalled, do not blindly ", "retry the same thing -- read the reason, adjust if you reasonably can, ", "or stop and explain the problem in your final reply.\n", "4) Use speak only for a short, useful confirmation to the human -- ", "typically once, near the end -- not for every intermediate step.\n", "5) Finish with a brief plain-text summary of what happened, whether ", "the goal was achieved, and why not if it wasn't."], "")
}

# Provider/model are explicit params (not baked in) so a test can substitute
# a scripted mock Provider — a Provider is just a { name, chat } record, so
# this is a genuine substitution, not a special test-only code path — and
# verify the ENTIRE tool-calling loop (a real HTTP round-trip into a real,
# grant-gated a2a_robot_server) without needing network access or an
# OpenCode API key. build_agent_opencode below is the convenience wrapper
# real callers use.
fn build_agent(peer_url :: Str, session_id :: Str, provider :: prov.Provider, model :: prov.ModelRef) -> ag.AgentLoop {
  ag.make_agent("xlerobot-planner", planner_goal(), model, provider, xlerobot_tools(peer_url, session_id), { temperature: Some(0.3), top_p: None, max_steps: Some(12), max_tokens: Some(2000) })
}

fn build_agent_opencode(peer_url :: Str, session_id :: Str, api_key :: Str, model_name :: Str) -> ag.AgentLoop {
  build_agent(peer_url, session_id, opencode_provider(api_key), opencode_model(model_name))
}

# ── Running the loop ─────────────────────────────────────────────────────
fn step_text(step :: d.Step) -> Str {
  match step {
    StepDone(AssistantMsg(text, _)) => text,
    _ => "",
  }
}

# The last non-empty StepDone assistant text — run_loop only emits one
# StepDone (the terminal step), so this is just "the final reply", spelled
# defensively in case that ever changes.
fn final_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, s :: d.Step) -> Str {
    let txt := step_text(s)
    if str.is_empty(txt) {
      acc
    } else {
      txt
    }
  })
}

# One human-readable line per notable step, for a demo/CLI to print live —
# tool calls, their pass/fail, and the model's final reply. Filters out
# raw token deltas (StepDelta) — too noisy for a one-line-per-event trace.
fn step_line(step :: d.Step) -> Option[Str] {
  match step {
    StepToolExec(name, id) => Some(str.concat("  -> calling ", name)),
    StepToolResult(id, ok) => Some(if ok {
      "     ok"
    } else {
      "     error"
    }),
    StepDone(AssistantMsg(text, _)) => if str.is_empty(text) {
      None
    } else {
      Some(str.concat("assistant: ", text))
    },
    _ => None,
  }
}

fn steps_to_lines(steps :: List[d.Step]) -> List[Str] {
  list.fold(steps, [], fn (acc :: List[Str], s :: d.Step) -> List[Str] {
    match step_line(s) {
      None => acc,
      Some(line) => list.concat(acc, [line]),
    }
  })
}

# Run the planner to completion against a live goal_text; returns the full
# step trace (StepToolExec/StepToolResult/StepDone/StepDelta) for a caller
# to render however it likes (steps_to_lines gives a ready-made summary).
fn plan(peer_url :: Str, session_id :: Str, provider :: prov.Provider, model :: prov.ModelRef, goal_text :: Str) -> [net, crypto, llm, io, proc] List[d.Step] {
  let ctx_id := open_client_session(peer_url, session_id)
  let agent := build_agent(peer_url, ctx_id, provider, model)
  iter.to_list(ag.run_loop(agent, [UserMsg(goal_text)]))
}

fn plan_opencode(peer_url :: Str, session_id :: Str, api_key :: Str, model_name :: Str, goal_text :: Str) -> [net, crypto, llm, io, proc] List[d.Step] {
  plan(peer_url, session_id, opencode_provider(api_key), opencode_model(model_name), goal_text)
}

# Traced variant: the same run, plus an lex-trail record of each LLM step
# and tool dispatch (llm_step / cap_invoked / cap_completed|cap_failed —
# see agent.lex's run_steps_traced) in `log`. This is the PLANNER's own
# reasoning trace; the physically-authoritative trail of what the robot
# actually did lives separately, inside a2a_robot_server.lex's own
# trail.Log on the server side — the two are complementary, not the same
# record twice.
fn plan_traced(peer_url :: Str, session_id :: Str, provider :: prov.Provider, model :: prov.ModelRef, goal_text :: Str, log :: trail.Log, parent :: Option[Str]) -> [net, crypto, llm, io, proc, sql, time] List[d.Step] {
  let ctx_id := open_client_session(peer_url, session_id)
  let agent := build_agent(peer_url, ctx_id, provider, model)
  iter.to_list(ag.run_loop_traced(agent, [UserMsg(goal_text)], log, parent))
}

fn plan_opencode_traced(peer_url :: Str, session_id :: Str, api_key :: Str, model_name :: Str, goal_text :: Str, log :: trail.Log, parent :: Option[Str]) -> [net, crypto, llm, io, proc, sql, time] List[d.Step] {
  plan_traced(peer_url, session_id, opencode_provider(api_key), opencode_model(model_name), goal_text, log, parent)
}

