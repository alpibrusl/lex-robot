# lex-robot/grant.lex — capability checks. Pure: no effects, no I/O.
# Every actuating skill runs these before issuing a command.

import "std.list" as list

import "./types" as t

fn skill_allowed(g :: t.Grant, skill :: Str) -> Bool {
  list.fold(g.skills, false, fn (acc :: Bool, s :: Str) -> Bool {
    if acc { true } else { s == skill }
  })
}

fn in_workspace(g :: t.Grant, p :: t.Vec3) -> Bool {
  if p.x < g.ws_min.x { false } else {
    if p.x > g.ws_max.x { false } else {
      if p.y < g.ws_min.y { false } else {
        if p.y > g.ws_max.y { false } else {
          if p.z < g.ws_min.z { false } else {
            if p.z > g.ws_max.z { false } else { true }
          }
        }
      }
    }
  }
}

# Clamp a requested force/velocity to the granted ceiling (never amplifies).
fn clamp_force(g :: t.Grant, f :: Float) -> Float {
  if f > g.max_force { g.max_force } else { f }
}

fn clamp_grip(g :: t.Grant, f :: Float) -> Float {
  if f > g.max_grip_force { g.max_grip_force } else { f }
}

fn clamp_velocity(g :: t.Grant, v :: Float) -> Float {
  if v > g.max_velocity { g.max_velocity } else { v }
}

# ── Keep-out zone (a "bystander"/fragile region the robot must not enter) ─────
# Expressed as an axis-aligned box in x/y. Kept separate from the Grant record
# so it can be attached per-task without changing every grant literal.
fn in_box(p :: t.Vec3, lo :: t.Vec3, hi :: t.Vec3) -> Bool {
  if p.x < lo.x { false } else {
    if p.x > hi.x { false } else {
      if p.y < lo.y { false } else {
        if p.y > hi.y { false } else { true }
      }
    }
  }
}

# Project a point to the nearest edge OUTSIDE the box (push out along the
# smaller overshoot axis). Assumes p is inside the box.
fn project_out_box(p :: t.Vec3, lo :: t.Vec3, hi :: t.Vec3) -> t.Vec3 {
  let dx_lo := p.x - lo.x
  let dx_hi := hi.x - p.x
  let dy_lo := p.y - lo.y
  let dy_hi := hi.y - p.y
  # nearest of the four faces
  let mx := if dx_lo < dx_hi { dx_lo } else { dx_hi }
  let my := if dy_lo < dy_hi { dy_lo } else { dy_hi }
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
