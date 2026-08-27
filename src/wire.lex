# lex-robot/wire.lex — the referee wire contract, in one place. Pure: no effects.
#
# Structured SkillOutcome payloads (the lex-os SkillOutcome shape) in INTEGER
# milli-units on the wire: metres→mm, newtons→mN. This is what the lex-games
# `robot_task` referee re-checks for grant legality — its strict vocabulary:
# a move_to / move_base must land inside ws_min..ws_max, a grasp must stay
# under max_grip, and an unknown skill name claiming success is refused.
# Keeping the wire integral avoids whole-valued floats serializing without a
# decimal (and decoding back as Int). Grant force caps should be ISO/TS
# 15066-derived in production.
#
# Shared by src/task.lex (the sql-effectful task graph), src/mcp_server.lex,
# and the game examples (examples/xlerobot_task.lex) — pure, so importing it
# adds no effect surface.

import "std.str"   as str
import "std.int"   as int
import "std.float" as flt
import "std.list"  as list

import "./types" as t

fn outcome_str(o :: t.Outcome) -> Str {
  match o {
    Reached => "reached",
    Stalled(m) => str.concat("stalled: ", m),
    Denied(m) => str.concat("denied: ", m),
    Killed(m) => str.concat("killed: ", m),
    Timeout => "timeout",
  }
}

fn is_reached(o :: t.Outcome) -> Bool {
  match o {
    Reached => true,
    _ => false,
  }
}

# Sanitize a detail string into a JSON payload (drops quotes/newlines).
fn payload(detail :: Str) -> Str {
  let clean := str.replace(str.replace(detail, "\"", "'"), "\n", " ")
  str.join(["{\"detail\":\"", clean, "\"}"], "")
}

fn milli(x :: Float) -> Str { int.to_str(flt.to_int(x * 1000.0)) }

# ── Limit names, spelled for the wire ────────────────────────────────────────
# Every ceiling that can bite has a name a client may branch on, and the names
# are literals here rather than derived from a Lex variant — microduck's rule
# (`robotd-design.md` §3.2): renaming a variant must not silently break a
# consumer reading `limited_by`. One spelling, in the file that owns the wire.
fn limit_max_force() -> Str { "max_force" }
fn limit_max_grip_force() -> Str { "max_grip_force" }
fn limit_max_velocity() -> Str { "max_velocity" }
fn limit_workspace() -> Str { "workspace" }
fn limit_not_finite() -> Str { "not_finite" }

# A JSON array of limit names. ALWAYS emitted, empty when nothing bit: a
# consistently-shaped array is cheaper for a verifier to read than a key that
# is sometimes absent.
fn limits_json(limits :: List[Str]) -> Str
  examples {
    limits_json([]) => "[]",
    limits_json(["max_force"]) => "[\"max_force\"]",
    limits_json(["not_finite", "max_grip_force"]) => "[\"not_finite\",\"max_grip_force\"]"
  }
{
  str.join(["[", str.join(list.map(limits, fn (l :: Str) -> Str { str.join(["\"", l, "\""], "") }), ","), "]"], "")
}

# `milli`, but NaN/inf-safe: a non-finite request encodes as JSON `null`.
# It cannot go through `milli` — `flt.to_int(NaN * 1000.0)` invents an integer
# nobody asked for, and putting `NaN` on the wire is not valid JSON for a
# strict reader. `null` alongside `"limited_by":["not_finite"]` says exactly
# what happened.
fn milli_safe(x :: Float) -> Str
  examples {
    milli_safe(0.015) => "15",
    milli_safe(0.0 / 0.0) => "null",
    milli_safe(1.0 / 0.0) => "null"
  }
{
  if x == x {
    if x > 1.0e308 {
      "null"
    } else {
      if x < -1.0e308 { "null" } else { milli(x) }
    }
  } else {
    "null"
  }
}

fn grant_json(g :: t.Grant) -> Str {
  str.join([
    "\"grant\":{\"ws_min\":{\"x\":", milli(g.ws_min.x), ",\"y\":", milli(g.ws_min.y), ",\"z\":", milli(g.ws_min.z),
    "},\"ws_max\":{\"x\":", milli(g.ws_max.x), ",\"y\":", milli(g.ws_max.y), ",\"z\":", milli(g.ws_max.z),
    "},\"max_force\":", milli(g.max_force), ",\"max_grip\":", milli(g.max_grip_force), "}"
  ], "")
}

# A structured execute payload: the actuation + the grant it ran under + the
# outcome, so a verifier can re-derive that it respected its authority.
#
# `args.force` is what actually LEFT THE BOX (the clamped value) — unchanged,
# and still what the referee re-checks against `max_grip`. What is new is the
# evidence beside it: `requested.force` and `limited_by`. Without those a
# replayer sees 15 N and cannot tell "asked for 15" from "asked for 20 and was
# held to 15" — and the second is the one the audit exists to prove.
fn skill_payload_clamped(skill :: Str, g :: t.Grant, x :: Float, y :: Float, z :: Float, c :: t.Clamp, o :: t.Outcome) -> Str {
  let oc := str.replace(outcome_str(o), "\"", "'")
  str.join([
    "{\"skill\":\"", skill, "\",\"args\":{\"x\":", milli_safe(x), ",\"y\":", milli_safe(y),
    ",\"z\":", milli_safe(z), ",\"force\":", milli_safe(c.applied), "},",
    "\"requested\":{\"force\":", milli_safe(c.requested), "},",
    "\"limited_by\":", limits_json(c.limits), ",", grant_json(g),
    ",\"outcome\":\"", oc, "\"}"
  ], "")
}

# The pre-Clamp signature, kept so every existing caller reads unchanged: a
# force nothing bit, reported as such.
fn skill_payload_for(skill :: Str, g :: t.Grant, x :: Float, y :: Float, z :: Float, force :: Float, o :: t.Outcome) -> Str {
  skill_payload_clamped(skill, g, x, y, z, { requested: force, applied: force, limits: [], ok: true }, o)
}
