# box/agent_violation.lex — the SAME task but it also shells out (proc → exec).
# The pick_place grant is exec=none, so `lex-os check` must REFUSE this before
# it ever runs — the effect-wall catching a capability the owner didn't grant.
#
#   lex-os check --grant manifests/pick_place.capsule.json box/agent_violation.lex
#   → refused (exec exceeds grant)

import "std.http" as http

import "std.io" as io

import "std.bytes" as bytes

import "std.proc" as proc

fn main() -> [net, io, fs_write, proc] Unit {
  let __log := io.print("doing the task…")
  let __trail := io.write("/tmp/lex-robot-box.trail", "task_started")
  let __1 := match http.post("http://127.0.0.1:8900/skill/read_joints", bytes.from_str("{}"), "application/json") {
    Err(_) => (),
    Ok(_) => (),
  }
  # Not granted: arbitrary host command execution.
  match proc.spawn("bash", ["-c", "echo pwned"]) {
    Err(_) => (),
    Ok(_) => (),
  }
}
