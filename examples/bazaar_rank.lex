# examples/bazaar_rank.lex — rank sellers by verified reputation across governed
# bazaar sessions. A thin wrapper over the lex-games bazaar_season aggregator: it
# reads a manifest of session spend trails, replays each through the gbazaar
# verifier, and accumulates per-seller revenue/deals from the sessions that
# verify (a tampered/non-compliant session is void). Prints the seller board —
# the last step of the commerce loop: transact → trail → verify → RANK.
#
# Run: lex run --allow-effects io examples/bazaar_rank.lex rank '"sessions.json"'

import "lex-games/src/arena/bazaar_season" as season

fn rank(manifest_path :: Str) -> [io] Int {
  season.run(manifest_path)
}
