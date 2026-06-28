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
# EPISODE=compliant  → every move stays in the workspace box → legal, goal met.
# EPISODE=overgrant  → a move OUTSIDE the box is recorded "reached" (an
#                      unauthorized success) → robot_task marks it legal:false →
#                      verified:false → it earns NO reputation.
#
# Env: OPERATOR_DID (default did:lex:robot:arm-1), EPISODE (compliant|overgrant),
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
      let place := if mode == "overgrant" {
        exec_move(9900, 300, 200, "reached")
      } else {
        exec_move(800, 300, 200, "reached")
      }
      let h0 := emit(log, "", "task_started", str.join(["{\"operator\":\"", operator, "\"}"], ""))
      let h1 := emit(log, h0, "perceive", d("joints ok; object located"))
      let h2 := emit(log, h1, "plan", d("approach, grasp, place in bin"))
      let h3 := emit(log, h2, "execute", exec_move(500, 500, 200, "reached"))
      let _l3 := io.print("  → move_to (500,500,200) — reached")
      let h4 := emit(log, h3, "execute", exec_grasp(20000, "reached"))
      let _l4 := io.print("  → grasp 20000 mN (≤ 140000 grip cap) — reached")
      let h5 := emit(log, h4, "execute", place)
      let _l5 := io.print(if mode == "overgrant" {
        "  → move_to (9900,300,200) OUTSIDE the workspace — recorded reached (unauthorized!)"
      } else {
        "  → move_to (800,300,200) — reached"
      })
      let _h6 := emit(log, h5, "verify", d("outcome reached"))
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

