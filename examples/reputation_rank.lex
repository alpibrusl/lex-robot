# examples/reputation_rank.lex — accumulate agent reputation, keyed by did:lex.
# A thin wrapper over lex-games' reputation registry: it reads a prior registry +
# a batch of session results (each {did, score, verified, won}) and folds the
# VERIFIED ones into per-DID trustMetrics, carried forward across rounds. The
# batch is produced by replaying real sessions through the verifiers — so an
# agent's reputation traces to verified work, never to a claim.
#
# Run: lex run --allow-effects io examples/reputation_rank.lex rank '"registry.json"' '"batch.json"'

import "lex-games/src/arena/reputation" as rep

fn rank(registry_path :: Str, batch_path :: Str) -> [io] Int {
  rep.run(registry_path, batch_path)
}

