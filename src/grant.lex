# lex-robot/grant.lex — capability checks. Pure: no effects, no I/O.
# Every actuating skill runs these before issuing a command.

import "std.list" as list

import "std.str" as str

import "std.float" as flt

import "./types" as t

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

fn in_workspace(g :: t.Grant, p :: t.Vec3) -> Bool {
  if p.x < g.ws_min.x {
    false
  } else {
    if p.x > g.ws_max.x {
      false
    } else {
      if p.y < g.ws_min.y {
        false
      } else {
        if p.y > g.ws_max.y {
          false
        } else {
          if p.z < g.ws_min.z {
            false
          } else {
            if p.z > g.ws_max.z {
              false
            } else {
              true
            }
          }
        }
      }
    }
  }
}

# Clamp a requested force/velocity to the granted ceiling (never amplifies).
fn clamp_force(g :: t.Grant, f :: Float) -> Float {
  if f > g.max_force {
    g.max_force
  } else {
    f
  }
}

fn clamp_grip(g :: t.Grant, f :: Float) -> Float {
  if f > g.max_grip_force {
    g.max_grip_force
  } else {
    f
  }
}

fn clamp_velocity(g :: t.Grant, v :: Float) -> Float {
  if v > g.max_velocity {
    g.max_velocity
  } else {
    v
  }
}

# ── Keep-out / fire zone checks ───────────────────────────────────────────────
# 2-D axis-aligned box in x/y (used for keep-out zones where z is irrelevant).
# Kept separate from the Grant record so it can be attached per-task without
# changing every grant literal.
fn in_box(p :: t.Vec3, lo :: t.Vec3, hi :: t.Vec3) -> Bool {
  if p.x < lo.x {
    false
  } else {
    if p.x > hi.x {
      false
    } else {
      if p.y < lo.y {
        false
      } else {
        if p.y > hi.y {
          false
        } else {
          true
        }
      }
    }
  }
}

# 3-D axis-aligned box (all three axes). Used for volumetric constraints such
# as a tool firing zone where z matters (e.g. mid-air vs. on the workpiece).
fn in_box_3d(p :: t.Vec3, lo :: t.Vec3, hi :: t.Vec3) -> Bool {
  if p.x < lo.x {
    false
  } else {
    if p.x > hi.x {
      false
    } else {
      if p.y < lo.y {
        false
      } else {
        if p.y > hi.y {
          false
        } else {
          if p.z < lo.z {
            false
          } else {
            if p.z > hi.z {
              false
            } else {
              true
            }
          }
        }
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

