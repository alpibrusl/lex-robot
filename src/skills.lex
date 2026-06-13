# lex-robot/skills.lex — the bounded skill API.
#
# Each actuating skill: (1) checks the grant, (2) clamps to limits, (3) calls
# the sidecar. A call the grant forbids returns Denied(...) and never touches
# the wire. Sensor-only skills (read_*) don't actuate but still hit [net].

import "std.str" as str

import "std.float" as flt

import "std.int" as int

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
