# lex-robot/skills.lex — the bounded skill API.
#
# Each actuating skill: (1) checks the grant, (2) clamps to limits, (3) calls
# the sidecar. A call the grant forbids returns Denied(...) and never touches
# the wire. Sensor-only skills (read_*) don't actuate but still hit [net].

import "std.str" as str

import "std.float" as flt

import "std.int" as int

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
fn policy_action(r :: t.Robot) -> [net] Result[t.Vec3, Str] {
  match client.call(r.sidecar_url, "policy_action", "{}") {
    Err(e) => Err(e),
    Ok(s) => Ok({ x: jfloat(s, "\"x\":", 0.5), y: jfloat(s, "\"y\":", 0.5), z: 0.0 }),
  }
}

# Execute a (possibly grant-adjusted) command; returns the resulting reward.
fn apply_action(r :: t.Robot, p :: t.Vec3) -> [net] Result[Float, Str] {
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
fn read_inlet(r :: t.Robot) -> [net] Result[t.Pose, Str] {
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
fn connect_charger(r :: t.Robot, force :: Float) -> [net] t.Outcome {
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

fn disconnect_charger(r :: t.Robot) -> [net] t.Outcome {
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
fn read_joints(r :: t.Robot) -> [net] Result[Str, Str] {
  client.call(r.sidecar_url, "read_joints", "{}")
}

fn read_camera(r :: t.Robot, name :: Str) -> [net] Result[Str, Str] {
  client.call(r.sidecar_url, "read_camera", str.join(["{\"name\":\"", name, "\"}"], ""))
}

# ── Actuating (grant-gated) ──────────────────────────────────────────────────
fn move_to(r :: t.Robot, target :: t.Pose) -> [net] t.Outcome {
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

fn grasp(r :: t.Robot, force :: Float) -> [net] t.Outcome {
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

# Hands the high-rate loop to LeRobot; the lex-os supervisor enforces the budget.
fn run_policy(r :: t.Robot, name :: Str, goal :: Str, budget_ms :: Int) -> [net] t.Outcome {
  if grant.skill_allowed(r.grant, "run_policy") {
    let body := str.join([
      "{\"name\":\"", name, "\",\"goal\":\"", goal, "\",\"budget_ms\":", int.to_str(budget_ms), "}"
    ], "")
    match client.call(r.sidecar_url, "run_policy", body) {
      Err(e) => Stalled(e),
      Ok(resp) => parse_outcome(resp),
    }
  } else {
    Denied("skill run_policy not in grant")
  }
}

fn record_episode(r :: t.Robot, task :: Str) -> [net] Result[Str, Str] {
  if grant.skill_allowed(r.grant, "record_episode") {
    client.call(r.sidecar_url, "record_episode", str.join(["{\"task\":\"", task, "\"}"], ""))
  } else {
    Err("skill record_episode not in grant")
  }
}
