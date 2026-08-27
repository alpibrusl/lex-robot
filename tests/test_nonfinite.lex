# lex-robot/tests/test_nonfinite.lex — the grant refuses non-finite values.
#
# The regression this locks down (#193). Every bound in grant.lex used to be a
# chain of POSITIVE rejections (`if p.x < lo { false } else ...`), and for NaN
# *both* `<` and `>` are false — so a NaN fell through every one of them into
# the permissive branch. Measured against lex 0.10.11 before the fix:
#
#     in_workspace(NaN pose)  : true      ← the grant admitted it
#     clamp_force(NaN)        : NaN       ← and passed it to the wire
#     clamp_grip(NaN)         : NaN
#     clamp_velocity(NaN)     : NaN
#     in_box_3d(NaN)          : true
#
# `flt.to_str(NaN)` is "NaN", which the hand-built JSON in skills.lex puts on
# the wire verbatim and Python's `json.loads` accepts — so on the sidecar side
# `force > HARD_GRIP_N` was false (skipping the firmware floor) and
# `min(nan, granted_max)` returned `granted_max`: a NaN grip request silently
# became the MAXIMUM granted force.
#
# The rule is microduck's, from duck-control/src/safety.rs: a non-finite target
# "is not clamped, it is refused outright" — clamping NaN produces a plausible-
# looking boundary value, so the robot commits to a limit instead of declining
# to move.
#
# Panics (1/0) on any failure; exits 0 when every assertion holds — the same
# shape as tests/test_mcp_grant.lex, and how scripts/smoke.sh drives it.
#
# Run:
#   lex run --allow-effects io tests/test_nonfinite.lex main

import "std.io" as io

import "std.list" as list

import "std.str" as str

import "std.int" as ints

import "../src/types" as t

import "../src/grant" as grant

import "../src/wire" as wire

# Lex has no NaN literal; 0.0/0.0 produces one (no trap) and 1.0/0.0 an
# infinity. Both are what a bad division upstream — a vision ray-cast, a
# transform against a zero-length vector, an LLM-supplied number — actually
# yields in practice.
fn nan() -> Float { 0.0 / 0.0 }
fn inf() -> Float { 1.0 / 0.0 }
fn neg_inf() -> Float { 0.0 - 1.0 / 0.0 }

fn g() -> t.Grant {
  { skills: ["move_to", "grasp", "move_base"],
    ws_min: { x: 0.05, y: 0.0, z: 0.0 }, ws_max: { x: 0.45, y: 0.35, z: 0.5 },
    max_velocity: 0.25, max_force: 15.0, max_grip_force: 20.0,
    budget_actions: 200, budget_wall_ms: 120000 }
}

fn check(label :: Str, ok :: Bool) -> Result[Unit, Str] {
  if ok {
    Ok(())
  } else {
    Err(label)
  }
}

# ── The envelope admits no non-finite point ─────────────────────────────────
fn test_workspace_refuses_non_finite() -> List[Result[Unit, Str]] {
  [
    check("in_workspace admits a NaN x", not grant.in_workspace(g(), { x: nan(), y: 0.1, z: 0.1 })),
    check("in_workspace admits a NaN y", not grant.in_workspace(g(), { x: 0.1, y: nan(), z: 0.1 })),
    check("in_workspace admits a NaN z", not grant.in_workspace(g(), { x: 0.1, y: 0.1, z: nan() })),
    check("in_workspace admits +inf", not grant.in_workspace(g(), { x: inf(), y: 0.1, z: 0.1 })),
    check("in_workspace admits -inf", not grant.in_workspace(g(), { x: neg_inf(), y: 0.1, z: 0.1 })),
    # And the guard must not have disabled the envelope it guards.
    check("in_workspace rejects a legal point", grant.in_workspace(g(), { x: 0.2, y: 0.1, z: 0.1 })),
    check("in_workspace admits an out-of-box point", not grant.in_workspace(g(), { x: 9.0, y: 0.1, z: 0.1 }))
  ]
}

fn test_boxes_refuse_non_finite() -> List[Result[Unit, Str]] {
  [
    check("in_box admits NaN", not grant.in_box({ x: nan(), y: 0.5, z: 0.0 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 })),
    check("in_box_3d admits NaN", not grant.in_box_3d({ x: 0.5, y: 0.5, z: nan() }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 })),
    check("in_box rejects a contained point", grant.in_box({ x: 0.5, y: 0.5, z: 0.0 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 })),
    check("in_box_3d rejects a contained point", grant.in_box_3d({ x: 0.5, y: 0.5, z: 0.5 }, { x: 0.0, y: 0.0, z: 0.0 }, { x: 1.0, y: 1.0, z: 1.0 }))
  ]
}

fn test_finiteness_predicates() -> List[Result[Unit, Str]] {
  [
    check("is_finite(NaN)", not grant.is_finite(nan())),
    check("is_finite(+inf)", not grant.is_finite(inf())),
    check("is_finite(-inf)", not grant.is_finite(neg_inf())),
    check("is_finite(0.0)", grant.is_finite(0.0)),
    check("is_finite(-3.5)", grant.is_finite(0.0 - 3.5)),
    check("vec_finite catches a NaN component", not grant.vec_finite({ x: 0.1, y: nan(), z: 0.2 })),
    check("vec_finite passes a finite vec", grant.vec_finite({ x: 0.1, y: 0.2, z: 0.3 })),
    # A NaN orientation reaches the arm just as surely as a NaN position.
    check("pose_finite catches a NaN ry", not grant.pose_finite({ pos: { x: 0.1, y: 0.2, z: 0.3 }, rx: 0.0, ry: nan(), rz: 0.0 })),
    check("pose_finite passes a finite pose", grant.pose_finite({ pos: { x: 0.1, y: 0.2, z: 0.3 }, rx: 0.0, ry: 0.0, rz: 0.0 }))
  ]
}

# ── Refused, not clamped ────────────────────────────────────────────────────
# `ok: false` is the refusal, and `applied: 0.0` is what a caller that ignores
# it gets — the harmless value for all three (no force, no grip, no motion),
# never the boundary value a naive clamp would have invented.
fn test_clamps_refuse_non_finite() -> List[Result[Unit, Str]] {
  let f_nan := grant.clamp_force_checked(g(), nan())
  let grip_nan := grant.clamp_grip_checked(g(), nan())
  let v_nan := grant.clamp_velocity_checked(g(), nan())
  let grip_inf := grant.clamp_grip_checked(g(), inf())
  [
    check("clamp_force_checked(NaN) reports ok", not f_nan.ok),
    check("clamp_force_checked(NaN) applied is not 0", f_nan.applied == 0.0),
    check("clamp_force_checked(NaN) names the limit", list.len(f_nan.limits) == 1),
    check("clamp_grip_checked(NaN) reports ok", not grip_nan.ok),
    check("clamp_grip_checked(NaN) applied is not 0", grip_nan.applied == 0.0),
    check("clamp_velocity_checked(NaN) reports ok", not v_nan.ok),
    check("clamp_velocity_checked(NaN) applied is not 0", v_nan.applied == 0.0),
    check("clamp_grip_checked(+inf) reports ok", not grip_inf.ok),
    # The legacy signatures are safe too: a caller that never learned about
    # `_checked` gets 0.0 rather than NaN on the wire.
    check("clamp_force(NaN) passes NaN through", grant.clamp_force(g(), nan()) == 0.0),
    check("clamp_grip(NaN) passes NaN through", grant.clamp_grip(g(), nan()) == 0.0),
    check("clamp_velocity(NaN) passes NaN through", grant.clamp_velocity(g(), nan()) == 0.0)
  ]
}

# ── A clamp that bites says so (#194) ───────────────────────────────────────
fn test_clamps_report_what_bit() -> List[Result[Unit, Str]] {
  let over := grant.clamp_grip_checked(g(), 99.0)
  let under := grant.clamp_grip_checked(g(), 3.0)
  let fast := grant.clamp_velocity_checked(g(), 2.0)
  [
    check("an over-ceiling grip is not held to the ceiling", over.applied == 20.0),
    check("an over-ceiling grip forgets what was requested", over.requested == 99.0),
    check("an over-ceiling grip does not name its limit", wire.limits_json(over.limits) == "[\"max_grip_force\"]"),
    check("an in-bounds grip is altered", under.applied == 3.0),
    check("an in-bounds grip claims a limit", wire.limits_json(under.limits) == "[]"),
    check("an over-ceiling speed is not held to the ceiling", fast.applied == 0.25),
    check("an over-ceiling speed does not name its limit", wire.limits_json(fast.limits) == "[\"max_velocity\"]")
  ]
}

# A non-finite number must never reach the integer wire encoder: `milli` would
# invent an integer for it, and "NaN" is not valid JSON for a strict reader.
fn test_wire_encodes_non_finite_as_null() -> List[Result[Unit, Str]] {
  [
    check("milli_safe(NaN) is not null", wire.milli_safe(nan()) == "null"),
    check("milli_safe(+inf) is not null", wire.milli_safe(inf()) == "null"),
    check("milli_safe(-inf) is not null", wire.milli_safe(neg_inf()) == "null"),
    check("milli_safe mangles an ordinary value", wire.milli_safe(0.015) == "15")
  ]
}

fn main() -> [io] Unit {
  let results := list.concat(
    list.concat(
      list.concat(test_workspace_refuses_non_finite(), test_boxes_refuse_non_finite()),
      list.concat(test_finiteness_predicates(), test_clamps_refuse_non_finite())),
    list.concat(test_clamps_report_what_bit(), test_wire_encodes_non_finite_as_null()))

  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(label) => list.concat(acc, [label]),
    }
  })

  let _ := io.print(str.join([int_str(list.len(results)), " assertions, ", int_str(list.len(failures)), " failed"], ""))
  let _ := io.print(str.join(failures, "\n  FAIL: "))

  if list.len(failures) == 0 {
    ()
  } else {
    let _ := 1 / 0
    ()
  }
}

fn int_str(n :: Int) -> Str { ints.to_str(n) }
