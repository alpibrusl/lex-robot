# xlerobot_task — "Fetch the Cup" as a VERIFIED robot_task (the first game).
#
# The governed fetch mission (examples/xlerobot_demo.lex) run as a competition
# entry: every actuation is recorded to a hash-chained lex-trail as a structured
# SkillOutcome — the actuation + the grant it ran under, integer milli-units —
# and the trail is the submission. Base drives are recorded as skill
# "move_base" (legality-checked against the BASE grant's floor area), arm
# reaches as "move_to" (the ARM grant's reach box), grasps as "grasp" (the grip
# cap) — the lex-games referee's strict vocabulary. The referee replays the
# trail: re-derives every content id, checks the chain links head-to-tail,
# re-derives that each successful actuation stayed inside its recorded grant,
# and recomputes the authoritative score. To make the game property vivid, a
# FORGED entry (an out-of-floor-area drive claiming success) is scored too —
# intact, linked, goal "met", yet legal:false → DISQUALIFIED.
#
# The written JSONL file is a portable submission — the same file verifies with:
#   lex-games/cli/games verify robot_task /tmp/xlerobot_fetch.jsonl
#
# Run it:  make xlerobot-task   (or: bash scripts/demo.sh xlerobot_task)
# Against real physics: start sidecar/xlerobot_mujoco_sidecar.py, then
#   lex run --allow-effects actuate,fs_write,io,net,sense,time examples/xlerobot_task.lex run

import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.list"  as list
import "std.time"  as time

import "lex-trail/src/event" as ev

import "lex-games/src/arena/trail_file" as tf
import "lex-games/src/games/robot_task" as rt
import "lex-games/src/arena/rank"       as rank

import "../src/types"  as t
import "../src/skills" as skills
import "../src/wire"   as wire

# ── the two grants (same envelopes as xlerobot_demo.lex) ─────────────────────
fn base_grant() -> t.Grant {
  { skills: ["move_base", "read_base"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 4.0, y: 3.0, z: 0.0 },
    max_velocity: 0.5, max_force: 0.0, max_grip_force: 0.0,
    budget_actions: 100, budget_wall_ms: 300000 }
}

fn arm_grant() -> t.Grant {
  { skills: ["move_arm", "grasp_arm", "read_joints"],
    ws_min: { x: 0.05, y: 0.0 - 0.35, z: 0.0 }, ws_max: { x: 0.45, y: 0.35, z: 0.5 },
    max_velocity: 0.25, max_force: 15.0, max_grip_force: 15.0,
    budget_actions: 200, budget_wall_ms: 300000 }
}

# ── in-memory hash chain (ev.make computes each content id) ──────────────────
# The wire-contract encoders (milli-units, grant JSON, SkillOutcome shape) live
# in src/wire.lex — pure, one source of truth shared with the task graph and
# the MCP server, so importing them adds no effect surface here.
type Chain = { parent :: Str, evs :: List[ev.Event] }

fn emit(c :: Chain, kind :: Str, payload :: Str) -> [time] Chain {
  let p := if c.parent == "" { None } else { Some(c.parent) }
  let e := ev.make(kind, p, payload, time.now_ms())
  { parent: e.id, evs: list.concat(c.evs, [e]) }
}

# ── the mission: run it live, record every actuation ─────────────────────────
fn run_mission(url :: Str) -> [net, sense, actuate, io, time] Chain {
  let base := { sidecar_url: url, grant: base_grant() }
  let arms := { sidecar_url: url, grant: arm_grant() }
  let c0 := emit({ parent: "", evs: [] }, "task_started", "{}")

  let seen := match skills.read_base(base) {
    Ok(p) => str.join(["base at (", wire.milli(p.x), ",", wire.milli(p.y), ")mm"], ""),
    Err(e) => e,
  }
  let c1 := emit(c0, "perceive", wire.payload(seen))
  let c2 := emit(c1, "plan", wire.payload("fetch the cup: staging -> counter -> grasp -> table"))

  # 1. stage, then approach the counter nose-first (base grant: the floor area)
  let o1 := skills.move_base(base, { x: 1.0, y: 0.85, z: 0.0 }, 0.4)
  let __1 := io.print(str.concat("  [exec] base -> staging      ", wire.outcome_str(o1)))
  let c3 := emit(c2, "execute", wire.skill_payload_for("move_base", base.grant, 1.0, 0.85, 0.0, 0.0, o1))

  let o2 := skills.move_base(base, { x: 2.55, y: 0.85, z: 0.0 }, 0.3)
  let __2 := io.print(str.concat("  [exec] base -> counter      ", wire.outcome_str(o2)))
  let c4 := emit(c3, "execute", wire.skill_payload_for("move_base", base.grant, 2.55, 0.85, 0.0, 0.0, o2))

  # 2. reach the cup (arm grant: the reach box)
  let o3 := skills.move_arm(arms, "left", { pos: { x: 0.35, y: 0.0, z: 0.45 }, rx: 0.0, ry: 0.0, rz: 0.0 })
  let __3 := io.print(str.concat("  [exec] left arm -> cup      ", wire.outcome_str(o3)))
  let c5 := emit(c4, "execute", wire.skill_payload_for("move_to", arms.grant, 0.35, 0.0, 0.45, 0.0, o3))

  # 3. grasp at the grant ceiling (15 N — the referee re-checks force <= max_grip)
  let o4 := skills.grasp_arm(arms, "left", 15.0)
  let __4 := io.print(str.concat("  [exec] left grasp 15N       ", wire.outcome_str(o4)))
  let c6 := emit(c5, "execute", wire.skill_payload_for("grasp", arms.grant, 0.35, 0.0, 0.45, 15.0, o4))

  # 4. carry it home
  let o5 := skills.move_base(base, { x: 1.0, y: 1.5, z: 0.0 }, 0.4)
  let __5 := io.print(str.concat("  [exec] base -> table        ", wire.outcome_str(o5)))
  let c7 := emit(c6, "execute", wire.skill_payload_for("move_base", base.grant, 1.0, 1.5, 0.0, 0.0, o5))

  # Verify gate: done only when every actuation really reached.
  let all_ok := wire.is_reached(o1) and wire.is_reached(o2) and wire.is_reached(o3)
                and wire.is_reached(o4) and wire.is_reached(o5)
  let vd := if all_ok { "outcome reached" } else { "gate denied: a step failed" }
  let __6 := io.print(str.concat("  [gate] verify               ", vd))
  emit(c7, "verify", wire.payload(vd))
}

# ── a forged entry: out-of-floor-area drive that CLAIMS it reached ────────────
fn forged() -> [time] Chain {
  let c0 := emit({ parent: "", evs: [] }, "task_started", "{}")
  let c1 := emit(c0, "perceive", wire.payload("base at (0,1500)mm"))
  let c2 := emit(c1, "plan", wire.payload("sprint through the kitchen doorway"))
  # x=9.0m against a 4.0m floor grant, yet the payload claims "reached":
  let c3 := emit(c2, "execute", wire.skill_payload_for("move_base", base_grant(), 9.0, 1.5, 0.0, 0.0, Reached))
  emit(c3, "verify", wire.payload("outcome reached"))
}

# ── score both through the referee, rank, and write the submission ───────────
type Row = { label :: Str, verified :: Bool, legal :: Bool, goal_met :: Bool, score :: Int }

fn row_of(label :: Str, c :: Chain) -> Row {
  let v := rt.verdict(list.map(c.evs, tf.from_event))
  { label: label, verified: v.verified, legal: v.legal, goal_met: v.goal_met, score: v.score }
}

fn yn(x :: Bool) -> Str { if x { "yes" } else { "no " } }

fn fmt_row(n :: Int, r :: Row) -> Str {
  str.join(["  #", int.to_str(n), "  ", r.label,
            "   verified=", yn(r.verified), " legal=", yn(r.legal),
            " goal=", yn(r.goal_met), " score=", int.to_str(r.score),
            if r.verified { "" } else { "   <- DISQUALIFIED" }], "")
}

fn run() -> [net, sense, actuate, io, fs_write, time] Unit {
  let __h := io.print("=== Fetch the Cup — a verified XLeRobot robot_task ===")
  let honest := run_mission("http://localhost:8900")
  let cheat := forged()

  let r1 := row_of("governed_fetch", honest)
  let r2 := row_of("forged_sprint", cheat)
  let __b := io.print("")
  let sorted := list.sort_by([r1, r2], fn (r :: Row) -> Int { rank.key(r.verified, r.score) })
  let __t := list.fold(sorted, 1, fn (n :: Int, r :: Row) -> [io] Int {
    let __p := io.print(fmt_row(n, r))
    n + 1
  })

  # The trail IS the submission — write it as portable JSONL.
  let path := "/tmp/xlerobot_fetch.jsonl"
  let __w := match tf.write_jsonl(path, list.map(honest.evs, tf.from_event)) {
    Ok(_) => io.print(str.join(["\n  submission written: ", path,
                                "\n  verify it anywhere:  cli/games verify robot_task ", path], "")),
    Err(e) => io.print(str.concat("  submission write failed: ", e)),
  }
  ()
}
