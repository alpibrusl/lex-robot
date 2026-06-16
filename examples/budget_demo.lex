# lex-robot/examples/budget_demo.lex — the budget supervisor kills a run.
#
# Same evidence-gated task as task_demo.lex, but the grant carries a ZERO action
# budget. The supervisor (src/budget.lex) checks the budget BEFORE the first
# command leaves the box, so the run is killed with `budget_actions: 0` — no
# move_to ever reaches the sidecar. The kill is recorded as a `killed` event in
# the hash-chained trail, right after `task_started`.
#
# This is the runtime twin of the effect wall: the effect wall stops actuation
# at compile/grant-admission time; the budget stops it at *exhaustion* time.
#
#   python3 sidecar/sim_sidecar.py &
#   lex run --allow-effects net,sense,actuate,io,sql,fs_write,time examples/budget_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "../src/types" as t

import "../src/task" as task

# Identical to task_demo's grant except budget_actions: 0 — the run may issue no
# actuating commands at all, so the supervisor kills it immediately.
fn starved_grant() -> t.Grant {
  {
    skills: ["move_to", "grasp", "read_joints", "run_policy"],
    ws_min: { x: 0.1, y: 0.0 - 0.3, z: 0.0 },
    ws_max: { x: 0.9, y: 0.9, z: 0.4 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 20.0,
    budget_actions: 0,
    budget_wall_ms: 120000,
  }
}

fn run() -> [net, sense, actuate, io, sql, fs_write, time] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: starved_grant() }
  let result := task.run(robot, 3, false, "/tmp/lex-robot-budget-trail.db")
  let verdict := if result.killed { "KILLED" } else { if result.success { "SUCCESS" } else { "FAILED" } }
  let __1 := io.print(str.join(["task ", verdict, " after ", int.to_str(result.attempts), " attempt(s)"], ""))
  let __2 := io.print(str.concat("trail head: ", result.last_event))
  ()
}
