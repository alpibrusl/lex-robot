# examples/bazaar_verify.lex — verify a governed-bazaar spend trail emitted by
# examples/bazaar_market.lex. Reads the JSONL trail and replays it through the
# lex-games gbazaar verifier to recompute whether every settlement respected the
# budget — the server side of the loop: transact → trail → VERIFY. Compliance is
# recomputed from the rules, never trusted from whatever produced the trail.
#
# Run: lex run --allow-effects io examples/bazaar_verify.lex verify '"bazaar_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "lex-games/src/arena/trail_file" as tf

import "lex-games/src/games/gbazaar" as gb

fn verify(trail_path :: Str) -> [io] Int {
  match tf.read_jsonl(trail_path) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("{\"verified\":false,\"error\":\"", str.concat(e, "\"}")))
      1
    },
    Ok(lines) => {
      let v := gb.verdict(lines)
      let __lex_discard_2 := io.print(gb.verdict_json(v))
      if v.verified {
        0
      } else {
        1
      }
    },
  }
}

