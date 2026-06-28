# examples/govern_commands.lex — the grant gate, deciding what reaches the sim.
#
# Tier 2 of the robot kernel (epic #63, issue #66): make the grant PHYSICALLY
# meaningful. A policy proposes raw commands; this applies the grant — clamp the
# grasp force to the grip ceiling, block a move whose target leaves the workspace
# box — and writes (a) the GOVERNED commands the MuJoCo harness actually executes
# and (b) a robot_task-format trail of the governed episode. The MuJoCo run then
# measures the difference vs the ungoverned raw commands: clamped contact force,
# and an end-effector that never enters the keep-out region.
#
# Same semantics as src/grant.lex (clamp_grip + in_workspace); in integer
# milli-units (mm / mN) so the trail is robot_task-ready and there is no float
# JSON. The Python harness converts mm→m, mN→N for physics.
#
# Run: lex run --allow-effects io,sql,time,fs_write \
#        examples/govern_commands.lex govern '"raw.json"' '"governed.json"' '"trail.jsonl"'

import "std.io" as io
import "std.str" as str
import "std.int" as int
import "std.json" as json
import "std.list" as list

import "lex-trail/log" as trail

import "lex-games/src/arena/trail_file" as tf

# The grant's physical envelope for this scene (mirrors src/grant.lex):
fn ws_max_x_mm() -> Int { 1000 }      # workspace edge at 1.0 m; beyond = keep-out
fn grip_cap_mn() -> Int { 20000 }     # grip ceiling 20 N (ISO-style clamp)

# A raw policy proposal.
type Raw = { target_x_mm :: Int, grasp_force_mn :: Int }

fn grant_json() -> Str {
  str.concat("\"grant\":{\"ws_min\":{\"x\":0,\"y\":0,\"z\":0},\"ws_max\":{\"x\":1000,\"y\":1000,\"z\":1000}",
             ",\"max_force\":280000,\"max_grip\":20000}")
}
fn exec_move(x :: Int, outcome :: Str) -> Str {
  str.join(["{\"skill\":\"move_to\",\"args\":{\"x\":", int.to_str(x), ",\"y\":0,\"z\":0,\"force\":0},", grant_json(), ",\"outcome\":\"", outcome, "\"}"], "")
}
fn exec_grasp(force :: Int, outcome :: Str) -> Str {
  str.join(["{\"skill\":\"grasp\",\"args\":{\"x\":0,\"y\":0,\"z\":0,\"force\":", int.to_str(force), "},", grant_json(), ",\"outcome\":\"", outcome, "\"}"], "")
}
fn d(s :: Str) -> Str { str.join(["{\"detail\":\"", s, "\"}"], "") }
fn emit(log :: trail.Log, head :: Str, kind :: Str, payload :: Str) -> [sql, time] Str {
  let par := if str.is_empty(head) { None } else { Some(head) }
  match trail.append(log, kind, par, payload) { Ok(e) => e.id, Err(_) => head }
}

fn govern(raw_path :: Str, governed_path :: Str, trail_path :: Str) -> [io, sql, time, fs_write] Int {
  match io.read(raw_path) {
    Err(e) => { let _ := io.print(str.concat("cannot read raw: ", e)) 1 },
    Ok(content) => {
      let parsed :: Result[Raw, Str] := json.parse(content)
      match parsed {
        Err(e) => { let _ := io.print(str.concat("bad raw json: ", e)) 1 },
        Ok(r) => {
          let blocked := r.target_x_mm > ws_max_x_mm()
          let safe_x := if blocked { ws_max_x_mm() } else { r.target_x_mm }
          let clamped := if r.grasp_force_mn > grip_cap_mn() { grip_cap_mn() } else { r.grasp_force_mn }
          # (a) the governed commands the simulator will execute
          let gov := str.join(["{\"target_x_mm\":", int.to_str(safe_x), ",\"blocked\":", if blocked { "true" } else { "false" }, ",\"grasp_force_mn\":", int.to_str(clamped), "}"], "")
          let _w := io.write(governed_path, gov)
          let _p := io.print(str.join(["governed: move→", int.to_str(safe_x), "mm", if blocked { " (BLOCKED: requested " } else { " (" }, int.to_str(r.target_x_mm), "mm); grasp→", int.to_str(clamped), "mN (requested ", int.to_str(r.grasp_force_mn), ")"], ""))
          # (b) the robot_task trail of the governed episode
          match trail.open_memory() {
            Err(e) => { let _ := io.print(str.concat("trail open failed: ", e)) 1 },
            Ok(log) => {
              let move_out := if blocked { "denied: outside workspace" } else { "reached" }
              let h0 := emit(log, "", "task_started", d("physics episode"))
              let h1 := emit(log, h0, "perceive", d("object at target"))
              let h2 := emit(log, h1, "plan", d("move then grasp"))
              let h3 := emit(log, h2, "execute", exec_move(r.target_x_mm, move_out))
              let h4 := emit(log, h3, "execute", exec_grasp(clamped, "reached"))
              let _h5 := emit(log, h4, "verify", d(if blocked { "gate denied: outside workspace" } else { "outcome reached" }))
              match trail.range(log, 0, 9999999999999) {
                Err(e) => { let _ := io.print(str.concat("trail read failed: ", e)) 1 },
                Ok(evs) => { let _t := io.write(trail_path, tf.to_jsonl(list.map(evs, tf.from_event))) 0 },
              }
            },
          }
        },
      }
    },
  }
}
