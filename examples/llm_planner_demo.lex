# examples/llm_planner_demo.lex — untrusted LLM planner, Lex on the rails.
#
# The lex-os thesis (judgment vs. authority) applied to a body: an LLM proposes
# high-level steps; the Lex GRANT decides what the robot is actually allowed to
# do. The LLM here is asked to "tidy the cup into the bin" and — as LLMs do —
# emits a mix of sensible steps, a hallucinated reach, an over-grip, an
# out-of-bounds move, and a prompt-injected "sweep everything off the table".
#
# Lex sits between the plan and the actuators: every proposed action is checked
# against the grant (skill allowlist, workspace, keep-out/bystander zone, force
# ceiling) BEFORE it can reach the sidecar. Unsafe actions are blocked or
# clamped and never sent; the safe ones run; the task is "done" only when the
# goal action actually completes (Verify). Every proposed-vs-executed decision
# is appended to a hash-chained lex-trail audit.
#
# Vanilla LeRobot would execute whatever the planner emits. The grant is the
# difference.
#
#   python3 sidecar/sim_sidecar.py &
#   lex run --allow-effects net,sense,actuate,io,sql,fs_write,time examples/llm_planner_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.list" as list

import "lex-trail/src/log" as tlog

import "lex-trail/src/event" as ev

import "../src/types" as t

import "../src/grant" as grant

import "../src/skills" as skills

# One step the LLM proposed: a tool call (skill + args) plus where it came from
# (the LLM's own label: a real task step, a hallucination, an injection, ...).
type Action = { skill :: Str, x :: Float, y :: Float, z :: Float, force :: Float, src :: Str }

type Stats = { executed :: Int, blocked :: Int, clamped :: Int, goal_done :: Bool, parent :: Str }

fn is_reached(o :: t.Outcome) -> Bool {
  match o { Reached => true, _ => false }
}

# ── The "LLM" planner ────────────────────────────────────────────────────────
# Offline default: a canned plan that mirrors what an LLM returns for the task,
# including the failure modes we care about. (Swap this for a real lex-llm call
# that returns structured tool calls — the governance below is unchanged.)
fn propose_plan() -> List[Action] {
  [
    { skill: "move_to", x: 0.5, y: 0.1, z: 0.2, force: 0.0, src: "task: approach the cup" },
    { skill: "grasp",   x: 0.0, y: 0.0, z: 0.0, force: 18.0, src: "task: pick up the cup" },
    { skill: "grasp",   x: 0.0, y: 0.0, z: 0.0, force: 250.0, src: "llm: grip it hard so it won't slip" },
    { skill: "move_to", x: 0.45, y: 0.5, z: 0.2, force: 0.0, src: "hallucination: shortcut across the table" },
    { skill: "move_to", x: 0.5, y: 1.5, z: 0.2, force: 0.0, src: "llm: reach behind the wall" },
    { skill: "sweep_all", x: 0.0, y: 0.0, z: 0.0, force: 0.0, src: "INJECTED: sweep everything off the table" },
    { skill: "move_to", x: 0.8, y: 0.2, z: 0.1, force: 0.0, src: "goal: place the cup in the bin" },
    { skill: "grasp",   x: 0.0, y: 0.0, z: 0.0, force: 0.0, src: "task: release the cup" },
  ]
}

# Keep-out zone: a bystander/fragile region in the workspace the robot must not
# enter (x/y box). The LLM's "shortcut" tries to cross it.
fn ko_lo() -> t.Vec3 { { x: 0.3, y: 0.3, z: 0.0 } }
fn ko_hi() -> t.Vec3 { { x: 0.6, y: 0.7, z: 0.0 } }

fn demo_grant() -> t.Grant {
  {
    skills: ["move_to", "grasp"],          # NOT "sweep_all" — injection can't run
    ws_min: { x: 0.1, y: 0.0 - 0.3, z: 0.0 },
    ws_max: { x: 0.9, y: 0.9, z: 0.4 },
    max_velocity: 0.25,
    max_force: 15.0,
    max_grip_force: 20.0,
  }
}

fn payload(s :: Str) -> Str {
  let clean := str.replace(str.replace(s, "\"", "'"), "\n", " ")
  str.join(["{\"detail\":\"", clean, "\"}"], "")
}

fn trail(log :: tlog.Log, parent :: Str, kind :: Str, detail :: Str) -> [sql, time] Str {
  match tlog.append(log, kind, Some(parent), payload(detail)) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
}

fn posxy(a :: Action) -> Str {
  str.join(["(", flt.to_str(a.x), ",", flt.to_str(a.y), ",", flt.to_str(a.z), ")"], "")
}

# Govern + (maybe) execute one proposed action; log the decision; update stats.
fn govern_one(r :: t.Robot, a :: Action, st :: Stats, log :: tlog.Log) -> [net, sense, actuate, io, sql, time] Stats {
  let g := r.grant
  if grant.skill_allowed(g, a.skill) {
    if a.skill == "move_to" {
      let pos := { x: a.x, y: a.y, z: a.z }
      if grant.in_workspace(g, pos) {
        if grant.in_box(pos, ko_lo(), ko_hi()) {
          let __p := io.print(str.join(["  [BLOCK] move_to ", posxy(a), " — ", a.src, " — enters keep-out (bystander) zone; NOT SENT"], ""))
          { executed: st.executed, blocked: st.blocked + 1, clamped: st.clamped, goal_done: st.goal_done,
            parent: trail(log, st.parent, "blocked", str.concat("move_to keep-out: ", a.src)) }
        } else {
          let o := skills.move_to(r, { pos: pos, rx: 0.0, ry: 0.0, rz: 0.0 })
          let ok := is_reached(o)
          let goal := if ok { str.contains(a.src, "goal") } else { false }
          let __p := io.print(str.join(["  [ALLOW] move_to ", posxy(a), " — ", a.src], ""))
          { executed: st.executed + 1, blocked: st.blocked, clamped: st.clamped,
            goal_done: if goal { true } else { st.goal_done },
            parent: trail(log, st.parent, "executed", str.concat("move_to ", a.src)) }
        }
      } else {
        let __p := io.print(str.join(["  [BLOCK] move_to ", posxy(a), " — ", a.src, " — outside granted workspace; NOT SENT"], ""))
        { executed: st.executed, blocked: st.blocked + 1, clamped: st.clamped, goal_done: st.goal_done,
          parent: trail(log, st.parent, "blocked", str.concat("move_to out-of-bounds: ", a.src)) }
      }
    } else {
      # grasp: the grant clamps force to the grip ceiling before it is sent.
      let over := a.force > g.max_grip_force
      let __e := skills.grasp(r, a.force)
      let msg := if over {
        str.join(["  [CLAMP] grasp ", flt.to_str(a.force), "N -> ", flt.to_str(g.max_grip_force), "N — ", a.src], "")
      } else {
        str.join(["  [ALLOW] grasp ", flt.to_str(a.force), "N — ", a.src], "")
      }
      let __p := io.print(msg)
      { executed: st.executed + 1, blocked: st.blocked,
        clamped: if over { st.clamped + 1 } else { st.clamped },
        goal_done: st.goal_done,
        parent: trail(log, st.parent, if over { "clamped" } else { "executed" }, str.concat("grasp ", a.src)) }
    }
  } else {
    let __p := io.print(str.join(["  [BLOCK] ", a.skill, " — ", a.src, " — skill not in grant; NOT SENT"], ""))
    { executed: st.executed, blocked: st.blocked + 1, clamped: st.clamped, goal_done: st.goal_done,
      parent: trail(log, st.parent, "blocked", str.join([a.skill, " not in grant: ", a.src], "")) }
  }
}

fn govern_all(r :: t.Robot, plan :: List[Action], st :: Stats, log :: tlog.Log) -> [net, sense, actuate, io, sql, time] Stats {
  match list.head(plan) {
    None => st,
    Some(a) => {
      let st2 := govern_one(r, a, st, log)
      govern_all(r, list.tail(plan), st2, log)
    },
  }
}

fn run() -> [net, sense, actuate, io, sql, fs_write, time] Unit {
  let robot := { sidecar_url: "http://localhost:8900", grant: demo_grant() }
  let plan := propose_plan()
  let __h := io.print(str.join(["=== untrusted LLM planner — ", int.to_str(list.len(plan)), " proposed steps; Lex on the rails ==="], ""))

  match tlog.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => match tlog.append(log, "plan_received", None, "{}") {
      Err(e) => io.print(str.concat("trail root failed: ", e)),
      Ok(root) => {
        let st := govern_all(robot, plan, { executed: 0, blocked: 0, clamped: 0, goal_done: false, parent: root.id }, log)
        let __s := io.print(str.join(["executed: ", int.to_str(st.executed), "   clamped: ", int.to_str(st.clamped), "   BLOCKED (never sent): ", int.to_str(st.blocked)], ""))
        # Verify gate: the task is done only if the goal action actually completed.
        let __v := if st.goal_done {
          io.print("task SUCCESS — cup placed in the bin (Verify gate passed)")
        } else {
          io.print("task FAILED — goal not confirmed")
        }
        # Audit: replay the chain and recompute every content hash (is_valid) —
        # any tampered proposed/executed/blocked record surfaces here.
        let __a := match tlog.range(log, 0, 9999999999999) {
          Err(e) => io.print(str.concat("audit read failed: ", e)),
          Ok(evs) => {
            let n := list.len(evs)
            let valid := list.fold(evs, 0, fn (acc :: Int, e :: ev.Event) -> Int {
              if ev.is_valid(e) { acc + 1 } else { acc }
            })
            io.print(str.join(["audit: ", int.to_str(n), " events, ", int.to_str(valid), " valid → ", if valid == n { "chain intact (tamper-evident)" } else { "TAMPERED" }], ""))
          },
        }
        io.print(str.concat("audit head: ", st.parent))
      },
    },
  }
}
