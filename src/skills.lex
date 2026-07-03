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

import "std.float" as flt

import "std.list" as list

import "./types" as t

import "./grant" as grant

import "./client" as client

# ── JSON helpers (manual; scaffold avoids a json dep) ────────────────────────
fn f(x :: Float) -> Str {
  flt.to_str(x)
}

fn pose_json(p :: t.Pose) -> Str {
  str.join([
    "{\"x\":", f(p.pos.x), ",\"y\":", f(p.pos.y), ",\"z\":", f(p.pos.z),
    ",\"rx\":", f(p.rx), ",\"ry\":", f(p.ry), ",\"rz\":", f(p.rz), "}"
  ], "")
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

# ── Tiny flat-JSON float extractor (scaffold; avoids a json dep) ─────────────
fn nth1(xs :: List[Str]) -> Str {
  match list.head(list.tail(xs)) { Some(v) => v, None => "" }
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
    Ok(s) => Ok({
      pos: { x: jfloat(s, "\"x\":", 0.0), y: jfloat(s, "\"y\":", 0.0), z: jfloat(s, "\"z\":", 0.0) },
      rx: jfloat(s, "\"rx\":", 0.0), ry: jfloat(s, "\"ry\":", 0.0), rz: jfloat(s, "\"rz\":", 0.0),
    }),
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
fn read_joints(r :: t.Robot) -> [net, sense] Result[Str, Str] {
  client.call(r.sidecar_url, "read_joints", "{}")
}

fn read_camera(r :: t.Robot, name :: Str) -> [net, sense] Result[Str, Str] {
  client.call(r.sidecar_url, "read_camera", str.join(["{\"name\":\"", name, "\"}"], ""))
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
    # Accept both compact (`"clamped":true`) and spaced (`"clamped": true`) JSON,
    # so the parse doesn't depend on the sidecar's serializer spacing.
    Ok(s) => Ok({
      present: str.contains(s, "\"present\":true") or str.contains(s, "\"present\": true"),
      clamped: str.contains(s, "\"clamped\":true") or str.contains(s, "\"clamped\": true"),
    }),
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
fn actuate_tool(r :: t.Robot, power :: Float, target :: t.Pose,
                tool_lo :: t.Vec3, tool_hi :: t.Vec3, max_power :: Float)
    -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "actuate_tool") {
    if grant.in_box_3d(target.pos, tool_lo, tool_hi) {
      match workpiece_status(r) {
        Err(e) => Stalled(str.concat("workpiece sensor: ", e)),
        Ok(ws) => {
          if ws.clamped {
            let safe_power := if power > max_power { max_power } else { power }
            let body := str.join([
              "{\"power\":", f(safe_power),
              ",\"x\":", f(target.pos.x), ",\"y\":", f(target.pos.y), ",\"z\":", f(target.pos.z),
              "}"
            ], "")
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
      let body := str.join([
        "{\"arm\":\"", arm,
        "\",\"x\":", f(target.pos.x), ",\"y\":", f(target.pos.y), ",\"z\":", f(target.pos.z),
        ",\"rx\":", f(target.rx), ",\"ry\":", f(target.ry), ",\"rz\":", f(target.rz), "}"
      ], "")
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

# Read the base's current floor pose (x, y, heading in detail JSON). A response
# without an "x" field (e.g. {"error":"unknown skill"} from the wrong sidecar on
# the shared port) is an Err — never silently decoded as a pose at the origin,
# because this reading may be recorded into a verified trail.
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
