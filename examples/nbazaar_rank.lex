# examples/nbazaar_rank.lex — rank models across N-player Bazaar matches by ELO.
# A thin wrapper over the lex-games nbazaar season: it reads prior standings + a
# manifest of match trails (each {trail, seats:[model,...]}), replays every trail
# to recompute verified scores, folds each match as one ELO round, and prints the
# new standings — the last step of the loop: play → trail → verify → RANK.
#
# Chain rounds by feeding the previous standings back in:
#   lex run --allow-effects io examples/nbazaar_rank.lex rank '"none.json"' '"round1.json"' > s1.json
#   lex run --allow-effects io examples/nbazaar_rank.lex rank '"s1.json"'   '"round2.json"' > standings.json

import "lex-games/src/arena/nbazaar_season" as season

fn rank(standings_path :: Str, manifest_path :: Str) -> [io] Int {
  season.run(standings_path, manifest_path)
}

