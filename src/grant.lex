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
