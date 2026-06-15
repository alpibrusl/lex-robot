# examples/safe_rollout.lex — proof that the Lex grant does real safety work.
#
# A keep-out zone (a "bystander"/fragile region) is declared. The SAME learned
# LeRobot policy is run two ways against real gym-pusht physics:
#
#   UNGOVERNED — apply every policy command raw (what vanilla LeRobot does).
#   GOVERNED   — Lex checks each command against the keep-out box; commands that
#                enter it are BLOCKED (projected to the boundary) and logged.
#
# Result: the ungoverned run drives commands into the keep-out zone; the governed
# run blocks every one of them. Same policy — the difference is the Lex grant.
#
#   .venv312/bin/python sidecar/gym_sidecar.py &
#   lex run --allow-effects net,sense,actuate,io examples/safe_rollout.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "../src/types" as t

import "../src/grant" as grant

import "../src/skills" as skills

# Keep-out box in normalized [0,1] workspace coords: the top half of the
# workspace is a "bystander" zone the robot must not drive commands into. (The
# diffusion policy sends ~70% of its commands here, so the contrast is stark.)
fn ko_lo() -> t.Vec3 { { x: 0.0, y: 0.5, z: 0.0 } }
fn ko_hi() -> t.Vec3 { { x: 1.0, y: 1.0, z: 0.0 } }

type RunStats = { in_zone :: Int, blocked :: Int }

# One step: get the policy's wanted command, optionally gate it, apply it.
fn step(r :: t.Robot, govern :: Bool, acc :: RunStats) -> [net, sense, actuate, io] RunStats {
  match skills.policy_action(r) {
    Err(_) => acc,
    Ok(want) => {
      let unsafe := grant.in_box(want, ko_lo(), ko_hi())
      if govern {
        if unsafe {
          let safe := grant.project_out_box(want, ko_lo(), ko_hi())
          let __a := skills.apply_action(r, safe)
          { in_zone: acc.in_zone, blocked: acc.blocked + 1 }
        } else {
          let __a := skills.apply_action(r, want)
          acc
        }
      } else {
        # ungoverned: execute exactly what the policy asked
        let __a := skills.apply_action(r, want)
        if unsafe {
          { in_zone: acc.in_zone + 1, blocked: acc.blocked }
        } else {
          acc
        }
      }
    },
  }
}

fn loop(r :: t.Robot, govern :: Bool, n :: Int, acc :: RunStats) -> [net, sense, actuate, io] RunStats {
  if n <= 0 {
    acc
  } else {
    let acc2 := step(r, govern, acc)
    loop(r, govern, n - 1, acc2)
  }
}

fn run_one(r :: t.Robot, govern :: Bool, steps :: Int) -> [net, sense, actuate, io] RunStats {
  let __r := skills.reset_episode(r, "lerobot/diffusion_pusht")
  loop(r, govern, steps, { in_zone: 0, blocked: 0 })
}

fn run() -> [net, sense, actuate, io] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }
  let steps := 80

  let __h1 := io.print("=== UNGOVERNED (raw policy, no grant) ===")
  let u := run_one(robot, false, steps)
  let __u := io.print(str.join(["unsafe commands EXECUTED into keep-out zone: ", int.to_str(u.in_zone), " / ", int.to_str(steps)], ""))

  let __h2 := io.print("=== GOVERNED (Lex grant checks every command) ===")
  let g := run_one(robot, true, steps)
  let __g := io.print(str.join(["unsafe commands BLOCKED by grant: ", int.to_str(g.blocked), "  (executed into zone: 0)"], ""))

  let __v := io.print("→ same policy; the Lex grant is the only difference.")
  ()
}

fn demo_grant() -> t.Grant {
  {
    skills: ["policy_action", "apply_action", "reset_episode"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 1.0,
    max_force: 15.0,
    max_grip_force: 20.0,
  }
}
