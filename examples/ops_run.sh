#!/usr/bin/env bash
# ops_run.sh — governed agent operations, end to end:
#
#   act    → a did:lex agent runs a tool-use task under a capability that bounds
#            which tools it may call (allow/deny) and a call budget; forbidden or
#            over-budget calls are refused, all attested to a hash-chained trail
#   verify → replay the run through lex-games' ops verifier — recompute that no
#            rogue tool ran and the budget held (audit, not trust)
#
# The "auditable agent ops" use case on the one substrate; a clean verdict is
# what earns the agent operator reputation (see examples/reputation_run.sh).
#
# Usage: LEX=lex ./examples/ops_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TRAIL="${OPS_TRAIL:-$(mktemp -d)/ops_trail.jsonl}"

echo "== act: agent runs a task under a tool-use capability =="
OPS_TRAIL="$TRAIL" $LEX run --allow-effects io,sql,time,fs_write,env "$HERE/ops_gate.lex" run

echo
echo "== verify: replay the run, recompute it stayed in-bounds =="
$LEX run --allow-effects io "$HERE/ops_verify.lex" verify "\"$TRAIL\"" | head -1

echo
echo "trail at: $TRAIL"
