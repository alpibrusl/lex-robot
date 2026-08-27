# lex-robot/grant.lex — capability checks. Pure: no effects, no I/O.
# Every actuating skill runs these before issuing a command.

import "std.list" as list

import "std.str" as str

import "std.float" as flt

import "./types" as t

import "./wire" as wire

# ── Finiteness: refused, never clamped ───────────────────────────────────────
# microduck's safety layer states this as an unconditional rule, and it is worth
# restating here: "a NaN target is not clamped, it is refused outright."
# Clamping NaN silently produces a boundary value -- a plausible-looking joint
# angle -- so the robot lurches to a limit instead of declining to move.
#
# The trap this closes was specific to how this file used to be written. Every
# bound was a chain of POSITIVE rejections (`if p.x < lo { false }`), and for
# NaN *both* `<` and `>` are false -- so a NaN fell through every one of them
# into the permissive branch. Verified against lex 0.10.11: before this change
# `in_workspace` returned `true` for a NaN pose and all three clamps returned
# NaN unchanged (#193). The chains are gone; `within` below is the one bound
# test, written so a non-finite value cannot satisfy it.
fn is_finite(v :: Float) -> Bool
  examples {
    is_finite(0.0) => true,
    is_finite(15.0) => true,
    is_finite(-3.5) => true,
    is_finite(0.0 / 0.0) => false,
    is_finite(1.0 / 0.0) => false,
    is_finite(0.0 - 1.0 / 0.0) => false
  }
{
  # Two positive tests, deliberately. NaN is the only value that fails its own
  # equality (IEEE 754); the magnitude bound catches the infinities, which do
  # compare. A negated comparison chain would reintroduce the bug above.
  if v == v {
    if v > 1.0e308 {
      false
    } else {
      if v < -1.0e308 {
        false
      } else {
        true
      }
    }
  } else {
    false
  }
}

fn vec_finite(p :: t.Vec3) -> Bool
  examples {
    vec_finite({ x: 0.1, y: 0.2, z: 0.3 }) => true,
    vec_finite({ x: 0.1, y: 0.0 / 0.0, z: 0.3 }) => false,
    vec_finite({ x: 1.0 / 0.0, y: 0.0, z: 0.0 }) => false
  }
{
  if is_finite(p.x) {
    if is_finite(p.y) {
      is_finite(p.z)
    } else {
      false
    }
  } else {
    false
  }
}

# A pose is finite when its position AND its orientation are: a NaN rx/ry/rz
# reaches the arm just as surely as a NaN x.
fn pose_finite(p :: t.Pose) -> Bool
  examples {
    pose_finite({ pos: { x: 0.1, y: 0.2, z: 0.3 }, rx: 0.0, ry: 0.0, rz: 0.0 }) => true,
    pose_finite({ pos: { x: 0.1, y: 0.2, z: 0.3 }, rx: 0.0, ry: 0.0 / 0.0, rz: 0.0 }) => false,
    pose_finite({ pos: { x: 0.0 / 0.0, y: 0.2, z: 0.3 }, rx: 0.0, ry: 0.0, rz: 0.0 }) => false
  }
{
  if vec_finite(p.pos) {
    if is_finite(p.rx) {
      if is_finite(p.ry) {
        is_finite(p.rz)
      } else {
        false
      }
    } else {
      false
    }
  } else {
    false
  }
}

# The one bound test. `lo <= v` and `v <= hi` are both required, so a NaN --
# which satisfies neither -- is outside every interval, and so is an infinity
# outside the bounds. This is the same shape the Python sidecar's
# `_grant_workspace_violation` already uses (`not (min <= val <= max)`), which
# is why that layer was NaN-safe while this one was not.
fn within(v :: Float, lo :: Float, hi :: Float) -> Bool
  examples {
    within(0.5, 0.0, 1.0) => true,
    within(0.0, 0.0, 1.0) => true,
    within(1.0, 0.0, 1.0) => true,
    within(-0.1, 0.0, 1.0) => false,
    within(1.1, 0.0, 1.0) => false,
    within(0.0 / 0.0, 0.0, 1.0) => false,
    within(1.0 / 0.0, 0.0, 1.0) => false
  }
{
  if lo <= v {
    v <= hi
  } else {
    false
  }
}

# The granted workspace, rendered for a denial message. A refusal that
# names the envelope TEACHES: an LLM planner (or any A2A caller) that gets
# "outside granted workspace (granted: x 0.05..0.45, ...)" back can replan
# inside the box instead of guessing — see llm_planner.lex's rule 3.
fn ws_str(g :: t.Grant) -> Str
  examples {
    ws_str({ skills: [], ws_min: { x: 0.05, y: 0.0, z: 0.0 }, ws_max: { x: 0.45, y: 0.35, z: 0.5 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 0, budget_wall_ms: 0 }) => "granted: x 0.05..0.45, y 0..0.35, z 0..0.5"
  }
{
  str.join(["granted: x ", flt.to_str(g.ws_min.x), "..", flt.to_str(g.ws_max.x), ", y ", flt.to_str(g.ws_min.y), "..", flt.to_str(g.ws_max.y), ", z ", flt.to_str(g.ws_min.z), "..", flt.to_str(g.ws_max.z)], "")
}

fn skill_allowed(g :: t.Grant, skill :: Str) -> Bool {
  list.fold(g.skills, false, fn (acc :: Bool, s :: Str) -> Bool {
    if acc {
      true
    } else {
      s == skill
    }
  })
}

fn in_workspace(g :: t.Grant, p :: t.Vec3) -> Bool
  examples {
    in_workspace({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 0, budget_wall_ms: 0 }, { x: 0.5, y: 0.5, z: 0.5 }) => true,
    in_workspace({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 0, budget_wall_ms: 0 }, { x: 2.0, y: 0.5, z: 0.5 }) => false,
    in_workspace({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 0, budget_wall_ms: 0 }, { x: 0.0 / 0.0, y: 0.5, z: 0.5 }) => false
  }
{
  if within(p.x, g.ws_min.x, g.ws_max.x) {
    if within(p.y, g.ws_min.y, g.ws_max.y) {
      within(p.z, g.ws_min.z, g.ws_max.z)
    } else {
      false
    }
  } else {
    false
  }
}

# ── Clamps: bounded, and never silent ────────────────────────────────────────
# A clamp lowers a request to the granted ceiling (never amplifies). What is
# new is that it SAYS SO. microduck's state frame carries
# `{requested, applied, limited_by}` for the reason its design note gives: "a
# teleop UI showing the stick forward and the robot still, with no explanation,
# is unusable, and safety clamps things constantly." Here the consumer is the
# lex-trail: a replayer that sees 15 N cannot otherwise tell "asked for 15"
# from "asked for 20 and was held to 15", and the second is the one the audit
# exists to prove (#194).
#
# A NON-FINITE request is REFUSED (`ok: false`), not clamped -- see the
# finiteness note above. `applied` is 0.0 there, which is the harmless value
# for all three of these (no force, no grip, no motion), so a caller that
# ignores `ok` is still safe; callers in skills.lex check it and return Denied.
fn clamp_force_checked(g :: t.Grant, f :: Float) -> t.Clamp
  examples {
    clamp_force_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 10.0) => { requested: 10.0, applied: 10.0, limits: [], ok: true },
    clamp_force_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 25.0) => { requested: 25.0, applied: 15.0, limits: ["max_force"], ok: true },
    clamp_force_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 1.0 / 0.0) => { requested: 1.0 / 0.0, applied: 0.0, limits: ["not_finite"], ok: false }
  }
{
  if is_finite(f) {
    if f > g.max_force {
      { requested: f, applied: g.max_force, limits: [wire.limit_max_force()], ok: true }
    } else {
      { requested: f, applied: f, limits: [], ok: true }
    }
  } else {
    { requested: f, applied: 0.0, limits: [wire.limit_not_finite()], ok: false }
  }
}

fn clamp_grip_checked(g :: t.Grant, f :: Float) -> t.Clamp
  examples {
    clamp_grip_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 5.0) => { requested: 5.0, applied: 5.0, limits: [], ok: true },
    clamp_grip_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 99.0) => { requested: 99.0, applied: 20.0, limits: ["max_grip_force"], ok: true },
    clamp_grip_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 1.0 / 0.0) => { requested: 1.0 / 0.0, applied: 0.0, limits: ["not_finite"], ok: false }
  }
{
  if is_finite(f) {
    if f > g.max_grip_force {
      { requested: f, applied: g.max_grip_force, limits: [wire.limit_max_grip_force()], ok: true }
    } else {
      { requested: f, applied: f, limits: [], ok: true }
    }
  } else {
    { requested: f, applied: 0.0, limits: [wire.limit_not_finite()], ok: false }
  }
}

fn clamp_velocity_checked(g :: t.Grant, v :: Float) -> t.Clamp
  examples {
    clamp_velocity_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 0.1) => { requested: 0.1, applied: 0.1, limits: [], ok: true },
    clamp_velocity_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 2.0) => { requested: 2.0, applied: 0.25, limits: ["max_velocity"], ok: true },
    clamp_velocity_checked({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 1.0 / 0.0) => { requested: 1.0 / 0.0, applied: 0.0, limits: ["not_finite"], ok: false }
  }
{
  if is_finite(v) {
    if v > g.max_velocity {
      { requested: v, applied: g.max_velocity, limits: [wire.limit_max_velocity()], ok: true }
    } else {
      { requested: v, applied: v, limits: [], ok: true }
    }
  } else {
    { requested: v, applied: 0.0, limits: [wire.limit_not_finite()], ok: false }
  }
}

# The pre-Clamp signatures, kept so existing callers read unchanged. They are
# strictly safer than before: a non-finite request now yields 0.0 rather than
# passing NaN through to the wire. A caller that needs to know WHY -- or needs
# to refuse rather than proceed -- uses the `_checked` form above.
fn clamp_force(g :: t.Grant, f :: Float) -> Float
  examples {
    clamp_force({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 25.0) => 15.0,
    clamp_force({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 1.0) => 1.0,
    clamp_force({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 0.0 / 0.0) => 0.0
  }
{
  clamp_force_checked(g, f).applied
}

fn clamp_grip(g :: t.Grant, f :: Float) -> Float
  examples {
    clamp_grip({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 99.0) => 20.0,
    clamp_grip({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 3.0) => 3.0,
    clamp_grip({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 0.0 / 0.0) => 0.0
  }
{
  clamp_grip_checked(g, f).applied
}

fn clamp_velocity(g :: t.Grant, v :: Float) -> Float
  examples {
    clamp_velocity({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 2.0) => 0.25,
    clamp_velocity({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 0.1) => 0.1,
    clamp_velocity({ skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0, budget_actions: 0, budget_wall_ms: 0 }, 0.0 / 0.0) => 0.0
  }
{
  clamp_velocity_checked(g, v).applied
}

# ── Keep-out / fire zone checks ───────────────────────────────────────────────
# 2-D axis-aligned box in x/y (used for keep-out zones where z is irrelevant).
# Kept separate from the Grant record so it can be attached per-task without
# changing every grant literal.
fn in_box(p :: t.Vec3, lo :: t.Vec3, hi :: t.Vec3) -> Bool
  examples {
    in_box({ x: 0.5, y: 0.5, z: 0.0 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 }) => true,
    in_box({ x: 1.5, y: 0.5, z: 0.0 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 }) => false,
    in_box({ x: 0.0 / 0.0, y: 0.5, z: 0.0 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 }) => false
  }
{
  if within(p.x, lo.x, hi.x) {
    within(p.y, lo.y, hi.y)
  } else {
    false
  }
}

# 3-D axis-aligned box (all three axes). Used for volumetric constraints such
# as a tool firing zone where z matters (e.g. mid-air vs. on the workpiece).
fn in_box_3d(p :: t.Vec3, lo :: t.Vec3, hi :: t.Vec3) -> Bool
  examples {
    in_box_3d({ x: 0.5, y: 0.5, z: 0.5 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 }) => true,
    in_box_3d({ x: 0.5, y: 0.5, z: 1.5 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 }) => false,
    in_box_3d({ x: 0.5, y: 0.5, z: 0.0 / 0.0 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 }) => false
  }
{
  if within(p.x, lo.x, hi.x) {
    if within(p.y, lo.y, hi.y) {
      within(p.z, lo.z, hi.z)
    } else {
      false
    }
  } else {
    false
  }
}

# Project a point to the nearest edge OUTSIDE the box (push out along the
# smaller overshoot axis). Assumes p is inside the box.
fn project_out_box(p :: t.Vec3, lo :: t.Vec3, hi :: t.Vec3) -> t.Vec3 {
  let dx_lo := p.x - lo.x
  let dx_hi := hi.x - p.x
  let dy_lo := p.y - lo.y
  let dy_hi := hi.y - p.y
  let mx := if dx_lo < dx_hi {
    dx_lo
  } else {
    dx_hi
  }
  let my := if dy_lo < dy_hi {
    dy_lo
  } else {
    dy_hi
  }
  if mx < my {
    if dx_lo < dx_hi {
      { x: lo.x, y: p.y, z: p.z }
    } else {
      { x: hi.x, y: p.y, z: p.z }
    }
  } else {
    if dy_lo < dy_hi {
      { x: p.x, y: lo.y, z: p.z }
    } else {
      { x: p.x, y: hi.y, z: p.z }
    }
  }
}

