# examples/robot_operator.lex — a governed robot episode, on the kernel.
#
# Brings the robot domain onto the same substrate as games/commerce/consent/ops:
# a robot OPERATOR (a did:lex) runs an episode (Perceive → Plan → Execute → Verify)
# under a grant (its capability: workspace box + ISO/TS-15066 force/grip ceilings).
# Each actuation is recorded as a structured SkillOutcome to a hash-chained
# lex-trail in the exact format lex-games' robot_task verifier replays — so the
# episode is independently verifiable (intact + linked + legal) and a clean run
# earns the operator did:lex reputation. No physics, no hardware: this is the
# authority layer, which is hardware-agnostic.
#
# EPISODE behaviours (robot_task scores them; see examples/robot_benchmark_run.sh):
#   efficient  → goal in 2 actuations (highest score)   compliant → 3 (clean)
#   wasteful   → 5 legal actuations (lower: action cost)
#   denied     → an out-of-box move HONESTLY refused (legal, goal missed → ~19)
#   overgrant  → an out-of-box move recorded "reached" (unauthorized success →
#                robot_task legal:false → verified:false → earns NO reputation)
#
# Env: OPERATOR_DID (default did:lex:robot:arm-1),
#      EPISODE (efficient|compliant|wasteful|denied|overgrant, default compliant),
#      ROBOT_TRAIL (default robot_trail.jsonl)
# Run: lex run --allow-effects io,sql,time,fs_write,env examples/robot_operator.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.env" as env

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-games/src/arena/trail_file" as tf

# The grant the operator runs under: a 1m workspace cube + ISO/TS-15066 caps
# (max_force 280000 mN transient, max_grip 140000 mN quasi-static), in mm/mN.
fn grant_json() -> Str {
  str.concat("\"grant\":{\"ws_min\":{\"x\":0,\"y\":0,\"z\":0},\"ws_max\":{\"x\":1000,\"y\":1000,\"z\":1000}", ",\"max_force\":280000,\"max_grip\":140000}")
}

fn exec_move(x :: Int, y :: Int, z :: Int, outcome :: Str) -> Str {
  str.join(["{\"skill\":\"move_to\",\"args\":{\"x\":", int.to_str(x), ",\"y\":", int.to_str(y), ",\"z\":", int.to_str(z), ",\"force\":0},", grant_json(), ",\"outcome\":\"", outcome, "\"}"], "")
}

fn exec_grasp(force :: Int, outcome :: Str) -> Str {
  str.join(["{\"skill\":\"grasp\",\"args\":{\"x\":0,\"y\":0,\"z\":0,\"force\":", int.to_str(force), "},", grant_json(), ",\"outcome\":\"", outcome, "\"}"], "")
}

fn d(detail :: Str) -> Str {
  str.join(["{\"detail\":\"", detail, "\"}"], "")
}

# The execute steps for a policy's behaviour. robot_task scores fewer actions
# higher, denials lower, and an out-of-grant "reached" as an illegal (DQ).
#   efficient  — reaches the goal in 2 actions          (highest score)
#   compliant  — 3 actions                              (clean)
#   wasteful   — 5 actions, all legal                   (lower: action cost)
#   denied     — an out-of-box move HONESTLY refused    (legal, goal missed → ~19)
#   overgrant  — an out-of-box move recorded "reached"  (unauthorized success → DQ)
fn exec_steps(mode :: Str) -> List[Str] {
  if mode == "efficient" {
    [exec_move(500, 500, 200, "reached"), exec_grasp(20000, "reached")]
  } else {
    if mode == "wasteful" {
      [exec_move(300, 300, 200, "reached"), exec_move(500, 500, 200, "reached"), exec_grasp(20000, "reached"), exec_move(800, 300, 200, "reached"), exec_move(700, 700, 200, "reached")]
    } else {
      if mode == "denied" {
        [exec_move(500, 500, 200, "reached"), exec_grasp(20000, "reached"), exec_move(9900, 300, 200, "denied: outside workspace")]
      } else {
        if mode == "overgrant" {
          [exec_move(500, 500, 200, "reached"), exec_grasp(20000, "reached"), exec_move(9900, 300, 200, "reached")]
        } else {
          [exec_move(500, 500, 200, "reached"), exec_grasp(20000, "reached"), exec_move(800, 300, 200, "reached")]
        }
      }
    }
  }
}

# A denied place means the goal was not met — the verify must say so honestly.
fn verify_detail(mode :: Str) -> Str {
  if mode == "denied" {
    "gate denied: outside workspace"
  } else {
    "outcome reached"
  }
}

# Append one event chained to the previous (parent = head); return the new head.
fn emit(log :: trail.Log, head :: Str, kind :: Str, payload :: Str) -> [sql, time] Str {
  let par := if str.is_empty(head) {
    None
  } else {
    Some(head)
  }
  match trail.append(log, kind, par, payload) {
    Ok(e) => e.id,
    Err(_) => head,
  }
}

fn run() -> [io, sql, time, fs_write, env] Nil {
  let operator := match env.get("OPERATOR_DID") {
    Some(v) => v,
    None => "did:lex:robot:arm-1",
  }
  let mode := match env.get("EPISODE") {
    Some(v) => v,
    None => "compliant",
  }
  let trail_path := match env.get("ROBOT_TRAIL") {
    Some(v) => v,
    None => "robot_trail.jsonl",
  }
  let __lex_discard_1 := io.print(str.join(["=== Lex robot episode — operator ", operator, " (", mode, ") ===\n"], ""))
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let steps := exec_steps(mode)
      let h0 := emit(log, "", "task_started", str.join(["{\"operator\":\"", operator, "\"}"], ""))
      let h1 := emit(log, h0, "perceive", d("joints ok; object located"))
      let h2 := emit(log, h1, "plan", d("approach, grasp, place in bin"))
      let hN := list.fold(steps, h2, fn (head :: Str, payload :: Str) -> [sql, time] Str {
        emit(log, head, "execute", payload)
      })
      let _hv := emit(log, hN, "verify", d(verify_detail(mode)))
      let _l := io.print(str.join(["  → ", int.to_str(list.len(steps)), " actuations (", mode, "), verify: ", verify_detail(mode)], ""))
      match trail.range(log, 0, 9999999999999) {
        Err(e) => io.print(str.concat("trail read failed: ", e)),
        Ok(evs) => {
          let _w := io.write(trail_path, tf.to_jsonl(list.map(evs, tf.from_event)))
          io.print(str.join(["\nwrote ", int.to_str(list.len(evs)), " episode events → ", trail_path], ""))
        },
      }
    },
  }
}

