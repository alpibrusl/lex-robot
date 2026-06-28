# examples/robot_verify.lex — verify a robot episode trail emitted by the robot
# operator (examples/robot_operator.lex). Replays it through lex-games' robot_task
# verifier to recompute integrity + linkage + grant-legality + the score — the
# server side of the loop: act → trail → VERIFY. A verified, legal episode is what
# earns the operator did:lex reputation.
#
# Run: lex run --allow-effects io examples/robot_verify.lex verify '"robot_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "lex-games/src/arena/trail_file" as tf

import "lex-games/src/games/robot_task" as rt

fn verify(trail_path :: Str) -> [io] Int {
  match tf.read_jsonl(trail_path) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("{\"verified\":false,\"error\":\"", str.concat(e, "\"}")))
      1
    },
    Ok(lines) => {
      let v := rt.verdict(lines)
      let __lex_discard_2 := io.print(rt.verdict_json(v))
      if v.verified {
        0
      } else {
        1
      }
    },
  }
}

