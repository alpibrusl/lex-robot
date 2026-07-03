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

fn grant_json(g :: t.Grant) -> Str {
  str.join([
    "\"grant\":{\"ws_min\":{\"x\":", milli(g.ws_min.x), ",\"y\":", milli(g.ws_min.y), ",\"z\":", milli(g.ws_min.z),
    "},\"ws_max\":{\"x\":", milli(g.ws_max.x), ",\"y\":", milli(g.ws_max.y), ",\"z\":", milli(g.ws_max.z),
    "},\"max_force\":", milli(g.max_force), ",\"max_grip\":", milli(g.max_grip_force), "}"
  ], "")
}

# A structured execute payload: the actuation + the grant it ran under + the
# outcome, so a verifier can re-derive that it respected its authority.
fn skill_payload_for(skill :: Str, g :: t.Grant, x :: Float, y :: Float, z :: Float, force :: Float, o :: t.Outcome) -> Str {
  let oc := str.replace(outcome_str(o), "\"", "'")
  str.join([
    "{\"skill\":\"", skill, "\",\"args\":{\"x\":", milli(x), ",\"y\":", milli(y),
    ",\"z\":", milli(z), ",\"force\":", milli(force), "},", grant_json(g),
    ",\"outcome\":\"", oc, "\"}"
  ], "")
}
