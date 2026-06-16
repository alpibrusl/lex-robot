# lex-robot/examples/task_demo.lex — the evidence-gated task graph end to end.
#
# Perceive → Plan → Execute → Verify against a running sidecar:
#   python3 sidecar/sim_sidecar.py &          # or gym_sidecar.py
#   lex run --allow-effects net,sense,actuate,io,sql,fs_write,time examples/task_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "../src/types" as t

import "../src/task" as task

fn demo_grant() -> t.Grant {
  {
    skills: ["move_to", "grasp", "read_joints", "run_policy"],
    ws_min: { x: 0.1, y: 0.0 - 0.3, z: 0.0 },
    ws_max: { x: 0.9, y: 0.9, z: 0.4 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 20.0,
    budget_actions: 200,
    budget_wall_ms: 120000,
  }
}

fn run() -> [net, sense, actuate, io, sql, fs_write, time] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }
  # use_policy=false → fast structural pass; set true to gate on a real
  # LeRobot policy solving the task (needs the gym sidecar + lerobot).
  let result := task.run(robot, 3, false, "/tmp/lex-robot-trail.db")
  let verdict := if result.killed { "KILLED" } else { if result.success { "SUCCESS" } else { "FAILED" } }
  let __1 := io.print(str.join(["task ", verdict, " after ", int.to_str(result.attempts), " attempt(s)"], ""))
  let __2 := io.print(str.concat("trail head: ", result.last_event))
  ()
}
