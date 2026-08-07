# lex-robot/examples/find_and_fetch_demo.lex — "bring me the cup": a
# vision-grounded fetch, with NO privileged read of the object's true
# position anywhere in this program.
#
# This closes the gap flagged when answering "how does an agentic LLM turn
# 'bring me a beer' into something it can actually execute": the LLM can name
# an object, but naming it is not the same as knowing where it is. Without
# object grounding, "bring me the cup" has no path to a `move_arm` target at
# all — the planner has a word, not a pose. `locate_object` (src/sense.lex)
# is that missing link: real perception (Tier-2 MuJoCo: color-threshold
# detection + ray-cast against the ACTUAL rendered camera image; Tier-1: an
# explicitly-labeled canned lookup so this demo also runs with no physics
# dependency) turns the name into a world-frame position, exactly the way a
# real vision model's bounding-box-to-3D-point pipeline would.
#
# Two-step look, then move: the head camera can only see the cup from a
# stand-off vantage point — any closer and the counter's own front edge
# blocks the line of sight (see gym_env/xlerobot_sim.py's `locate_object`
# doc). So the mission locates from a distance, drives in on the strength of
# that single sighting, and re-projects the SAME world position into the
# arm's new frame with `transform_to_arm` once the base has moved — it does
# not (cannot) visually servo the final few centimetres. This is a genuine
# architectural constraint of the camera mount, not a shortcut, and mirrors
# real "look-then-move" pick pipelines that don't keep the target in frame
# through the final approach.
#
# Grant shape: the base grant lists locate_object/transform_to_arm alongside
# move_base/read_base for documentation (they carry no grant check — see
# sense.lex — since neither one actuates anything); the arm grant is the
# usual SO-101 reach box + grip ceiling.
#
# Run (starts sidecar/xlerobot_mujoco_sidecar.py first — or `make xlerobot-find`):
#   lex run --allow-effects net,sense,actuate,io examples/find_and_fetch_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.float" as flt

import "std.math" as mm

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

fn base_grant() -> t.Grant {
  {
    skills: ["move_base", "read_base", "locate_object", "transform_to_arm"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 4.0, y: 3.0, z: 0.0 },
    max_velocity: 0.5,
    max_force: 0.0,
    max_grip_force: 0.0,
    budget_actions: 100,
    budget_wall_ms: 300000,
  }
}

fn arm_grant() -> t.Grant {
  {
    skills: ["move_arm", "grasp_arm", "read_joints"],
    ws_min: { x: 0.05, y: 0.0 - 0.35, z: 0.0 },
    ws_max: { x: 0.45, y: 0.35, z: 0.5 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 15.0,
    budget_actions: 200,
    budget_wall_ms: 300000,
  }
}

fn clampf(v :: Float, lo :: Float, hi :: Float) -> Float { mm.min(mm.max(v, lo), hi) }

fn fmt3(x :: Float, y :: Float, z :: Float) -> Str {
  str.join(["(", flt.to_str(x), ",", flt.to_str(y), ",", flt.to_str(z), ")"], "")
}

# A room-knowledge waypoint (NOT the object's position) — "stand off from the
# counter and look" is something the robot's floorplan can tell it before it
# has ever seen the cup, the same distinction a real deployment draws between
# a map and object knowledge. Chosen so the head camera clears the counter's
# front edge (see the module doc above and gym_env/xlerobot_sim.py).
fn search_vantage() -> t.Vec3 { { x: 2.3, y: 1.0, z: 0.0 } }

fn run() -> [net, sense, actuate, io] Unit {
  let base := { sidecar_url: "http://localhost:8900", grant: base_grant() }
  let arms := { sidecar_url: "http://localhost:8900", grant: arm_grant() }
  let vantage := search_vantage()

  let __0 := io.print(str.concat("base → search vantage (2.3,1.0) → ", outcome_str(skills.move_base(base, vantage, 0.4))))

  match skills.locate_object(base, "cup") {
    Err(e) => io.print(str.concat("locate_object 'cup' failed     → ", e)),
    Ok(loc) => {
      let __1 := io.print(str.concat("located 'cup' at world          → ", fmt3(loc.world.x, loc.world.y, loc.world.z)))

      # Approach: stand off 0.55m short of the located point, along the
      # straight-line direction from the vantage — the base's own final
      # heading (not a memorized waypoint) determines the arm's frame.
      let dx := loc.world.x - vantage.x
      let dy := loc.world.y - vantage.y
      let dist := mm.max(mm.sqrt(dx * dx + dy * dy), 0.000001)
      let stage := { x: loc.world.x - (dx / dist) * 0.55, y: loc.world.y - (dy / dist) * 0.55, z: 0.0 }
      let __2 := io.print(str.concat("base → approach                 → ", outcome_str(skills.move_base(base, stage, 0.4))))

      # The base moved, so the OLD arm-frame offset from locate_object no
      # longer applies — re-project the SAME world position (no new camera
      # read: this range is the occluded one) into the arm's current frame.
      match skills.transform_to_arm(base, loc.world) {
        Err(e) => io.print(str.concat("transform_to_arm failed         → ", e)),
        Ok(tgt) => {
          let target := {
            pos: {
              x: clampf(tgt.offset.x, 0.05, 0.45),
              y: clampf(tgt.offset.y, 0.0 - 0.35, 0.35),
              z: clampf(tgt.offset.z, 0.0, 0.5),
            },
            rx: 0.0, ry: 0.0, rz: 0.0,
          }
          let __3 := io.print(str.concat(tgt.arm, str.concat(" arm → cup                  → ", outcome_str(skills.move_arm(arms, tgt.arm, target)))))
          let __4 := io.print(str.concat(tgt.arm, str.concat(" grasp 15N                  → ", outcome_str(skills.grasp_arm(arms, tgt.arm, 15.0)))))
          let home := { x: 0.5, y: 1.5, z: 0.0 }
          io.print(str.concat("base → home                      → ", outcome_str(skills.move_base(base, home, 0.4))))
        },
      }
    },
  }
}
