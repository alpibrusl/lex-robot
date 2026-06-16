# lex-robot/task.lex — evidence-gated task graph (the lex-loom pattern) with a
# hash-chained lex-trail audit.
#
# Perceive → Plan → Execute → Verify, hard gate at Verify (done only when a real
# outcome confirms it), bounded retries. Every phase is appended to a lex-trail
# log, each event chained to the previous via its content-hash id — a
# tamper-evident record of exactly what the robot did.

import "std.str" as str

import "std.io" as io

import "std.int" as int

import "lex-trail/src/log" as tlog

import "./types" as t

import "./skills" as skills

import "./policy" as policy

type StepLog = { phase :: Str, ok :: Bool, detail :: Str }

type TaskResult = { success :: Bool, attempts :: Int, last_event :: Str }

fn outcome_str(o :: t.Outcome) -> Str {
  match o {
    Reached => "reached",
    Stalled(m) => str.concat("stalled: ", m),
    Denied(m) => str.concat("denied: ", m),
    Timeout => "timeout",
  }
}

fn is_reached(o :: t.Outcome) -> Bool {
  match o {
    Reached => true,
    _ => false,
  }
}

# Sanitize a detail string into a JSON payload (drops quotes/newlines).
fn payload(detail :: Str) -> Str {
  let clean := str.replace(str.replace(detail, "\"", "'"), "\n", " ")
  str.join(["{\"detail\":\"", clean, "\"}"], "")
}

# Append one event chained to `parent`; return the new event id (or `parent`
# unchanged on failure, so the chain never breaks the run).
fn trail(log :: tlog.Log, parent :: Str, kind :: Str, detail :: Str) -> [sql, time] Str {
  match tlog.append(log, kind, Some(parent), payload(detail)) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
}

# ── Phases ───────────────────────────────────────────────────────────────────
fn perceive(r :: t.Robot) -> [net, sense] StepLog {
  match skills.read_joints(r) {
    Err(e) => { phase: "perceive", ok: false, detail: e },
    Ok(s) => { phase: "perceive", ok: true, detail: s },
  }
}

fn plan_target() -> t.Pose {
  { pos: { x: 0.5, y: 0.5, z: 0.2 }, rx: 0.0, ry: 0.0, rz: 0.0 }
}

# use_policy=true gates on real task completion via a learned LeRobot policy;
# false uses a single grant-checked move (fast, structural).
fn execute(r :: t.Robot, target :: t.Pose, use_policy :: Bool) -> [net, sense, actuate, time] t.Outcome {
  if use_policy {
    # budget_ms maps to a step cap in the gym sidecar (≈100ms/step, capped at the
    # 300-step PushT episode). 8000 → only 80 steps, too few to reach peak
    # coverage; 30000 → a full episode so the Verify gate sees the real outcome.
    #
    # skills.run_policy hands the rollout to the sidecar asynchronously and polls
    # to completion (each poll sub-10s), so it returns a real outcome — Reached
    # when the policy clears the solve threshold, Timeout otherwise — rather than
    # tripping the http client's ~10s ceiling. See skills.lex / client.lex.
    policy.run_policy(r, "lerobot/diffusion_pusht", "solve pusht", 30000)
  } else {
    skills.move_to(r, target)
  }
}

fn verify(o :: t.Outcome) -> StepLog {
  if is_reached(o) {
    { phase: "verify", ok: true, detail: "outcome reached" }
  } else {
    { phase: "verify", ok: false, detail: str.concat("gate denied: ", outcome_str(o)) }
  }
}

fn log_step(s :: StepLog) -> [io] Unit {
  let mark := if s.ok { "ok " } else { "FAIL" }
  io.print(str.join(["  [", mark, "] ", s.phase, " — ", s.detail], ""))
}

# One Perceive→Plan→Execute→Verify pass; threads the audit chain via `parent`.
fn attempt(r :: t.Robot, n :: Int, use_policy :: Bool, log :: tlog.Log, parent :: Str) -> [net, sense, actuate, io, sql, time] { ok :: Bool, parent :: Str } {
  let __h := io.print(str.join(["attempt ", int.to_str(n), ":"], ""))
  let p := perceive(r)
  let __1 := log_step(p)
  let e_p := trail(log, parent, "perceive", p.detail)
  if p.ok {
    let target := plan_target()
    let __2 := log_step({ phase: "plan", ok: true, detail: "target (0.5,0.5,0.2)" })
    let e_pl := trail(log, e_p, "plan", "target 0.5,0.5,0.2")
    let o := execute(r, target, use_policy)
    let __3 := log_step({ phase: "execute", ok: is_reached(o), detail: outcome_str(o) })
    let e_ex := trail(log, e_pl, "execute", outcome_str(o))
    let v := verify(o)
    let __4 := log_step(v)
    let e_v := trail(log, e_ex, "verify", v.detail)
    { ok: v.ok, parent: e_v }
  } else {
    { ok: false, parent: e_p }
  }
}

fn loop(r :: t.Robot, max :: Int, n :: Int, use_policy :: Bool, log :: tlog.Log, parent :: Str) -> [net, sense, actuate, io, sql, time] TaskResult {
  let a := attempt(r, n, use_policy, log, parent)
  if a.ok {
    { success: true, attempts: n, last_event: a.parent }
  } else {
    if n >= max {
      { success: false, attempts: n, last_event: a.parent }
    } else {
      loop(r, max, n + 1, use_policy, log, a.parent)
    }
  }
}

# Run the gated task, recording a hash-chained trail at `trail_path`.
fn run(r :: t.Robot, max_attempts :: Int, use_policy :: Bool, trail_path :: Str) -> [net, sense, actuate, io, sql, fs_write, time] TaskResult {
  match tlog.open(trail_path) {
    Err(e) => {
      let __e := io.print(str.concat("trail open failed: ", e))
      { success: false, attempts: 0, last_event: "" }
    },
    Ok(log) => match tlog.append(log, "task_started", None, "{}") {
      Err(e) => {
        let __e := io.print(str.concat("trail root failed: ", e))
        { success: false, attempts: 0, last_event: "" }
      },
      Ok(root) => loop(r, max_attempts, 1, use_policy, log, root.id),
    },
  }
}
