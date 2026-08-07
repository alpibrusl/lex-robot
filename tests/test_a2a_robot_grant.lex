# lex-robot/tests/test_a2a_robot_grant.lex — CI smoke tests for
# a2a_robot_server.lex
#
# Mirrors tests/test_mcp_grant.lex's four grant/budget assertions, but drives
# them through the actual A2A JSON-RPC wire shape (`dispatch_request` with a
# `tasks/send` body) instead of calling `dispatch_skill` directly — proving
# the grant holds through the standard-protocol layer, not just the internal
# dispatcher. Adds two more: the XLeRobot's per-arm dispatch (move_arm/
# grasp_arm), and that the response is a real, spec-shaped A2A Task.
#
# Run (standalone; llm,proc required too — see a2a_robot_server.lex):
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
#       tests/test_a2a_robot_grant.lex main

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.time" as time

import "lex-trail/log" as trail

import "../src/types" as t

import "../src/mcp_server" as mcp

import "../src/a2a_robot_server" as a2a

# ── Fixtures ──────────────────────────────────────────────────────────────────

fn make_grant(skill_names :: List[Str], budget_actions :: Int) -> t.Grant {
  {
    skills: skill_names,
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 0.5,
    max_force: 50.0,
    max_grip_force: 40.0,
    budget_actions: budget_actions,
    budget_wall_ms: 60000,
  }
}

fn make_robot(skill_names :: List[Str], budget_actions :: Int) -> t.Robot {
  { sidecar_url: "http://localhost:19999", grant: make_grant(skill_names, budget_actions) }
}

# A `tasks/send` body naming `skill_name` with a DataPart carrying `data_json`
# as its structured arguments.
fn tasks_send_body(skill_name :: Str, data_json :: Str) -> Str {
  str.join([
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{",
    "\"id\":\"t_1\",\"contextId\":\"ctx_1\",\"skill\":\"", skill_name, "\",",
    "\"message\":{\"kind\":\"message\",\"messageId\":\"m1\",\"role\":\"user\",",
    "\"parts\":[{\"type\":\"data\",\"data\":", data_json, "}]}}}"
  ], "")
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Deny: skill not in grant → the Task comes back `failed` with a
#    "denied:" outcome in the reply DataPart.
fn test_deny_skill_not_in_grant() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["grasp"], 10)
        let body := tasks_send_body("move_to", "{\"x\":0.5,\"y\":0.5,\"z\":0.2}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "\"state\":\"failed\"") and str.contains(resp, "denied:") {
          Ok(())
        } else {
          Err(str.concat("expected a failed task carrying denied:, got: ", resp))
        }
      },
    },
  }
}

# 2. Allow: skill present, target in workspace → reaches the sidecar
#    (stalled, since :19999 isn't listening) and the Task is `completed` —
#    stalled/timeout still count as the goal action having left the box,
#    same distinction dispatch_skill's outcome text already draws.
fn test_allow_reaches_sidecar() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_to"], 10)
        let body := tasks_send_body("move_to", "{\"x\":0.5,\"y\":0.5,\"z\":0.2}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied:") {
          Err(str.concat("skill was denied but should have reached the sidecar: ", resp))
        } else {
          if str.contains(resp, "\"kind\":\"task\"") and str.contains(resp, "\"id\":\"t_1\"") {
            Ok(())
          } else {
            Err(str.concat("response is not a well-formed A2A task: ", resp))
          }
        }
      },
    },
  }
}

# 3. Clamp: grasp force above max_grip_force is clamped, not denied.
fn test_grasp_force_clamped_not_denied() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["grasp"], 10)
        let body := tasks_send_body("grasp", "{\"force\":999.9}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied: skill grasp") {
          Err(str.concat("grasp was denied (should be clamped): ", resp))
        } else {
          Ok(())
        }
      },
    },
  }
}

# 4. Budget: budget_actions=1; second actuating call returns a "killed:"
#    outcome inside a `failed` task.
fn test_budget_exhausted_returns_killed() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_to"], 1)
        let _init := mcp.ledger_init(db, robot.grant, time.now_ms())
        let body := tasks_send_body("move_to", "{\"x\":0.5,\"y\":0.5,\"z\":0.2}")
        let _first := a2a.dispatch_request(robot, db, log, body)
        let second := a2a.dispatch_request(robot, db, log, body)
        if str.contains(second, "\"state\":\"failed\"") and str.contains(second, "killed:") {
          Ok(())
        } else {
          Err(str.concat("expected a failed task carrying killed:, got: ", second))
        }
      },
    },
  }
}

# 5. XLeRobot per-arm dispatch: move_arm resolves through the same grant —
#    denied when move_arm isn't granted, reaches the sidecar when it is.
fn test_move_arm_denied_when_not_granted() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["grasp_arm"], 10)
        let body := tasks_send_body("move_arm", "{\"arm\":\"left\",\"x\":0.3,\"y\":0.2,\"z\":0.2}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied: skill move_arm") {
          Ok(())
        } else {
          Err(str.concat("expected move_arm denied, got: ", resp))
        }
      },
    },
  }
}

fn test_move_arm_reaches_sidecar_when_granted() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_arm"], 10)
        let body := tasks_send_body("move_arm", "{\"arm\":\"left\",\"x\":0.3,\"y\":0.2,\"z\":0.2}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied:") {
          Err(str.concat("move_arm was denied but should have reached the sidecar: ", resp))
        } else {
          Ok(())
        }
      },
    },
  }
}

# 6. speak: grant-gated like every other actuating skill (unlike locate_object/
#    transform_to_arm, which are sensing-only and ungated) — denied when not
#    granted, reaches the sidecar (and is budget-charged) when it is.
fn test_speak_denied_when_not_granted() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["move_arm"], 10)
        let body := tasks_send_body("speak", "{\"text\":\"hello\"}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied: skill speak") {
          Ok(())
        } else {
          Err(str.concat("expected speak denied, got: ", resp))
        }
      },
    },
  }
}

fn test_speak_reaches_sidecar_when_granted() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["speak"], 10)
        let body := tasks_send_body("speak", "{\"text\":\"hello, i have the cup\"}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied:") {
          Err(str.concat("speak was denied but should have reached the sidecar: ", resp))
        } else {
          Ok(())
        }
      },
    },
  }
}

# 7. locate_object/transform_to_arm are sensing-only, like read_base/listen —
#    no grant check at all (see sense.lex), so even a grant that never
#    mentions them still reaches the sidecar (fails on the network, since
#    :19999 isn't listening — never "denied:").
fn test_locate_object_not_grant_gated() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot([], 10)
        let body := tasks_send_body("locate_object", "{\"name\":\"cup\"}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied:") {
          Err(str.concat("locate_object was denied but is sensing-only (ungated): ", resp))
        } else {
          if str.contains(resp, "\"state\":\"failed\"") {
            Ok(())
          } else {
            Err(str.concat("expected a failed task (no sidecar listening), got: ", resp))
          }
        }
      },
    },
  }
}

fn test_transform_to_arm_not_grant_gated() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot([], 10)
        let body := tasks_send_body("transform_to_arm", "{\"x\":0.3,\"y\":0.1,\"z\":0.2}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "denied:") {
          Err(str.concat("transform_to_arm was denied but is sensing-only (ungated): ", resp))
        } else {
          if str.contains(resp, "\"state\":\"failed\"") {
            Ok(())
          } else {
            Err(str.concat("expected a failed task (no sidecar listening), got: ", resp))
          }
        }
      },
    },
  }
}

# 8. Unknown skill name still refuses cleanly (falls through to
#    mcp.dispatch_skill's "error: unknown tool:" — never silently allowed).
fn test_unknown_skill_refused() -> [sql, fs_write, time, net, sense, actuate] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match trail.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let robot := make_robot(["teleport"], 10)
        let body := tasks_send_body("teleport", "{}")
        let resp := a2a.dispatch_request(robot, db, log, body)
        if str.contains(resp, "\"state\":\"failed\"") and str.contains(resp, "error: unknown tool") {
          Ok(())
        } else {
          Err(str.concat("expected failed task carrying an unknown-tool error, got: ", resp))
        }
      },
    },
  }
}

# ── Runner (CI: panics on any failure) ───────────────────────────────────────

fn main() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, sense, actuate] Nil {
  let results := [
    test_deny_skill_not_in_grant(),
    test_allow_reaches_sidecar(),
    test_grasp_force_clamped_not_denied(),
    test_budget_exhausted_returns_killed(),
    test_move_arm_denied_when_not_granted(),
    test_move_arm_reaches_sidecar_when_granted(),
    test_speak_denied_when_not_granted(),
    test_speak_reaches_sidecar_when_granted(),
    test_locate_object_not_grant_gated(),
    test_transform_to_arm_not_grant_gated(),
    test_unknown_skill_refused()
  ]
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  })
  if failures == 0 {
    ()
  } else {
    let _ := 1 / 0
    ()
  }
}
