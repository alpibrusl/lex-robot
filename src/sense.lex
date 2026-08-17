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

import "std.float" as flt

import "std.list" as list

import "./types" as t

import "./grant" as grant

import "./client" as client

import "./camera" as camera

# ── tiny JSON field helpers (shared with skills.lex via re-export) ───────────
fn nth1(xs :: List[Str]) -> Str {
  match list.head(list.tail(xs)) {
    Some(v) => v,
    None => "",
  }
}

fn head_or(xs :: List[Str], dflt :: Str) -> Str {
  match list.head(xs) {
    Some(v) => v,
    None => dflt,
  }
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

# Unlike a2a_card.lex's jstr (which expects LEX-authored, unspaced JSON and
# folds the value's opening quote into `key` itself), this JSON comes from
# the Python sidecar's `json.dumps`, which puts a space after every colon
# ("\"arm\": \"left\"") — so `key` here is colon-only (e.g. "\"arm\":") and
# the segment is trimmed before splitting on the quote, landing the value at
# index 1 (index 0 is the empty text before that now-leading quote).
fn jstr(json :: Str, key :: Str, dflt :: Str) -> Str {
  let seg := str.trim(nth1(str.split(json, key)))
  let tok := nth1(str.split(seg, "\""))
  if str.is_empty(tok) {
    dflt
  } else {
    tok
  }
}

# Isolate a flat nested-object field's raw text (e.g. the {"x":..,"y":..}
# value at "world":) so jfloat/jstr can be applied within just that object —
# `locate_object`'s response nests two same-shaped {x,y,z} records ("world"
# and "arm_frame"), so a plain top-level jfloat("\"x\":") would always find
# the FIRST one. Assumes no nested braces inside the field (true here).
fn jobj(json :: Str, key :: Str) -> Str {
  let seg := nth1(str.split(json, key))
  head_or(str.split(seg, "}"), seg)
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

# Read the one unread tap from the robot's touchscreen prompt and return the
# sidecar's JSON ({"option": "...", "detail"?}) — "" for option means no tap
# (or no prompt showing). The touch layer is an input sensor exactly like the
# mic: what a person tapped is something the program SENSES, so it is
# grant-gated the same way listen is — a program whose grant does not name
# "read_touch" can show a prompt (if granted show_prompt) but never learn the
# answer; the request is never sent.
fn read_touch(r :: t.Robot) -> [net, sense] Result[Str, Str] {
  if grant.skill_allowed(r.grant, "read_touch") {
    client.call(r.sidecar_url, "read_touch", "{}")
  } else {
    Err("skill read_touch not in grant")
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

# Find a named object via the sidecar's vision (Tier-2 MuJoCo: genuine
# color-threshold detection + ray-cast against the rendered camera image;
# Tier-1: an explicitly-labeled canned lookup so the demo runs with no
# physics dependency; Tier-3 real hardware: not yet implemented, returns
# Err). Sensing-only, no grant check — matching read_camera/read_joints:
# locate_object never moves anything, so it carries no authority to gate.
# The caller's own move_arm/move_base calls (see find_and_fetch_demo.lex)
# are what the grant actually checks.
fn locate_object(r :: t.Robot, name :: Str) -> [net, sense] Result[t.Located, Str] {
  match client.call(r.sidecar_url, "locate_object", str.join(["{\"name\":\"", name, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(s) => {
      if str.contains(s, "\"found\"") {
        let w := jobj(s, "\"world\":")
        let af := jobj(s, "\"arm_frame\":")
        Ok({ arm: jstr(af, "\"arm\":", "left"), world: { x: jfloat(w, "\"x\":", 0.0), y: jfloat(w, "\"y\":", 0.0), z: jfloat(w, "\"z\":", 0.0) }, offset: { x: jfloat(af, "\"x\":", 0.0), y: jfloat(af, "\"y\":", 0.0), z: jfloat(af, "\"z\":", 0.0) } })
      } else {
        Err(str.concat("locate_object: ", s))
      }
    },
  }
}

# 2D object detection via the split-compute vision service (the sidecar
# captures a head-camera frame on the robot, ships the already-captured JPEG
# to the service named by LEX_XLE_VISION_URL, and passes the normalized
# bounding box back — deploy/VISION_SPLIT.md). Returns the sidecar's raw
# JSON ({"found": bool, "cx","cy","w","h", "confidence", "detail"}) —
# deliberately 2D image coordinates, not a world pose: turning a box into a
# position needs depth or calibration. The calibrated-plane answer is
# detect_object_pose below (Tier-2, src/camera.lex); full per-pixel depth
# stays Tier-3 and open. Sensing-only, no grant check — same reasoning as
# locate_object: detection never moves anything.
fn detect_object(r :: t.Robot, name :: Str) -> [net, sense] Result[Str, Str] {
  client.call(r.sidecar_url, "detect_object", str.join(["{\"name\":\"", name, "\"}"], ""))
}

# Tier-2 vision: detect via the split-compute vision service, then turn the
# 2D box into a WORLD position by intersecting the pixel ray with the
# calibrated table plane (src/camera.lex). Two refusals instead of guesses:
# a detection below `min_confidence` yields NO position, and a ray that
# misses the plane (parallel / behind) is a geometry error, not (0,0,0).
# Only valid for objects standing on the calibrated plane — that is the
# Tier-2 deal, stated in camera.lex's module header.
fn detect_object_pose(r :: t.Robot, name :: Str, cam :: camera.CameraModel, plane_z :: Float, min_confidence :: Float) -> [net, sense] Result[t.Vec3, Str] {
  match detect_object(r, name) {
    Err(e) => Err(e),
    Ok(s) => {
      if str.contains(str.replace(s, " ", ""), "\"found\":true") {
        let conf := jfloat(s, "\"confidence\":", 0.0)
        if conf >= min_confidence {
          camera.project_to_plane(cam, jfloat(s, "\"cx\":", 0.5), jfloat(s, "\"cy\":", 0.5), plane_z)
        } else {
          Err(str.join(["detect_object_pose: confidence ", flt.to_str(conf), " below the ", flt.to_str(min_confidence), " floor — refusing to guess a position"], ""))
        }
      } else {
        Err(str.concat("detect_object_pose: not found: ", s))
      }
    },
  }
}

# Re-project a world position (e.g. from an earlier locate_object call) into
# whichever arm's frame is nearest, using the base's CURRENT pose. Needed
# because the base moving after locate_object invalidates that earlier call's
# arm_frame offset — the world position is still valid, but the base-relative
# offset to reach it is not. Sensing-only, no grant check (same reasoning as
# locate_object: it never moves anything).
fn transform_to_arm(r :: t.Robot, world :: t.Vec3) -> [net, sense] Result[t.Located, Str] {
  let body := str.join(["{\"x\":", flt.to_str(world.x), ",\"y\":", flt.to_str(world.y), ",\"z\":", flt.to_str(world.z), "}"], "")
  match client.call(r.sidecar_url, "transform_to_arm", body) {
    Err(e) => Err(e),
    Ok(s) => {
      if str.contains(s, "\"found\"") {
        let af := jobj(s, "\"arm_frame\":")
        Ok({ arm: jstr(af, "\"arm\":", "left"), world: world, offset: { x: jfloat(af, "\"x\":", 0.0), y: jfloat(af, "\"y\":", 0.0), z: jfloat(af, "\"z\":", 0.0) } })
      } else {
        Err(str.concat("transform_to_arm: ", s))
      }
    },
  }
}

