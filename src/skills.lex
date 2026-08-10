# lex-robot/skills.lex — the bounded skill API.
#
# Each actuating skill: (1) checks the grant, (2) clamps to limits, (3) calls
# the sidecar. A call the grant forbids returns Denied(...) and never touches
# the wire. Sensor-only skills (read_*) don't actuate but still hit [net].
#
# Effect rows make the judgment/authority split a TYPE, not a convention
# (DESIGN.md §4):
#   [sense]    reads a sensor — no physical output (read_*, policy_action, ...)
#   [actuate]  drives a physical output — gated by the grant (move_to, grasp, ...)
#   [net]      the transport: each skill is a localhost call to the sidecar.
# Because effects propagate, a caller cannot invoke an actuating skill without
# declaring [actuate] itself — so `lex check` rejects a "look but don't touch"
# routine that secretly moves the arm, and `lex run --allow-effects` (the grant's
# authority) can withhold `actuate` to make actuation unreachable before run.

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.list" as list

import "std.bytes" as bytes

import "std.http" as http

import "std.map" as map

import "lex-schema/json_value" as jv

import "./types" as t

import "./grant" as grant

import "./client" as client

import "./sense" as sense

import "./fleet_client" as fleet

# ── JSON helpers (manual; scaffold avoids a json dep) ────────────────────────
fn f(x :: Float) -> Str {
  flt.to_str(x)
}

fn pose_json(p :: t.Pose) -> Str {
  str.join(["{\"x\":", f(p.pos.x), ",\"y\":", f(p.pos.y), ",\"z\":", f(p.pos.z), ",\"rx\":", f(p.rx), ",\"ry\":", f(p.ry), ",\"rz\":", f(p.rz), "}"], "")
}

# Minimal JSON string escape — every other skill's body only ever encodes
# numbers/enum-like arm names, but `speak`'s text is free-form (may come from
# an LLM planner) and could contain quotes/backslashes/newlines that would
# otherwise break the hand-built JSON body below.
fn json_escape_str(s :: Str) -> Str {
  list.fold(str.split(s, ""), "", fn (acc :: Str, c :: Str) -> Str {
    str.concat(acc, match c {
      "\"" => "\\\"",
      "\\" => "\\\\",
      "\n" => "\\n",
      "\r" => "\\r",
      "\t" => "\\t",
      _ => c,
    })
  })
}

# Minimal outcome parse: the sidecar returns {"outcome":"reached|stalled|timeout", "detail":"..."}.
fn parse_outcome(resp :: Str) -> t.Outcome {
  if str.contains(resp, "\"reached\"") {
    Reached
  } else {
    if str.contains(resp, "\"timeout\"") {
      Timeout
    } else {
      Stalled(resp)
    }
  }
}

# ── Tiny flat-JSON float extractor ───────────────────────────────────────────
# Lives in ./sense (the [net, sense]-only module); a thin delegate keeps the
# local name for this module's parsers.
fn jfloat(json :: Str, key :: Str, dflt :: Float) -> Float {
  sense.jfloat(json, key, dflt)
}

# ── Step-wise control (lets the Lex grant vet each policy command) ───────────
fn reset_episode(r :: t.Robot, name :: Str) -> [net] Result[Str, Str] {
  client.call(r.sidecar_url, "reset_episode", str.join(["{\"name\":\"", name, "\"}"], ""))
}

# The action the policy *wants* (normalized), before any grant check.
fn policy_action(r :: t.Robot) -> [net, sense] Result[t.Vec3, Str] {
  match client.call(r.sidecar_url, "policy_action", "{}") {
    Err(e) => Err(e),
    Ok(s) => Ok({ x: jfloat(s, "\"x\":", 0.5), y: jfloat(s, "\"y\":", 0.5), z: 0.0 }),
  }
}

# Execute a (possibly grant-adjusted) command; returns the resulting reward.
fn apply_action(r :: t.Robot, p :: t.Vec3) -> [net, sense, actuate] Result[Float, Str] {
  let body := str.join(["{\"x\":", flt.to_str(p.x), ",\"y\":", flt.to_str(p.y), "}"], "")
  match client.call(r.sidecar_url, "apply_action", body) {
    Err(e) => Err(e),
    Ok(s) => Ok(jfloat(s, "\"reward\":", 0.0)),
  }
}

# ── Depot / EV-charging skills ───────────────────────────────────────────────
fn reset_depot(r :: t.Robot) -> [net] Result[Str, Str] {
  client.call(r.sidecar_url, "reset_depot", "{}")
}

# Read the truck's charge-inlet pose (Perceive).
fn read_inlet(r :: t.Robot) -> [net, sense] Result[t.Pose, Str] {
  match client.call(r.sidecar_url, "read_inlet", "{}") {
    Err(e) => Err(e),
    Ok(s) => Ok({ pos: { x: jfloat(s, "\"x\":", 0.0), y: jfloat(s, "\"y\":", 0.0), z: jfloat(s, "\"z\":", 0.0) }, rx: jfloat(s, "\"rx\":", 0.0), ry: jfloat(s, "\"ry\":", 0.0), rz: jfloat(s, "\"rz\":", 0.0) }),
  }
}

# Seat the connector. Grant-gated: rejected if not allowed; force clamped to the
# grant ceiling before the command is sent.
fn connect_charger(r :: t.Robot, force :: Float) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "connect_charger") {
    let clamped := grant.clamp_force(r.grant, force)
    match client.call(r.sidecar_url, "connect_charger", str.join(["{\"force\":", f(clamped), "}"], "")) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill connect_charger not in grant")
  }
}

fn disconnect_charger(r :: t.Robot) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "disconnect_charger") {
    match client.call(r.sidecar_url, "disconnect_charger", "{}") {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill disconnect_charger not in grant")
  }
}

# ── Sensing ──────────────────────────────────────────────────────────────────
# The sensing half of the surface lives in ./sense ([net, sense] only), so a
# sensing-only program can import it without inheriting this module's
# [actuate] surface; delegates keep the public names for actuating programs.
fn read_joints(r :: t.Robot) -> [net, sense] Result[Str, Str] {
  sense.read_joints(r)
}

fn read_camera(r :: t.Robot, name :: Str) -> [net, sense] Result[Str, Str] {
  sense.read_camera(r, name)
}

# Current position of the bystander/person in the workspace (normalized [0,1]).
# Used by the dynamic keep-out demo to compute a live exclusion box each step.
fn read_bystander(r :: t.Robot) -> [net, sense] Result[t.Vec3, Str] {
  match client.call(r.sidecar_url, "read_bystander", "{}") {
    Err(e) => Err(e),
    Ok(s) => Ok({ x: jfloat(s, "\"x\":", 0.5), y: jfloat(s, "\"y\":", 0.5), z: 0.0 }),
  }
}

# ── Actuating (grant-gated) ──────────────────────────────────────────────────
fn move_to(r :: t.Robot, target :: t.Pose) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "move_to") {
    if grant.in_workspace(r.grant, target.pos) {
      match client.call(r.sidecar_url, "move_to", pose_json(target)) {
        Err(e) => Stalled(e),
        Ok(resp) => parse_outcome(resp),
      }
    } else {
      Denied("target outside granted workspace")
    }
  } else {
    Denied("skill move_to not in grant")
  }
}

fn grasp(r :: t.Robot, force :: Float) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "grasp") {
    let clamped := grant.clamp_grip(r.grant, force)
    match client.call(r.sidecar_url, "grasp", str.join(["{\"force\":", f(clamped), "}"], "")) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill grasp not in grant")
  }
}

# run_policy + its async polling live in ./policy (policy.lex) so the [time]
# effect they need stays off the core skill surface — a plain move/grasp program
# that imports this module does not inherit `time`.
# Captures a LeRobotDataset episode: reads sensors ([sense]); the file write
# happens in the sidecar (Python), so it is not a Lex [fs_write].
fn record_episode(r :: t.Robot, task :: Str) -> [net, sense] Result[Str, Str] {
  if grant.skill_allowed(r.grant, "record_episode") {
    client.call(r.sidecar_url, "record_episode", str.join(["{\"task\":\"", task, "\"}"], ""))
  } else {
    Err("skill record_episode not in grant")
  }
}

# ── Dangerous-tool skills ─────────────────────────────────────────────────────
# Sense whether a workpiece is present in the jig and physically clamped.
fn workpiece_status(r :: t.Robot) -> [net, sense] Result[t.WorkpieceStatus, Str] {
  match client.call(r.sidecar_url, "workpiece_status", "{}") {
    Err(e) => Err(e),
    Ok(s) => Ok({ present: str.contains(s, "\"present\":true") or str.contains(s, "\"present\": true"), clamped: str.contains(s, "\"clamped\":true") or str.contains(s, "\"clamped\": true") }),
  }
}

# Actuate the clamp that holds the workpiece. Precondition for tool firing.
fn clamp_workpiece(r :: t.Robot) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "clamp_workpiece") {
    match client.call(r.sidecar_url, "clamp_workpiece", "{}") {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill clamp_workpiece not in grant")
  }
}

# Fire a tool (laser/drill/welder) at target. Three grant checks in order:
#   1. skill "actuate_tool" in the grant
#   2. target.pos inside tool_lo..tool_hi (the workpiece bounding box)
#   3. workpiece sensor reports clamped (re-read every call — no bypass)
# Power is clamped to max_power before the command is sent.
fn actuate_tool(r :: t.Robot, power :: Float, target :: t.Pose, tool_lo :: t.Vec3, tool_hi :: t.Vec3, max_power :: Float) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "actuate_tool") {
    if grant.in_box_3d(target.pos, tool_lo, tool_hi) {
      match workpiece_status(r) {
        Err(e) => Stalled(str.concat("workpiece sensor: ", e)),
        Ok(ws) => {
          if ws.clamped {
            let safe_power := if power > max_power {
              max_power
            } else {
              power
            }
            let body := str.join(["{\"power\":", f(safe_power), ",\"x\":", f(target.pos.x), ",\"y\":", f(target.pos.y), ",\"z\":", f(target.pos.z), "}"], "")
            match client.call(r.sidecar_url, "fire_tool", body) {
              Err(e) => Stalled(e),
              Ok(resp) => parse_outcome(resp),
            }
          } else {
            Denied("workpiece not clamped — clamp before firing tool")
          }
        },
      }
    } else {
      Denied("target outside tool firing zone")
    }
  } else {
    Denied("skill actuate_tool not in grant")
  }
}

# ── XLeRobot skills (dual SO-101 arms + holonomic base) ──────────────────────
# A mobile dual-arm robot has TWO capability envelopes, not one: the arm's
# reach box (metres, robot frame) and the base's permitted floor area (metres,
# world frame). Rather than widen the Grant type, an XLeRobot program carries
# two Grant instances — an arm grant and a base grant — both pointing at the
# same sidecar (examples/xlerobot_demo.lex). Same primitives, per actuator group.
# Move one arm ("left" | "right") to a pose in the arm frame. Gated exactly
# like move_to: skill allowed + target inside the arm grant's workspace box.
fn move_arm(r :: t.Robot, arm :: Str, target :: t.Pose) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "move_arm") {
    if grant.in_workspace(r.grant, target.pos) {
      let body := str.join(["{\"arm\":\"", arm, "\",\"x\":", f(target.pos.x), ",\"y\":", f(target.pos.y), ",\"z\":", f(target.pos.z), ",\"rx\":", f(target.rx), ",\"ry\":", f(target.ry), ",\"rz\":", f(target.rz), "}"], "")
      match client.call(r.sidecar_url, "move_arm", body) {
        Err(e) => Stalled(e),
        Ok(resp) => parse_outcome(resp),
      }
    } else {
      Denied(str.concat(arm, " arm target outside granted workspace"))
    }
  } else {
    Denied("skill move_arm not in grant")
  }
}

# Close one arm's gripper; force clamped to the arm grant's grip ceiling
# before the command is sent (the sidecar's firmware floor caps it again).
fn grasp_arm(r :: t.Robot, arm :: Str, force :: Float) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "grasp_arm") {
    let clamped := grant.clamp_grip(r.grant, force)
    let body := str.join(["{\"arm\":\"", arm, "\",\"force\":", f(clamped), "}"], "")
    match client.call(r.sidecar_url, "grasp_arm", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill grasp_arm not in grant")
  }
}

# Speak `text` aloud through the robot's speaker (Kokoro TTS on Tier-3
# hardware; an honest "would say" no-op on Tier-1/Tier-2, which have no
# physical speaker). Grant-gated like every other actuating skill: an
# audible output is a real effect on the world (and, unlike move_arm/
# grasp_arm's numeric args, `text` may come straight from an LLM planner),
# so "is this program allowed to make the robot talk right now" is a typed,
# auditable, refusable question — the same posture `listen` takes on the
# input side. No workspace/force bound applies; there's nothing to clamp.
fn speak(r :: t.Robot, text :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "speak") {
    let body := str.join(["{\"text\":\"", json_escape_str(text), "\"}"], "")
    match client.call(r.sidecar_url, "speak", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill speak not in grant")
  }
}

# Show an image on the robot's attached screen — `source` is either a local
# file path (already on the robot) or an http(s) URL (fetched by the kiosk
# browser itself). Grant-gated like speak: the source may come straight from
# an LLM planner, so "is this program allowed to put something on the screen
# right now" stays a typed, refusable question, not an ambient one. No
# workspace/force bound applies; there's nothing to clamp.
fn show_image(r :: t.Robot, source :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "show_image") {
    let body := str.join(["{\"source\":\"", json_escape_str(source), "\"}"], "")
    match client.call(r.sidecar_url, "show_image", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill show_image not in grant")
  }
}

# Play a video on the robot's attached screen — same local-path-or-URL
# contract and grant-gating as show_image.
fn show_video(r :: t.Robot, source :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "show_video") {
    let body := str.join(["{\"source\":\"", json_escape_str(source), "\"}"], "")
    match client.call(r.sidecar_url, "show_video", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill show_video not in grant")
  }
}

# Show a webpage (via the kiosk page's <iframe>) on the robot's attached
# screen. Same grant-gating rationale as show_image — a URL is exactly the
# kind of free-form, possibly-LLM-chosen content that should stay a typed,
# refusable question. Note: some sites refuse to be iframed (X-Frame-
# Options/CSP) — that surfaces as the iframe staying blank, not an error
# this skill can detect or report.
fn show_url(r :: t.Robot, url :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "show_url") {
    let body := str.join(["{\"url\":\"", json_escape_str(url), "\"}"], "")
    match client.call(r.sidecar_url, "show_url", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill show_url not in grant")
  }
}

# Show plain text on the robot's attached screen (status, a message, a
# number — whatever). Same grant-gating rationale as show_image.
fn show_text(r :: t.Robot, text :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "show_text") {
    let body := str.join(["{\"text\":\"", json_escape_str(text), "\"}"], "")
    match client.call(r.sidecar_url, "show_text", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill show_text not in grant")
  }
}

# Blank the robot's attached screen. Grant-gated for consistency with the
# rest of the display skills, even though there's no content to leak here —
# the grant is what makes the whole show_* family a coherent, auditable
# capability rather than a special case.
fn clear_display(r :: t.Robot) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "clear_display") {
    match client.call(r.sidecar_url, "clear_display", "{}") {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill clear_display not in grant")
  }
}

# Show a picture PLUS a findings list together — the composite kind none of
# show_image/show_text alone can express (see the "fridge contents" example
# in README's "On-demand skill acquisition" discussion). Same grant-gate /
# client.call / parse_outcome shape as every other show_* skill; the sidecar
# side is xlerobot_sidecar.py's DisplayState "report" kind.
fn show_report(r :: t.Robot, image_source :: Str, items :: List[Str], caption :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "show_report") {
    let items_json := JList(list.map(items, fn (s :: Str) -> jv.Json {
      JStr(s)
    }))
    let body := jv.stringify(JObj([("source", JStr(image_source)), ("items", items_json), ("caption", JStr(caption))]))
    match client.call(r.sidecar_url, "show_report", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill show_report not in grant")
  }
}

fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("net: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

# Turn an already-captured image into a findings list, via an external
# vision API (examples/skills_api_stub.py's /vision/describe stands in for
# a real one). Deliberately [net] only, NOT [net, sense]: the camera read
# that produced `image_b64` was the [sense] effect (read_camera); this is
# judgment about data already in hand, the same distinction the
# skill-catalog's informational skills draw (see skill_library.lex's module
# comment). Not grant-checked internally, matching sense.lex's own
# locate_object/transform_to_arm convention for trusted local callers — an
# A2A caller gets gated at the door (a2a_robot_server.lex), same as those.
fn list_visible_items(vision_url :: Str, image_b64 :: Str) -> [net] Result[List[Str], Str] {
  let req_json := jv.stringify(JObj([("image_b64", JStr(image_b64))]))
  let req0 := { method: "POST", url: str.join([vision_url, "/vision/describe"], ""), headers: map.new(), body: Some(bytes.from_str(req_json)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 10000), "Content-Type", "application/json")
  match http.send(req) {
    Err(e) => Err(http_err_str(e)),
    Ok(resp) => match http.text_body(resp) {
      Err(e) => Err(http_err_str(e)),
      Ok(s) => match jv.parse(s) {
        Err(p) => Err(p.message),
        Ok(j) => match jv.get_field(j, "items") {
          None => Err("missing items in response"),
          Some(v) => match jv.as_list(v) {
            None => Err("items not a list"),
            Some(xs) => Ok(list.map(xs, fn (x :: jv.Json) -> Str {
              match jv.as_str(x) {
                Some(s) => s,
                None => "",
              }
            })),
          },
        },
      },
    },
  }
}

# Drive the holonomic base to (x, y) on the floor (z ignored, kept 0). Gated by
# the BASE grant: target inside the permitted floor area, speed clamped to the
# granted ceiling (never amplified) before the command leaves the box.
fn move_base(r :: t.Robot, target :: t.Vec3, speed :: Float) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "move_base") {
    let flat := { x: target.x, y: target.y, z: 0.0 }
    if grant.in_workspace(r.grant, flat) {
      let v := grant.clamp_velocity(r.grant, speed)
      let body := str.join(["{\"x\":", f(flat.x), ",\"y\":", f(flat.y), ",\"speed\":", f(v), "}"], "")
      match client.call(r.sidecar_url, "move_base", body) {
        Err(e) => Stalled(e),
        Ok(resp) => parse_outcome(resp),
      }
    } else {
      Denied("base target outside granted floor area")
    }
  } else {
    Denied("skill move_base not in grant")
  }
}

# Same as move_base, but ALSO requires the caller to already hold a live
# fleet_traffic.lex zone claim (fleet_arbiter_server.lex's `fleet/check`)
# covering the destination before the sidecar is ever contacted — the
# physical-safety precondition epic #115 / issue #118 adds on top of the
# grant's authority check. This is a SEPARATE gate from grant.in_workspace:
# a destination can be inside the robot's own workspace Grant (authority:
# "you're allowed to go there") while still lacking a zone claim (safety:
# "nobody's confirmed the room is clear right now") — both must pass.
#
# Deliberately a NEW function rather than changing move_base itself: dozens
# of existing callers (every non-fleet demo, every existing test) have no
# fleet arbiter to talk to and shouldn't need one — move_base stays exactly
# as it was, and only a fleet-aware caller opts into this stricter gate.
fn move_base_claimed(r :: t.Robot, arbiter_url :: Str, robot_id :: Str, target :: t.Vec3, speed :: Float) -> [net, sense, actuate] t.Outcome {
  let flat := { x: target.x, y: target.y, z: 0.0 }
  match fleet.check(arbiter_url, robot_id, flat) {
    Err(e) => Stalled(str.concat("fleet arbiter unreachable: ", e)),
    Ok(false) => Denied("no zone claim for destination — call fleet/claim first"),
    Ok(true) => move_base(r, target, speed),
  }
}

# Microphone (grant-gated, privacy-sensitive) — see sense.listen.
fn listen(r :: t.Robot, seconds :: Int) -> [net, sense] Result[Str, Str] {
  sense.listen(r, seconds)
}

# Base floor pose (refuses unparseable responses) — see sense.read_base.
fn read_base(r :: t.Robot) -> [net, sense] Result[t.Vec3, Str] {
  sense.read_base(r)
}

# Vision-based object localization — see sense.locate_object.
fn locate_object(r :: t.Robot, name :: Str) -> [net, sense] Result[t.Located, Str] {
  sense.locate_object(r, name)
}

# Re-project a world position into the current arm frame — see sense.transform_to_arm.
fn transform_to_arm(r :: t.Robot, world :: t.Vec3) -> [net, sense] Result[t.Located, Str] {
  sense.transform_to_arm(r, world)
}

