# examples/consent_verify.lex — verify a consent trail emitted by the consent
# gate (examples/consent_gate.lex). Reads the JSONL trail and replays it through
# lex-games' consent verifier to recompute whether every grant respected the
# policy — the server side of the loop: gate → trail → VERIFY. Compliance is
# recomputed from the rules, never trusted from whatever produced the receipt.
#
# Run: lex run --allow-effects io examples/consent_verify.lex verify '"consent_trail.jsonl"'

import "std.io" as io

import "std.str" as str

import "lex-games/src/arena/trail_file" as tf

import "lex-games/src/games/consent" as consent

fn verify(trail_path :: Str) -> [io] Int {
  match tf.read_jsonl(trail_path) {
    Err(e) => {
      let __lex_discard_1 := io.print(str.concat("{\"verified\":false,\"error\":\"", str.concat(e, "\"}")))
      1
    },
    Ok(lines) => {
      let v := consent.verdict(lines)
      let __lex_discard_2 := io.print(consent.verdict_json(v))
      if v.verified {
        0
      } else {
        1
      }
    },
  }
}

