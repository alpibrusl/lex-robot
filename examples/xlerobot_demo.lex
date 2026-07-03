# lex-robot/examples/xlerobot_demo.lex — governance for a dual-arm mobile robot.
#
# The XLeRobot 0.4.0 (two SO-101 arms on a dual-wheel differential base) has TWO
# envelopes, so this demo carries TWO grants against one sidecar:
#   • base grant — the permitted floor area (a room-scale box) + a speed cap
#   • arm grant  — the arms' reach box (≈40 cm SO-101 envelope) + grip cap
# A base command is checked against the floor area; an arm command against the
# reach box; grip force and base speed are clamped, never amplified. The
# sidecar's firmware floors (grip/speed) sit independently behind all of it.
#
# Run (starts sidecar/xlerobot_sidecar.py first — or use `make xlerobot`):
#   lex run --allow-effects net,sense,actuate,io examples/xlerobot_demo.lex run

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

# The base's envelope: a 4m × 3m room, kitchen doorway at x=4 NOT granted.
# max_velocity is the base speed cap (m/s); force/grip fields are unused here.
fn base_grant() -> t.Grant {
  {
    skills: ["move_base", "read_base"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 4.0, y: 3.0, z: 0.0 },
    max_velocity: 0.5,
    max_force: 0.0,
    max_grip_force: 0.0,
    budget_actions: 100,
    budget_wall_ms: 300000,
  }
}

# The arms' envelope: the SO-101 reach box in the robot frame (~40 cm), grip
# capped at 15 N — well under ISO/TS 15066 quasi-static hand/finger limits and
# under the sidecar's 25 N firmware floor (defense in depth).
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

# The mission: fetch the cup from the kitchen counter to the table — with the
# unsafe detours a planner might propose refused along the way. Against the
# MuJoCo sidecar every "reached" below is real physics (the grasp is a weld
# that only takes if the EE is actually at the cup; the carry drags real mass).
fn run() -> [net, sense, actuate, io] Unit {
  let base := { sidecar_url: "http://localhost:8900", grant: base_grant() }
  let arms := { sidecar_url: "http://localhost:8900", grant: arm_grant() }

  # Drive to the counter via a staging point, so the differential base's final
  # approach leg faces the counter (the arm frame follows the cart's nose).
  let staging := { x: 1.0, y: 0.85, z: 0.0 }
  let __0 := io.print(str.concat("base → staging (1.0,0.85)      → ", outcome_str(skills.move_base(base, staging, 0.4))))
  let counter := { x: 2.55, y: 0.85, z: 0.0 }
  let __1 := io.print(str.concat("base → counter (2.55,0.85)     → ", outcome_str(skills.move_base(base, counter, 0.3))))

  # Left arm: reach the cup — inside the reach box, allowed.
  let cup := { pos: { x: 0.35, y: 0.0, z: 0.45 }, rx: 0.0, ry: 0.0, rz: 0.0 }
  let __2 := io.print(str.concat("left arm → cup (0.35,0,0.45)   → ", outcome_str(skills.move_arm(arms, "left", cup))))

  # Over-grip 99 N — clamped to the 15 N grant ceiling, then sent (in MuJoCo
  # the grasp welds only if the EE really is at the cup).
  let __3 := io.print(str.concat("left grasp 99N (clamped→15N)   → ", outcome_str(skills.grasp_arm(arms, "left", 99.0))))

  # Detour 1: through the doorway at x=4.5 — outside the floor area, NEVER SENT.
  let kitchen := { x: 4.5, y: 1.5, z: 0.0 }
  let __4 := io.print(str.concat("base → kitchen (4.5,1.5)       → ", outcome_str(skills.move_base(base, kitchen, 0.3))))

  # Detour 2: right arm reach behind the robot — outside the reach box, NEVER SENT.
  let far := { pos: { x: 0.9, y: 0.0, z: 0.2 }, rx: 0.0, ry: 0.0, rz: 0.0 }
  let __5 := io.print(str.concat("right arm → behind (0.90,0.0)  → ", outcome_str(skills.move_arm(arms, "right", far))))

  # Detour 3: cross-envelope — the ARM grant holds no base authority, so
  # move_base under it is refused at the capability layer, before any
  # workspace math runs.
  let __6 := io.print(str.concat("move_base under ARM grant      → ", outcome_str(skills.move_base(arms, counter, 0.3))))

  # Carry the cup home; a 2.0 m/s sprint request is clamped to the 0.5 grant
  # ceiling (and the sidecar's 1.0 m/s firmware floor sits behind that).
  let table := { x: 1.0, y: 1.5, z: 0.0 }
  let __7 := io.print(str.concat("base → table, 2 m/s (clamped)  → ", outcome_str(skills.move_base(base, table, 2.0))))
  ()
}
