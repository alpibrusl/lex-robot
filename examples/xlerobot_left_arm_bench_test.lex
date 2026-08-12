# lex-robot/examples/xlerobot_left_arm_bench_test.lex — minimal single-arm
# bench test, arms only (no base — this rig has no base motor controller
# attached). Reads joints, nudges the left arm to a modest target well
# inside its reach box, opens and closes the gripper, then reports back.
#
# Unlike xlerobot_demo.lex, the move target here is NOT read live from the
# arm first (a contention issue with something else polling the sidecar
# blocked that at write time) — it's a conservative, previously-verified-
# reachable point for this specific rig, not derived from a live reading.
# Watch the arm on first run regardless.
#
# Run (sidecar must already be up in hardware mode, nothing else polling it):
#   lex run --allow-effects net,sense,actuate,io examples/xlerobot_left_arm_bench_test.lex run

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

# Left arm's envelope: same SO-101 reach box as xlerobot_demo.lex's
# arm_grant(), scoped to just the skills this script actually calls.
fn arm_grant() -> t.Grant {
  {
    skills: ["move_arm", "grasp_arm", "read_joints"],
    ws_min: { x: 0.05, y: 0.0, z: 0.0 },
    ws_max: { x: 0.45, y: 0.35, z: 0.5 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 15.0,
    budget_actions: 20,
    budget_wall_ms: 60000,
  }
}

fn run() -> [net, sense, actuate, io] Unit {
  let arms := { sidecar_url: "http://localhost:8900", grant: arm_grant() }

  let __0 := match skills.read_joints(arms) {
    Ok(j) => io.print(str.concat("read_joints (left)             → ", j)),
    Err(e) => io.print(str.concat("read_joints failed             → ", e)),
  }

  # A modest, conservative target well inside the reach box — not read live
  # from the arm (see header). Roughly mid-envelope, low and close in.
  let target := { pos: { x: 0.30, y: 0.0, z: 0.15 }, rx: 0.0, ry: 0.0, rz: 0.0 }
  let __1 := io.print(str.concat("left arm → (0.30,0.0,0.15)     → ", outcome_str(skills.move_arm(arms, "left", target))))

  # Open the gripper. No release_arm wrapper exists in Lex yet (only the
  # sidecar has that endpoint) — grasp_arm with force 0.0 is the equivalent:
  # the sidecar maps force → gripper.pos linearly, so 0.0 N means fully open.
  let __2 := io.print(str.concat("left gripper open (grasp 0N)   → ", outcome_str(skills.grasp_arm(arms, "left", 0.0))))

  # Close gently.
  let __3 := io.print(str.concat("left gripper close (5N)        → ", outcome_str(skills.grasp_arm(arms, "left", 5.0))))

  # Back open before ending, so the arm isn't left gripping something.
  let __4 := io.print(str.concat("left gripper open (grasp 0N)   → ", outcome_str(skills.grasp_arm(arms, "left", 0.0))))
  ()
}
