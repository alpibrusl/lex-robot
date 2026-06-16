# lex-robot/examples/demo.lex — exercises the bounded skill API.
#
# Run (no sidecar needed to see the Denied path; the in-bounds call will report
# a network error if no sidecar is listening on :8900):
#   lex run --allow-effects net,sense,actuate,io examples/demo.lex run

import "std.io" as io

import "std.str" as str

import "../src/types" as t

import "../src/skills" as skills

fn outcome_str(o :: t.Outcome) -> Str {
  match o {
    Reached => "reached",
    Stalled(m) => str.concat("stalled: ", m),
    Denied(m) => str.concat("denied: ", m),
    Killed(m) => str.concat("killed: ", m),
    Timeout => "timeout",
  }
}

fn demo_grant() -> t.Grant {
  {
    skills: ["move_to", "grasp", "read_joints"],
    ws_min: { x: 0.1, y: 0.0 - 0.3, z: 0.0 },
    ws_max: { x: 0.5, y: 0.3, z: 0.4 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 20.0,
    budget_actions: 200,
    budget_wall_ms: 120000,
  }
}

fn run() -> [net, sense, actuate, io] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }

  # In-workspace target: grant allows it, so the skill reaches the sidecar.
  let good := { pos: { x: 0.3, y: 0.0, z: 0.2 }, rx: 0.0, ry: 0.0, rz: 0.0 }
  let __1 := io.print(str.concat("move_to in-bounds   → ", outcome_str(skills.move_to(robot, good))))

  # Out-of-workspace target: Denied by the grant — never hits the wire.
  let bad := { pos: { x: 0.9, y: 0.0, z: 0.2 }, rx: 0.0, ry: 0.0, rz: 0.0 }
  let __2 := io.print(str.concat("move_to out-bounds  → ", outcome_str(skills.move_to(robot, bad))))

  # Grip force is clamped to the grant ceiling before the command is sent.
  let __3 := io.print(str.concat("grasp(99N→clamped)  → ", outcome_str(skills.grasp(robot, 99.0))))
  ()
}
