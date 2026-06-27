# examples/ops_verify.lex — verify an agent-ops trail emitted by the ops gate
# (examples/ops_gate.lex). Replays the tool-use run through lex-games' ops
# verifier to recompute that the agent stayed in its authority — the server side
# of the loop: gate → trail → VERIFY. A clean verdict is what would earn the
# agent operator reputation in the did:lex registry.
#
# Run: lex run --allow-effects io examples/ops_verify.lex verify '"ops_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "lex-games/src/arena/trail_file" as tf

import "lex-games/src/games/ops" as ops

fn verify(trail_path :: Str) -> [io] Int {
  match tf.read_jsonl(trail_path) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("{\"verified\":false,\"error\":\"", str.concat(e, "\"}")))
      1
    },
    Ok(lines) => {
      let v := ops.verdict(lines)
      let __lex_discard_2 := io.print(ops.verdict_json(v))
      if v.verified {
        0
      } else {
        1
      }
    },
  }
}

