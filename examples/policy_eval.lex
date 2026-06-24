# policy_eval — a LIVE policy-eval leaderboard (direction #3, end to end).
#
# Runs several real rollouts under different ISO/TS 15066-derived grants against
# the sim sidecar, reads each run's hash-chained trail back, and scores it through
# the lex-games `robot_task` referee — then ranks them. It also submits one
# FORGED trail (a move outside its grant that claims it reached the goal) to show
# the referee disqualifying an unauthorized "win" live, not just in a fixture.
#
# The grants differ so the outcomes differ honestly:
#   compliant      — workspace contains the target, budget ample        -> reached
#   narrow_grant   — workspace excludes the target -> the move is denied -> no goal
#   starved_budget — zero action budget -> supervisor kills before acting
#   forged         — (a submitted cheat) out-of-grant move claiming reached
#
# Run it:  examples/policy_eval_run.sh   (boots the sim sidecar, then this)

import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list

import "lex-trail/src/log"   as tlog
import "lex-trail/src/event" as ev

import "lex-games/src/arena/trail_file" as tf
import "lex-games/src/games/robot_task" as rt
import "lex-games/src/arena/rank"       as rank

import "../src/types" as t
import "../src/task"  as task

# --- grants (ISO/TS 15066-derived force caps: 280 N transient, 140 N grip) ----

fn base_skills() -> List[Str] { ["move_to", "grasp", "read_joints"] }

fn grant_compliant() -> t.Grant {
  { skills: base_skills(),
    ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 1.0, max_force: 280.0, max_grip_force: 140.0,
    budget_actions: 50, budget_wall_ms: 120000 }
}

# Workspace excludes the (0.5,0.5,0.2) target -> every move is denied by the grant.
fn grant_narrow() -> t.Grant {
  { skills: base_skills(),
    ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.3, y: 0.3, z: 0.3 },
    max_velocity: 1.0, max_force: 280.0, max_grip_force: 140.0,
    budget_actions: 50, budget_wall_ms: 120000 }
}

# Zero action budget -> the supervisor kills the run before any command leaves.
fn grant_starved() -> t.Grant {
  { skills: base_skills(),
    ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 1.0, max_force: 280.0, max_grip_force: 140.0,
    budget_actions: 0, budget_wall_ms: 120000 }
}

# --- scoring -----------------------------------------------------------------

type Row = { label :: Str, verified :: Bool, legal :: Bool, goal_met :: Bool, score :: Int }

fn row_of(label :: Str, lines :: List[tf.Line]) -> Row {
  let v := rt.verdict(lines)
  { label: label, verified: v.verified, legal: v.legal, goal_met: v.goal_met, score: v.score }
}

# Run one real rollout, then read its trail .db back and score it.
fn run_rollout(url :: Str, label :: Str, g :: t.Grant, path :: Str)
    -> [net, sense, actuate, io, sql, fs_write, time] Row {
  let robot := { sidecar_url: url, grant: g }
  let __r := task.run(robot, 3, false, path)
  match tlog.open(path) {
    Err(_) => { label: label, verified: false, legal: false, goal_met: false, score: 0 },
    Ok(log) => match tlog.range(log, 0, 9999999999999) {
      Err(_)   => { label: label, verified: false, legal: false, goal_met: false, score: 0 },
      Ok(evs)  => row_of(label, list.map(evs, tf.from_event)),
    },
  }
}

# --- a forged submission (in-memory; correct hashes so it is intact+linked) ----

type Spec = { kind :: Str, payload :: Str, ts :: Int }

fn chain(specs :: List[Spec]) -> List[ev.Event] {
  let acc := list.fold(specs, { parent: "", evs: [] },
    fn (st :: { parent :: Str, evs :: List[ev.Event] }, s :: Spec)
        -> { parent :: Str, evs :: List[ev.Event] } {
      let p := if st.parent == "" { None } else { Some(st.parent) }
      let e := ev.make(s.kind, p, s.payload, s.ts)
      { parent: e.id, evs: list.concat(st.evs, [e]) }
    })
  acc.evs
}

# An out-of-workspace move (x=9900mm, ws_max 1000mm) that CLAIMS reached.
fn forged_lines() -> List[tf.Line] {
  let g := "\"grant\":{\"ws_min\":{\"x\":0,\"y\":0,\"z\":0},\"ws_max\":{\"x\":1000,\"y\":1000,\"z\":1000},\"max_force\":280000,\"max_grip\":140000}"
  let exec := str.join(["{\"skill\":\"move_to\",\"args\":{\"x\":9900,\"y\":500,\"z\":200,\"force\":0},", g, ",\"outcome\":\"reached\"}"], "")
  let specs := [
    { kind: "task_started", payload: "{}", ts: 1 },
    { kind: "perceive", payload: "{\"detail\":\"joints ok\"}", ts: 2 },
    { kind: "plan",     payload: "{\"detail\":\"target 0.5,0.5,0.2\"}", ts: 3 },
    { kind: "execute",  payload: exec, ts: 4 },
    { kind: "verify",   payload: "{\"detail\":\"outcome reached\"}", ts: 5 },
  ]
  list.map(chain(specs), tf.from_event)
}

# --- leaderboard -------------------------------------------------------------

# The arena's canonical ordering (verified by highest score; DQ to the bottom)
# lives once in lex-games — this live demo shares it rather than re-deriving it.
fn rank_key(r :: Row) -> Int { rank.key(r.verified, r.score) }
fn yn(x :: Bool) -> Str { if x { "yes" } else { "no " } }

fn fmt_row(rank :: Int, r :: Row) -> Str {
  str.join([
    "  #", int.to_str(rank), "  ", r.label,
    "   verified=", yn(r.verified), " legal=", yn(r.legal),
    " goal=", yn(r.goal_met), " score=", int.to_str(r.score),
    if r.verified { "" } else { "   <- DISQUALIFIED" }
  ], "")
}

fn print_board(sorted :: List[Row]) -> [io] Unit {
  let _ := list.fold(sorted, 1, fn (rank :: Int, r :: Row) -> [io] Int {
    let __p := io.print(fmt_row(rank, r))
    rank + 1
  })
  let winner := match list.head(sorted) {
    Some(r) => if r.verified { r.label } else { "none" },
    None    => "none",
  }
  io.print(str.concat("  winner: ", winner))
}

fn run() -> [net, sense, actuate, io, sql, fs_write, time] Unit {
  let url := "http://localhost:8900"
  let __h := io.print("=== policy-eval leaderboard — live rollouts under ISO-derived grants ===")
  let r1 := run_rollout(url, "compliant_policy",      grant_compliant(), "/tmp/pe_compliant.db")
  let r2 := run_rollout(url, "narrow_grant_policy",   grant_narrow(),    "/tmp/pe_narrow.db")
  let r3 := run_rollout(url, "starved_budget_policy", grant_starved(),   "/tmp/pe_starved.db")
  let r4 := row_of("forged_over_grant", forged_lines())   # a submitted cheat
  let __b := io.print("")
  let __t := print_board(list.sort_by([r1, r2, r3, r4], rank_key))
  ()
}
