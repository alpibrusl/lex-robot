# lex-robot/sense.lex — the sensing half of the skill surface. [net, sense] ONLY.
#
# Split from skills.lex so a sensing-only program (a perception monitor, the
# voice-goal demo) can import cameras/mic/odometry WITHOUT inheriting the
# [actuate] module surface — `lex run --allow-effects net,sense,io` then admits
# it, and the absence of actuate authority is visible in the effect row, not
# just in the grant. skills.lex re-exports these under their existing names,
# so actuating programs keep importing one module.
#
# The microphone is the most privacy-sensitive sensor on the robot, so listen()
# is explicitly grant-gated (like record_episode): "can this program hear the
# room?" is a typed, auditable, refusable question. Raw audio never crosses
# into Lex — the sidecar transcribes locally and only the transcript returns.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "./types" as t

import "./grant" as grant

import "./client" as client

# ── tiny JSON field helpers (shared with skills.lex via re-export) ───────────
fn nth1(xs :: List[Str]) -> Str {
  match list.head(list.tail(xs)) {
    Some(v) => v,
    None => "",
  }
}

fn head_or(xs :: List[Str], dflt :: Str) -> Str {
  match list.head(xs) { Some(v) => v, None => dflt }
}

# Extract a numeric field from a flat JSON object. key e.g. "\"x\":".
fn jfloat(json :: Str, key :: Str, dflt :: Float) -> Float {
  let seg := nth1(str.split(json, key))
  let tok := head_or(str.split(head_or(str.split(seg, ","), seg), "}"), seg)
  match str.to_float(str.trim(tok)) {
    Some(v) => v,
    None => dflt,
  }
}

# ── sensing skills ────────────────────────────────────────────────────────────
fn read_joints(r :: t.Robot) -> [net, sense] Result[Str, Str] {
  client.call(r.sidecar_url, "read_joints", "{}")
}

fn read_camera(r :: t.Robot, name :: Str) -> [net, sense] Result[Str, Str] {
  client.call(r.sidecar_url, "read_camera", str.join(["{\"name\":\"", name, "\"}"], ""))
}

# Capture audio from the robot's microphone and return the sidecar's
# transcription JSON ({"transcript": "...", "confidence": ...}). Grant-gated:
# a program whose grant does not name "listen" is refused at the capability
# layer — the request is never sent.
fn listen(r :: t.Robot, seconds :: Int) -> [net, sense] Result[Str, Str] {
  if grant.skill_allowed(r.grant, "listen") {
    client.call(r.sidecar_url, "listen", str.join(["{\"seconds\":", int.to_str(seconds), "}"], ""))
  } else {
    Err("skill listen not in grant")
  }
}

# Read the base's current floor pose. A response without an "x" field (e.g.
# {"error":"unknown skill"} from the wrong sidecar on the shared port) is an
# Err — never silently decoded as a pose at the origin, because this reading
# may be recorded into a verified trail.
fn read_base(r :: t.Robot) -> [net, sense] Result[t.Vec3, Str] {
  match client.call(r.sidecar_url, "read_base", "{}") {
    Err(e) => Err(e),
    Ok(s) => {
      if str.contains(s, "\"error\"") {
        Err(str.concat("read_base: ", s))
      } else {
        if str.contains(s, "\"x\"") {
          Ok({ x: jfloat(s, "\"x\":", 0.0), y: jfloat(s, "\"y\":", 0.0), z: 0.0 })
        } else {
          Err(str.concat("read_base: no pose in response: ", s))
        }
      }
    },
  }
}
