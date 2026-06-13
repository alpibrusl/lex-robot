# box/agent_ok.lex — a self-contained "agent program" representing what runs
# inside the lex-os box for the pick-place task. Its effect row
# ([net, io, fs_write]) stays within the pick_place grant
# (net=allowlist, fs=read-write, exec=none), so `lex-os check` admits it.
#
#   lex-os check --grant manifests/pick_place.capsule.json box/agent_ok.lex

import "std.http" as http

import "std.io" as io

import "std.bytes" as bytes

# Representative perimeter-relevant work: talk to the sidecar (net), write the
# trail (fs_write), log (io). No exec/proc — matches exec=none.
fn main() -> [net, io, fs_write] Unit {
  let __log := io.print("perceive → plan → execute → verify")
  let __trail := io.write("/tmp/lex-robot-box.trail", "task_started")
  match http.post("http://127.0.0.1:8900/skill/read_joints", bytes.from_str("{}"), "application/json") {
    Err(_) => (),
    Ok(_) => (),
  }
}
