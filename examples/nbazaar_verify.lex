# examples/nbazaar_verify.lex — verify a match trail emitted by the N-player
# Bazaar referee (examples/nplayer_bazaar.lex). Reads the JSONL trail and replays
# it through the lex-games nbazaar referee to recompute the per-seat scores — the
# server side of the loop: play → trail → VERIFY → rank. The score is recomputed
# by the rules, never trusted from whatever produced the trail.
#
# Run: lex run --allow-effects io examples/nbazaar_verify.lex verify '"nbazaar_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "lex-games/src/arena/trail_file" as tf

import "lex-games/src/games/nbazaar" as nb

fn verify(trail_path :: Str) -> [io] Int {
  match tf.read_jsonl(trail_path) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("{\"verified\":false,\"error\":\"", str.concat(e, "\"}")))
      1
    },
    Ok(lines) => {
      let v := nb.verdict(lines)
      let __lex_discard_2 := io.print(nb.verdict_json(v))
      if v.verified {
        0
      } else {
        1
      }
    },
  }
}

