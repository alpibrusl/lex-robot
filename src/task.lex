# lex-robot/task.lex — evidence-gated task graph (the lex-loom pattern).
#
# Perceive → Plan → Execute → Verify, with a hard gate at Verify: a task is
# only "done" when a real post-condition (sensor / outcome) confirms it.
# Failure loops back (bounded retries), mirroring lex-loom's gated pipeline —
# self-contained here (no DB / orchestrator) so it runs against any sidecar.

import "std.str" as str

import "std.io" as io

import "std.int" as int

import "./types" as t

import "./skills" as skills

type StepLog = { phase :: Str, ok :: Bool, detail :: Str }

type TaskResult = { success :: Bool, attempts :: Int, log :: List[StepLog] }

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

# ── Phase 1: Perceive — confirm the robot is responsive (real sensor read). ──
fn perceive(r :: t.Robot) -> [net] StepLog {
  match skills.read_joints(r) {
    Err(e) => { phase: "perceive", ok: false, detail: e },
    Ok(s) => { phase: "perceive", ok: true, detail: s },
  }
}

# ── Phase 2: Plan — choose a target/strategy. Pure (judgment, no actuation). ──
# A real planner (lex-llm) would decide here; the scaffold uses a fixed target.
fn plan_target() -> t.Pose {
  { pos: { x: 0.5, y: 0.5, z: 0.2 }, rx: 0.0, ry: 0.0, rz: 0.0 }
}

# ── Phase 3: Execute — actuate via a grant-gated skill. ──────────────────────
fn execute(r :: t.Robot, target :: t.Pose) -> [net] t.Outcome {
  skills.move_to(r, target)
}

# ── Phase 4: Verify — the gate. Only pass on a confirmed outcome. ────────────
fn verify(r :: t.Robot, o :: t.Outcome) -> StepLog {
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

# One Perceive→Plan→Execute→Verify pass.
fn attempt(r :: t.Robot, n :: Int) -> [net, io] TaskResult {
  let __h := io.print(str.join(["attempt ", int.to_str(n), ":"], ""))
  let p := perceive(r)
  let __1 := log_step(p)
  if p.ok {
    let target := plan_target()
    let __pl := log_step({ phase: "plan", ok: true, detail: "target (0.5,0.5,0.2)" })
    let o := execute(r, target)
    let __ex := log_step({ phase: "execute", ok: is_reached(o), detail: outcome_str(o) })
    let v := verify(r, o)
    let __v := log_step(v)
    { success: v.ok, attempts: n, log: [p, v] }
  } else {
    { success: false, attempts: n, log: [p] }
  }
}

# Run the gated task with bounded retries.
fn run_task(r :: t.Robot, max_attempts :: Int, n :: Int) -> [net, io] TaskResult {
  let res := attempt(r, n)
  if res.success {
    res
  } else {
    if n >= max_attempts {
      res
    } else {
      run_task(r, max_attempts, n + 1)
    }
  }
}

fn run(r :: t.Robot, max_attempts :: Int) -> [net, io] TaskResult {
  run_task(r, max_attempts, 1)
}
