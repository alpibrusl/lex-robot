# examples/xlerobot_policy_rollout.lex — a POLICY's rollout, run through the
# grant gate (lex-robot epic #63 / PR #76's stated next step).
#
# gym_env/xlerobot_policy_eval.py runs a closed-loop policy (a reactive
# geometric controller today; a future RL-trained policy against the
# registered LexXLeRobotFetch-v0 gym env plugs into the exact same rollout
# format) against the SAME physics core the gym wraps, and writes its rollout
# — the sequence of skill calls it chose, in the exact units/frame the
# governed skills expect — to a JSON file. This program reads that rollout and
# REPLAYS it through the actual governed skill surface (skills.move_base /
# move_arm / grasp_arm, against a live sidecar): every command the policy
# chose is re-issued under the SAME base + arm grants xlerobot_task.lex uses,
# gated and clamped exactly as it would be for any other operator, and chained
# into a robot_task-format trail. "Roll out through the grant gate."
#
# The trail is then verified (lex-games robot_task) and written as a portable
# submission — the completion of the loop: train/eval (Python/gym) -> roll out
# through the grant gate (this file, Lex) -> verify (the referee) -> did:lex
# reputation (examples/agent_registry.lex, the kernel built in #80/#81).
#
# Run: lex run --allow-effects net,sense,actuate,io,fs_write,time \
#   examples/xlerobot_policy_rollout.lex run '"/tmp/xlerobot_rollout.json"' '"/tmp/xlerobot_policy_trail.jsonl"'
# (against sidecar/xlerobot_sidecar.py on :8900 — see examples/xlerobot_policy_run.sh)

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

import "std.time" as time

import "std.float" as flt

import "lex-trail/src/event" as ev

import "lex-games/src/arena/trail_file" as tf

import "lex-games/src/games/robot_task" as rt

import "../src/types" as t

import "../src/skills" as skills

import "../src/wire" as wire

fn base_grant() -> t.Grant {
  { skills: ["move_base", "read_base"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 4.0, y: 3.0, z: 0.0 }, max_velocity: 0.5, max_force: 0.0, max_grip_force: 0.0, budget_actions: 100, budget_wall_ms: 300000 }
}

fn arm_grant() -> t.Grant {
  { skills: ["move_arm", "grasp_arm", "read_joints"], ws_min: { x: 0.05, y: 0.0 - 0.35, z: 0.0 }, ws_max: { x: 0.45, y: 0.35, z: 0.5 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 15.0, budget_actions: 200, budget_wall_ms: 300000 }
}

# One step of the policy's rollout — a uniform shape across skill kinds (the
# fields not used by a given skill are simply 0.0), matching the JSON the eval
# script writes.
type Step = { skill :: Str, x :: Float, y :: Float, z :: Float, speed :: Float, force :: Float, sim_outcome :: Str }

type Rollout = { policy :: Str, steps :: List[Step] }

type Chain = { parent :: Str, evs :: List[ev.Event] }

fn emit(c :: Chain, kind :: Str, payload :: Str) -> [time] Chain {
  let p := if c.parent == "" {
    None
  } else {
    Some(c.parent)
  }
  let e := ev.make(kind, p, payload, time.now_ms())
  { parent: e.id, evs: list.concat(c.evs, [e]) }
}

# Re-issue one rollout step through the GOVERNED skill it names — the policy's
# decision is replayed, not re-derived; the grant decides whether it stands.
fn replay_step(url :: Str, c :: Chain, s :: Step) -> [net, sense, actuate, io, time] Chain {
  if s.skill == "move_base" {
    let base := { sidecar_url: url, grant: base_grant() }
    let o := skills.move_base(base, { x: s.x, y: s.y, z: 0.0 }, s.speed)
    let __p := io.print(str.join(["  [replay] move_base(", flt_str(s.x), ",", flt_str(s.y), ") ", wire.outcome_str(o)], ""))
    emit(c, "execute", wire.skill_payload_for("move_base", base.grant, s.x, s.y, 0.0, 0.0, o))
  } else {
    if s.skill == "move_arm" {
      let arms := { sidecar_url: url, grant: arm_grant() }
      let o := skills.move_arm(arms, "left", { pos: { x: s.x, y: s.y, z: s.z }, rx: 0.0, ry: 0.0, rz: 0.0 })
      let __p := io.print(str.join(["  [replay] move_arm(", flt_str(s.x), ",", flt_str(s.y), ",", flt_str(s.z), ") ", wire.outcome_str(o)], ""))
      emit(c, "execute", wire.skill_payload_for("move_to", arms.grant, s.x, s.y, s.z, 0.0, o))
    } else {
      let arms := { sidecar_url: url, grant: arm_grant() }
      let o := skills.grasp_arm(arms, "left", s.force)
      let __p := io.print(str.join(["  [replay] grasp(", flt_str(s.force), "N) ", wire.outcome_str(o)], ""))
      emit(c, "execute", wire.skill_payload_for("grasp", arms.grant, 0.0, 0.0, 0.0, s.force, o))
    }
  }
}

fn flt_str(x :: Float) -> Str {
  flt.to_str(x)
}

fn replay_all(url :: Str, steps :: List[Step]) -> [net, sense, actuate, io, time] Chain {
  let c0 := emit({ parent: "", evs: [] }, "task_started", "{}")
  let c1 := emit(c0, "perceive", wire.payload("policy rollout: fetch the cup"))
  let c2 := emit(c1, "plan", wire.payload("replay the policy's chosen skill sequence under the grant"))
  let c3 := list.fold(steps, c2, fn (c :: Chain, s :: Step) -> [net, sense, actuate, io, time] Chain {
    replay_step(url, c, s)
  })
  emit(c3, "verify", wire.payload("outcome reached"))
}

fn run(rollout_path :: Str, trail_path :: Str) -> [net, sense, actuate, io, fs_write, time] Int {
  let __h := io.print("=== XLeRobot policy rollout, replayed through the grant gate ===")
  match io.read(rollout_path) {
    Err(e) => {
      let __e := io.print(str.concat("cannot read rollout: ", e))
      1
    },
    Ok(content) => {
      let parsed :: Result[Rollout, Str] := json.parse(content)
      match parsed {
        Err(e) => {
          let __e := io.print(str.concat("bad rollout json: ", e))
          1
        },
        Ok(r) => {
          let __p := io.print(str.join(["policy: ", r.policy, " (", int.to_str(list.len(r.steps)), " steps)\n"], ""))
          let chain := replay_all("http://localhost:8900", r.steps)
          let lines := list.map(chain.evs, tf.from_event)
          let v := rt.verdict(lines)
          let __w := io.write(trail_path, tf.to_jsonl(lines))
          let __v := io.print(str.join(["\n[verify] ", rt.verdict_json(v)], ""))
          if v.verified {
            0
          } else {
            1
          }
        },
      }
    },
  }
}

