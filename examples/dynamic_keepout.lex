# examples/dynamic_keepout.lex — dynamic human keep-out (live-updating no-go zone).
#
# Extends safe_rollout.lex to a MOVING bystander: the exclusion zone updates
# every step to track the person's current position. Same deterministic policy,
# two modes:
#
#   UNGOVERNED — commands applied raw; the bystander's zone is freely entered.
#   GOVERNED   — each step: read bystander → live keep-out box → block if unsafe;
#                blocked intrusions recorded in lex-trail (with bystander pos at
#                block time).
#
# Acceptance (issue #8):
#   Ungoverned: N commands enter the moving zone.
#   Governed:   0 executed into the zone; all N blocked + audited.
#   Same policy, same bystander path — the live grant gate is the only difference.
#
#   python3 sidecar/sim_sidecar.py &
#   lex run --allow-effects net,sense,actuate,io,sql,fs_write,time \
#       examples/dynamic_keepout.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "lex-trail/src/log" as tlog

import "../src/types" as t

import "../src/grant" as grant

import "../src/skills" as skills

# Exclusion radius around the bystander in normalised workspace coords.
fn margin() -> Float { 0.15 }

fn f(x :: Float) -> Str { flt.to_str(x) }

fn pos_str(p :: t.Vec3) -> Str {
  str.join(["(", f(p.x), ",", f(p.y), ")"], "")
}

type RunStats = { in_zone :: Int, blocked :: Int }

# Build the axis-aligned keep-out box around the bystander's current position.
fn ko_lo(by :: t.Vec3) -> t.Vec3 {
  let m := margin()
  { x: by.x - m, y: by.y - m, z: 0.0 }
}

fn ko_hi(by :: t.Vec3) -> t.Vec3 {
  let m := margin()
  { x: by.x + m, y: by.y + m, z: 0.0 }
}

# Append one blocked-intrusion event to the trail, chained to parent.
fn trail_blocked(log :: tlog.Log, parent :: Str, by_pos :: t.Vec3, cmd :: t.Vec3) -> [sql, time] Str {
  let detail := str.join([
    "{\"bystander\":", pos_str(by_pos), ",\"cmd\":", pos_str(cmd), "}"
  ], "")
  match tlog.append(log, "keep_out_blocked", Some(parent), detail) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
}

fn step(r :: t.Robot, govern :: Bool, log :: tlog.Log, parent :: Str, acc :: RunStats)
    -> [net, sense, actuate, io, sql, time] { stats :: RunStats, parent :: Str } {
  match skills.read_bystander(r) {
    Err(_) => { stats: acc, parent: parent },
    Ok(by_pos) => {
      match skills.policy_action(r) {
        Err(_) => { stats: acc, parent: parent },
        Ok(want) => {
          let lo := ko_lo(by_pos)
          let hi := ko_hi(by_pos)
          let unsafe := grant.in_box(want, lo, hi)
          if govern {
            if unsafe {
              let safe := grant.project_out_box(want, lo, hi)
              let __a := skills.apply_action(r, safe)
              let __p := io.print(str.join([
                "  BLOCKED person", pos_str(by_pos), " cmd", pos_str(want), " → redirected"
              ], ""))
              let new_parent := trail_blocked(log, parent, by_pos, want)
              { stats: { in_zone: acc.in_zone, blocked: acc.blocked + 1 }, parent: new_parent }
            } else {
              let __a := skills.apply_action(r, want)
              { stats: acc, parent: parent }
            }
          } else {
            let __a := skills.apply_action(r, want)
            if unsafe {
              let __p := io.print(str.join([
                "  entered zone: person", pos_str(by_pos), " cmd", pos_str(want)
              ], ""))
              { stats: { in_zone: acc.in_zone + 1, blocked: acc.blocked }, parent: parent }
            } else {
              { stats: acc, parent: parent }
            }
          }
        },
      }
    },
  }
}

fn loop(r :: t.Robot, govern :: Bool, n :: Int, log :: tlog.Log, parent :: Str, acc :: RunStats)
    -> [net, sense, actuate, io, sql, time] RunStats {
  if n <= 0 {
    acc
  } else {
    let res := step(r, govern, log, parent, acc)
    loop(r, govern, n - 1, log, res.parent, res.stats)
  }
}

fn run_one(r :: t.Robot, govern :: Bool, steps :: Int, log :: tlog.Log, parent :: Str)
    -> [net, sense, actuate, io, sql, time] RunStats {
  let __r := skills.reset_episode(r, "sim")
  loop(r, govern, steps, log, parent, { in_zone: 0, blocked: 0 })
}

fn run() -> [net, sense, actuate, io, sql, fs_write, time] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }
  let steps := 80
  match tlog.open("/tmp/lex-robot-dynamic-keepout.db") {
    Err(e) => {
      let __e := io.print(str.concat("trail open failed: ", e))
      ()
    },
    Ok(log) => {
      match tlog.append(log, "dynamic_keepout_started", None, "{}") {
        Err(_) => (),
        Ok(root) => {
          let __h1 := io.print("=== UNGOVERNED (raw policy, bystander ignored) ===")
          let u := run_one(robot, false, steps, log, root.id)
          let __u := io.print(str.join([
            "commands entered bystander zone: ", int.to_str(u.in_zone), " / ", int.to_str(steps)
          ], ""))

          let __h2 := io.print("=== GOVERNED (Lex live keep-out: zone tracks person every step) ===")
          let g := run_one(robot, true, steps, log, root.id)
          let __g := io.print(str.join([
            "commands BLOCKED: ", int.to_str(g.blocked), "  (entered zone: 0)"
          ], ""))

          let __v := io.print("→ same policy, same bystander path; the live grant gate is the only difference.")
          let __t := io.print(str.join([
            "lex-trail: /tmp/lex-robot-dynamic-keepout.db  (", int.to_str(g.blocked), " blocked events)"
          ], ""))
          ()
        },
      }
    },
  }
}

fn demo_grant() -> t.Grant {
  {
    skills: ["policy_action", "apply_action", "reset_episode", "read_bystander"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 1.0,
    max_force: 15.0,
    max_grip_force: 20.0,
    budget_actions: 200,
    budget_wall_ms: 120000,
  }
}
