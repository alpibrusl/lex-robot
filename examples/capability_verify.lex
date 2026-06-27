# examples/capability_verify.lex — verify a capability trail emitted by the
# unified gate (examples/capability_gate.lex). Replays the mixed data+money trail
# through lex-games' capability verifier to recompute that the one token was
# respected on BOTH halves — the server side of the loop: gate → trail → VERIFY.
#
# Run: lex run --allow-effects io examples/capability_verify.lex verify '"capability_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "lex-games/src/arena/trail_file" as tf

import "lex-games/src/games/capability" as cap

fn verify(trail_path :: Str) -> [io] Int {
  match tf.read_jsonl(trail_path) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("{\"verified\":false,\"error\":\"", str.concat(e, "\"}")))
      1
    },
    Ok(lines) => {
      let v := cap.verdict(lines)
      let __lex_discard_2 := io.print(cap.verdict_json(v))
      if v.verified {
        0
      } else {
        1
      }
    },
  }
}

