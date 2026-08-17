# vision_pose_demo — Tier-2 split-compute vision: a 2D detection box becomes
# a WORLD position the arm can actually reach for.
#
# The split (deploy/VISION_SPLIT.md): the sidecar captures the head-camera
# frame ON the robot; the vision service (Pi→Mac in a real deployment, mock
# mode here) judges it and returns a normalized 2D box. What was missing —
# the reason detect_object deliberately returned image coordinates — is the
# geometry that turns a box into a position. src/camera.lex supplies it:
# intersect the pixel ray with the calibrated table plane. Pure,
# examples-tested, refuses instead of guessing.
#
# The acts:
#   1. detect_object_pose: box (0.62, 0.55) from the mock service + the
#      overhead head camera at (0.25, 0, 0.6) over the table plane z=0 →
#      world (322, 30, 0) mm.
#   2. The position is consumable: transform_to_arm picks the nearest arm
#      and move_arm (grant-gated) reaches it.
#   3. The confidence floor: demanding more confidence than the detection
#      carries yields a refusal — NO position exists to act on.
#
# Run it:  bash scripts/demo.sh vision_pose

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "../src/types" as t

import "../src/camera" as camera

import "../src/sense" as sense

import "../src/skills" as sk

# The reacher's envelope: right-arm reach box around the table, gentle caps.
fn arm_grant() -> t.Grant {
  { skills: ["move_arm"], ws_min: { x: 0.0, y: -0.6, z: 0.0 }, ws_max: { x: 0.7, y: 0.6, z: 0.6 }, max_velocity: 0.5, max_force: 20.0, max_grip_force: 15.0, budget_actions: 10, budget_wall_ms: 60000 }
}

# Calibration for the demo rig: head camera mounted straight down at
# (0.25, 0, 0.6) over the table plane z = 0. Real rigs measure these once.
fn head_cam() -> camera.CameraModel {
  camera.overhead_camera({ x: 0.25, y: 0.0, z: 0.6 })
}

fn table_z() -> Float {
  0.0
}

fn mm(p :: t.Vec3) -> Str {
  let m := camera.vec_mm(p)
  str.join(["x=", int.to_str(m.x_mm), "mm y=", int.to_str(m.y_mm), "mm z=", int.to_str(m.z_mm), "mm"], "")
}

fn run() -> [net, sense, actuate, io] Unit {
  let r := { sidecar_url: "http://localhost:8900", grant: arm_grant() }
  let __h := io.print("── Tier-2 vision: a 2D box becomes a reachable world position ──")
  let __a1 := io.print("[act 1] detect + project onto the calibrated table plane:")
  match sense.detect_object_pose(r, "cup", head_cam(), table_z(), 0.9) {
    Err(e) => io.print(str.concat("  pose failed: ", e)),
    Ok(world) => {
      let __p := io.print(str.join(["  cup at world ", mm(world), " (2D box + calibrated plane — no depth sensor)"], ""))
      let __a2 := io.print("[act 2] the position is consumable — reach for it:")
      let __r2 := match sense.transform_to_arm(r, world) {
        Err(e) => io.print(str.concat("  transform failed: ", e)),
        Ok(loc) => match sk.move_arm(r, loc.arm, { pos: { x: world.x, y: world.y, z: world.z + 0.05 }, rx: 0.0, ry: 0.0, rz: 0.0 }) {
          Reached => io.print(str.join(["  approach: move_arm ", loc.arm, " → reached (5 cm above the cup)"], "")),
          Denied(d) => io.print(str.concat("  approach denied: ", d)),
          Stalled(s) => io.print(str.concat("  approach stalled: ", s)),
          Killed(k) => io.print(str.concat("  approach killed: ", k)),
          Timeout => io.print("  approach timed out"),
        },
      }
      ()
    },
  }
  let __a3 := io.print("[act 3] the confidence floor is a refusal, not a guess:")
  match sense.detect_object_pose(r, "cup", head_cam(), table_z(), 0.995) {
    Err(e) => io.print(str.concat("  ", e)),
    Ok(p) => io.print(str.concat("  got a position despite the floor — THIS MUST NOT HAPPEN: ", mm(p))),
  }
}

