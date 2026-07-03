# xlerobot_task — "Fetch the Cup" as a VERIFIED robot_task (the first game).
#
# The governed fetch mission (examples/xlerobot_demo.lex) run as a competition
# entry: every actuation is recorded to a hash-chained lex-trail as a structured
# SkillOutcome — the actuation + the grant it ran under, integer milli-units —
# and the trail is the submission. The lex-games `robot_task` referee replays
# it: re-derives every content id, checks the chain links head-to-tail,
# re-derives that each successful actuation stayed inside its recorded grant,
# and recomputes the authoritative score. To make the game property vivid, a
# FORGED entry (an out-of-floor-area base move claiming success) is scored too —
# intact, linked, goal "met", yet legal:false → DISQUALIFIED.
#
# The written JSONL file is a portable submission — the same file verifies with:
#   lex-games/cli/games verify robot_task /tmp/xlerobot_fetch.jsonl
#
# Run it:  examples/xlerobot_task_run.sh   (boots the XLeRobot stub sidecar)
# Against real physics: start sidecar/xlerobot_mujoco_sidecar.py instead.

import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.float" as flt
import "std.list"  as list
import "std.time"  as time

import "lex-trail/src/event" as ev

import "lex-games/src/arena/trail_file" as tf
import "lex-games/src/games/robot_task" as rt
import "lex-games/src/arena/rank"       as rank

import "../src/types"  as t
import "../src/skills" as skills

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

# ── structured SkillOutcome payloads (integer milli-units, task.lex shape) ───
fn milli(x :: Float) -> Str { int.to_str(flt.to_int(x * 1000.0)) }

fn grant_json(g :: t.Grant) -> Str {
  str.join([
    "\"grant\":{\"ws_min\":{\"x\":", milli(g.ws_min.x), ",\"y\":", milli(g.ws_min.y), ",\"z\":", milli(g.ws_min.z),
    "},\"ws_max\":{\"x\":", milli(g.ws_max.x), ",\"y\":", milli(g.ws_max.y), ",\"z\":", milli(g.ws_max.z),
    "},\"max_force\":", milli(g.max_force), ",\"max_grip\":", milli(g.max_grip_force), "}"
  ], "")
}

fn outcome_str(o :: t.Outcome) -> Str {
  match o {
    Reached => "reached",
    Stalled(m) => str.replace(str.concat("stalled: ", m), "\"", "'"),
    Denied(m) => str.replace(str.concat("denied: ", m), "\"", "'"),
    Killed(m) => str.replace(str.concat("killed: ", m), "\"", "'"),
    Timeout => "timeout",
  }
}

# One structured execute payload. The referee legality-checks skill "move_to"
# against the payload's ws box and "grasp" against its max_grip — so a base
# drive is recorded as a move_to under the BASE grant (its floor area) and an
# arm reach as a move_to under the ARM grant (its reach box). The grant in the
# payload is the authority the actuation actually ran under.
fn exec_payload(skill :: Str, g :: t.Grant, x :: Float, y :: Float, z :: Float, force :: Float, o :: t.Outcome) -> Str {
  str.join([
    "{\"skill\":\"", skill, "\",\"args\":{\"x\":", milli(x), ",\"y\":", milli(y),
    ",\"z\":", milli(z), ",\"force\":", milli(force), "},", grant_json(g),
    ",\"outcome\":\"", outcome_str(o), "\"}"
  ], "")
}

fn detail_payload(d :: Str) -> Str {
  str.join(["{\"detail\":\"", str.replace(str.replace(d, "\"", "'"), "\n", " "), "\"}"], "")
}

# ── in-memory hash chain (ev.make computes each content id) ──────────────────
type Chain = { parent :: Str, evs :: List[ev.Event] }

fn emit(c :: Chain, kind :: Str, payload :: Str) -> [time] Chain {
  let p := if c.parent == "" { None } else { Some(c.parent) }
  let e := ev.make(kind, p, payload, time.now_ms())
  { parent: e.id, evs: list.concat(c.evs, [e]) }
}

fn is_reached(o :: t.Outcome) -> Bool { match o { Reached => true, _ => false } }

# ── the mission: run it live, record every actuation ─────────────────────────
fn run_mission(url :: Str) -> [net, sense, actuate, io, time] Chain {
  let base := { sidecar_url: url, grant: base_grant() }
  let arms := { sidecar_url: url, grant: arm_grant() }
  let c0 := emit({ parent: "", evs: [] }, "task_started", "{}")

  let seen := match skills.read_base(base) { Ok(p) => str.join(["base at (", milli(p.x), ",", milli(p.y), ")mm"], ""), Err(e) => e }
  let c1 := emit(c0, "perceive", detail_payload(seen))
  let c2 := emit(c1, "plan", detail_payload("fetch the cup: counter -> grasp -> table"))

  # 1. drive to the counter (base grant: the floor area)
  let o1 := skills.move_base(base, { x: 2.55, y: 0.85, z: 0.0 }, 0.3)
  let __1 := io.print(str.concat("  [exec] base -> counter      ", outcome_str(o1)))
  let c3 := emit(c2, "execute", exec_payload("move_to", base_grant(), 2.55, 0.85, 0.0, 0.0, o1))

  # 2. reach the cup (arm grant: the reach box)
  let o2 := skills.move_arm(arms, "left", { pos: { x: 0.35, y: 0.0, z: 0.45 }, rx: 0.0, ry: 0.0, rz: 0.0 })
  let __2 := io.print(str.concat("  [exec] left arm -> cup      ", outcome_str(o2)))
  let c4 := emit(c3, "execute", exec_payload("move_to", arm_grant(), 0.35, 0.0, 0.45, 0.0, o2))

  # 3. grasp at the grant ceiling (15 N — the referee re-checks force <= max_grip)
  let o3 := skills.grasp_arm(arms, "left", 15.0)
  let __3 := io.print(str.concat("  [exec] left grasp 15N       ", outcome_str(o3)))
  let c5 := emit(c4, "execute", exec_payload("grasp", arm_grant(), 0.35, 0.0, 0.45, 15.0, o3))

  # 4. carry it home
  let o4 := skills.move_base(base, { x: 1.0, y: 1.5, z: 0.0 }, 0.4)
  let __4 := io.print(str.concat("  [exec] base -> table        ", outcome_str(o4)))
  let c6 := emit(c5, "execute", exec_payload("move_to", base_grant(), 1.0, 1.5, 0.0, 0.0, o4))

  # Verify gate: done only when every actuation really reached.
  let all_ok := is_reached(o1) and is_reached(o2) and is_reached(o3) and is_reached(o4)
  let vd := if all_ok { "outcome reached" } else { "gate denied: a step failed" }
  let __5 := io.print(str.concat("  [gate] verify               ", vd))
  emit(c6, "verify", detail_payload(vd))
}

# ── a forged entry: out-of-floor-area drive that CLAIMS it reached ────────────
fn forged() -> [time] Chain {
  let c0 := emit({ parent: "", evs: [] }, "task_started", "{}")
  let c1 := emit(c0, "perceive", detail_payload("base at (0,1500)mm"))
  let c2 := emit(c1, "plan", detail_payload("sprint through the kitchen doorway"))
  # x=9.0m against a 4.0m floor grant, yet the payload claims "reached":
  let c3 := emit(c2, "execute", exec_payload("move_to", base_grant(), 9.0, 1.5, 0.0, 0.0, Reached))
  emit(c3, "verify", detail_payload("outcome reached"))
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
