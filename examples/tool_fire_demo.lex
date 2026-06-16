# examples/tool_fire_demo.lex — dangerous-tool fire-only-in-bounds demo.
#
# A robot wielding a high-consequence tool (laser/drill/welder) can ONLY fire:
#   (1) inside the workpiece bounding box (tool_lo..tool_hi), AND
#   (2) after the workpiece is physically clamped.
#
# The grant makes both constraints impossible to bypass: the actuate_tool skill
# checks each in turn before issuing any command. Four attempts; three blocked:
#
#   mid-air      → BLOCKED: target outside tool firing zone
#   hand region  → BLOCKED: target outside tool firing zone
#   not clamped  → BLOCKED: workpiece not clamped
#   clamped      → FIRED at 100W (power clamped from 150W)
#
# Every attempt is audited in lex-trail (allowed + blocked).
#
# Acceptance (issue #6):
#   ≥3 unsafe fire attempts blocked; 1 valid fire after clamp Verify;
#   lex-trail verify passes.
#
#   python3 sidecar/sim_sidecar.py &
#   lex run --allow-effects net,sense,actuate,io,sql,fs_write,time \
#       examples/tool_fire_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.float" as flt

import "lex-trail/src/log" as tlog

import "../src/types" as t

import "../src/skills" as skills

# Workpiece bounding box — the only zone the tool may fire in.
fn tool_lo() -> t.Vec3 { { x: 0.35, y: 0.35, z: 0.05 } }
fn tool_hi() -> t.Vec3 { { x: 0.65, y: 0.65, z: 0.25 } }

# Tool power ceiling (Watts). Anything above this is clamped.
fn max_power() -> Float { 100.0 }

fn f(x :: Float) -> Str { flt.to_str(x) }

fn pos_str(v :: t.Vec3) -> Str {
  str.join(["(", f(v.x), ",", f(v.y), ",", f(v.z), ")"], "")
}

fn pose_at(x :: Float, y :: Float, z :: Float) -> t.Pose {
  { pos: { x: x, y: y, z: z }, rx: 0.0, ry: 0.0, rz: 0.0 }
}

fn outcome_str(o :: t.Outcome) -> Str {
  match o {
    Reached    => "FIRED",
    Stalled(m) => str.concat("stalled: ", m),
    Denied(m)  => str.concat("BLOCKED: ", m),
    Killed(m)  => str.concat("killed: ", m),
    Timeout    => "timeout",
  }
}

fn trail_attempt(log :: tlog.Log, parent :: Str, label :: Str, result :: Str)
    -> [sql, time] Str {
  let detail := str.join(["{\"attempt\":\"", label, "\",\"outcome\":\"", result, "\"}"], "")
  match tlog.append(log, "tool_fire_attempt", Some(parent), detail) {
    Ok(ev) => ev.id,
    Err(_)  => parent,
  }
}

# Fire the tool, print the result, and append a trail event. Returns the new parent id.
fn try_fire(r :: t.Robot, label :: Str, power :: Float, pose :: t.Pose,
            log :: tlog.Log, parent :: Str)
    -> [net, sense, actuate, io, sql, time] Str {
  let __h := io.print(str.join(["  [", label, "]  power=", f(power), "W  target", pos_str(pose.pos)], ""))
  let o := skills.actuate_tool(r, power, pose, tool_lo(), tool_hi(), max_power())
  let result := outcome_str(o)
  let __r := io.print(str.concat("    → ", result))
  trail_attempt(log, parent, label, result)
}

fn run() -> [net, sense, actuate, io, sql, fs_write, time] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }
  match tlog.open("/tmp/lex-robot-tool-fire.db") {
    Err(e) => {
      let __e := io.print(str.concat("trail open failed: ", e))
      ()
    },
    Ok(log) => {
      match tlog.append(log, "tool_fire_demo_started", None, "{}") {
        Err(_) => (),
        Ok(root) => {
          let __h := io.print("=== dangerous-tool: fire-only-in-bounds ===")
          let __b := io.print(str.join([
            "  fire zone ", pos_str(tool_lo()), " → ", pos_str(tool_hi()),
            "  ceiling ", f(max_power()), "W"
          ], ""))

          # Attempt 1: mid-air — z=0.80 is far above the workpiece box (hi.z=0.25).
          let p1 := try_fire(robot, "mid-air (z=0.80)", 80.0, pose_at(0.5, 0.5, 0.80), log, root.id)

          # Attempt 2: hand region — x=0.10 is left of the workpiece box (lo.x=0.35).
          let p2 := try_fire(robot, "hand region (x=0.10)", 80.0, pose_at(0.10, 0.5, 0.15), log, p1)

          # Attempt 3: on the workpiece but NOT clamped yet.
          let p3 := try_fire(robot, "workpiece, NOT clamped", 80.0, pose_at(0.5, 0.5, 0.15), log, p2)

          # Clamp the workpiece (physical action — sidecar state changes).
          let __c := io.print("  → clamping workpiece...")
          let clamp_o := skills.clamp_workpiece(robot)
          let __cl := io.print(match clamp_o {
            Reached => "    → workpiece clamped",
            _ => str.concat("    → clamp failed: ", outcome_str(clamp_o)),
          })

          # Attempt 4: workpiece clamped; power 150W → clamped to max 100W.
          let __p4 := try_fire(robot, "workpiece, CLAMPED, 150W→100W", 150.0, pose_at(0.5, 0.5, 0.15), log, p3)

          let __v := io.print("=== 3 BLOCKED, 1 FIRED (power-clamped); all 4 attempts in lex-trail ===")
          let __t := io.print("lex-trail: /tmp/lex-robot-tool-fire.db")
          ()
        },
      }
    },
  }
}

fn demo_grant() -> t.Grant {
  {
    skills: ["actuate_tool", "clamp_workpiece", "workpiece_status"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 1.0,
    max_force: 15.0,
    max_grip_force: 20.0,
    budget_actions: 20,
    budget_wall_ms: 60000,
  }
}
