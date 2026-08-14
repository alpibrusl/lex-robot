# lex-robot/examples/llm_command_demo.lex — "bring me the cup," spoken to the
# robot and answered out loud: voice in (listen, faster-whisper), a REAL
# OpenCode-backed LLM plan (src/llm_planner.lex), grant-gated execution over
# the robot's own A2A server, voice out (speak, Kokoro).
#
# This is the live end of the mechanism tests/test_llm_planner.lex verifies
# mechanically with a scripted mock model (no API key needed there — see
# `make xlerobot-llm-mock`). Here a REAL hosted model decides what to do;
# everything downstream (every tool call still going through
# a2a_robot_server.lex's actual grant/budget/trail) is identical either way.
#
# KNOWN LIMITATION, stated honestly rather than hidden: examples/a2a_robot_demo.lex
# (the server this demo talks to) shares ONE grant box across move_base AND
# move_arm/grasp_arm — unlike the in-process xlerobot_demo.lex, which splits
# a room-scale base grant from an SO-101-scale arm grant. That single box is
# arm-sized (x:[0.05,0.45], y:[0,0.35]), so a move_base command to actually
# cross the room to the cup's real location gets denied — a genuine
# architectural gap in a2a_robot_server.lex today (giving A2A callers the
# base/arm grant split the in-process API already has is real, scoped,
# NOT-YET-DONE follow-up work, not something papered over here). Expect this
# demo's likely outcome to be: the model locates the cup for real (vision,
# ungated), tries to drive to it, gets denied, and — per its own system
# prompt rule 3 — explains that rather than pretending success. That is the
# grant doing its job, not a bug in this demo.
#
# Prereqs (see Makefile):
#   OPENCODE_API_KEY set (get one at opencode.ai/zen)
#   sidecar/xlerobot_mujoco_sidecar.py (or the Tier-1 stub) running on :8900
#   examples/a2a_robot_demo.lex running on :8766 (its grant covers
#     move_arm/grasp_arm/move_base/read_base; speak/listen/locate_object/
#     transform_to_arm are ungated or -- for speak -- covered separately,
#     see a2a_robot_server.lex)
#
# Run (spoken goal — the sidecar's `listen` transcribes it):
#   OPENCODE_MODEL=kimi-k2.6 OPENCODE_API_KEY=sk-... \
#     lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,env,stream \
#       examples/llm_command_demo.lex run
# Run (typed goal, skips listen entirely):
#     lex run --allow-effects ...same as above... \
#       examples/llm_command_demo.lex run_text '"bring me the cup"'

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "../src/types" as t

import "../src/sense" as sense

import "../src/llm_planner" as planner

fn sensor_robot() -> t.Robot {
  { sidecar_url: "http://localhost:8900", grant: { skills: ["listen"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 10, budget_wall_ms: 60000 } }
}

# Same shape xlerobot_voice_demo.lex uses — the sidecar's transcription JSON
# is {"transcript": "...", ...}, space-after-colon tolerant.
fn transcript_of(json :: Str) -> Str {
  let parts := str.split(json, "\"transcript\"")
  match list.head(list.tail(parts)) {
    None => "",
    Some(rest) => match list.head(list.tail(str.split(rest, "\""))) {
      None => "",
      Some(tr) => tr,
    },
  }
}

fn goal_from_voice() -> [net, sense, io] Str {
  match sense.listen(sensor_robot(), 4) {
    Err(e) => {
      let __p := io.print(str.concat("listen failed, using a default goal: ", e))
      "bring me the cup"
    },
    Ok(resp) => {
      let tr := transcript_of(resp)
      let __p := io.print(str.concat("heard: ", tr))
      tr
    },
  }
}

fn run_goal(goal_text :: Str) -> [net, crypto, llm, io, proc, env, stream, approval] Unit {
  let api_key := match env.get("OPENCODE_API_KEY") {
    None => "",
    Some(v) => v,
  }
  if str.is_empty(api_key) {
    io.print("error: OPENCODE_API_KEY not set — get one at opencode.ai/zen")
  } else {
    let model_name := match env.get("OPENCODE_MODEL") {
      None => planner.default_model(),
      Some(v) => if str.is_empty(v) {
        planner.default_model()
      } else {
        v
      },
    }
    let __0 := io.print(str.concat("goal: ", goal_text))
    let __1 := io.print(str.concat("model: opencode-go/", model_name))
    let steps := planner.plan_opencode("http://localhost:8766", "llmcmd-1", api_key, model_name, goal_text)
    let lines := planner.steps_to_lines(steps)
    io.print(str.join(lines, "\n"))
  }
}

# Spoken goal: listens first, then hands the transcript to run_goal.
fn run() -> [net, crypto, sense, llm, io, proc, env, stream, approval] Unit {
  run_goal(goal_from_voice())
}

# Typed goal: skips listen entirely.
fn run_text(goal_text :: Str) -> [net, crypto, llm, io, proc, env, stream, approval] Unit {
  run_goal(goal_text)
}

