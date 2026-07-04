#!/usr/bin/env bash
# portable_reputation_run.sh — durable did:lex identity + portable reputation,
# end to end (platform kernel, #73).
#
#   own    → an agent is an ed25519 keypair; did:lex:agent:<name> is the handle,
#            the key is what makes it ownable (src/identity.lex)
#   earn   → the agent runs governed episodes in TWO apps (robot + agent-ops),
#            each producing a replay-verifiable trail
#   sign   → it SIGNS each submission (a claim binding did|app|game|trail-hash)
#   fold   → the registry (examples/agent_registry.lex) verifies the signature
#            AND replays the trail, crediting only when both hold — accumulating
#            ONE portable profile across both apps
#
# Also demonstrated: an impersonator submitting under the agent's did with a
# different key earns nothing, and a tampered trail breaks the signature.
#
# No network, no sidecar, no hardware — the identity + reputation layer of the
# kernel. Usage: LEX=lex ./examples/portable_reputation_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
ADID="did:lex:agent:atlas"
ATLAS_SEED="atlas-seed-0001"
MAL_SEED="mallory-seed-0001"

sign() { # <name> <seed> <app> <game> <trail> <seat> <won>  → signed entry JSON
  $LEX run --allow-effects io,crypto "$HERE/agent_registry.lex" sign \
    "\"$1\"" "\"$2\"" "\"$3\"" "\"$4\"" "\"$5\"" "\"$6\"" "\"$7\"" 2>/dev/null | grep '^{'
}
apply() { # <prior> <batch>  → registry JSON
  $LEX run --allow-effects io,crypto "$HERE/agent_registry.lex" apply "\"$1\"" "\"$2\"" 2>/dev/null | grep '^{'
}

# 1. atlas earns a verifiable trail in each of two apps.
EPISODE=efficient OPERATOR_DID="$ADID" ROBOT_TRAIL="$WORK/robot.jsonl" \
  $LEX run --allow-effects io,sql,time,fs_write,env "$HERE/robot_operator.lex" run >/dev/null 2>&1
AGENT_DID="$ADID" OPS_TRAIL="$WORK/ops.jsonl" \
  $LEX run --allow-effects io,sql,time,fs_write,env "$HERE/ops_gate.lex" run >/dev/null 2>&1

# 2. atlas signs both submissions; an impersonator signs the same did with its key.
E1="$(sign atlas "$ATLAS_SEED" robot     robot_task "$WORK/robot.jsonl" 0 false)"
E2="$(sign atlas "$ATLAS_SEED" agent-ops ops        "$WORK/ops.jsonl"   0 false)"
E3="$(sign atlas "$MAL_SEED"   robot     robot_task "$WORK/robot.jsonl" 0 false)"
printf '{"entries":[%s,%s,%s]}' "$E1" "$E2" "$E3" > "$WORK/batch.json"
REG="$(apply none.json "$WORK/batch.json")"

# 3. tamper: atlas's signed entry, pointed at an altered copy of the trail.
sed 's/reached/REACHED/' "$WORK/robot.jsonl" > "$WORK/robot_tampered.jsonl"
E1T="$(printf '%s' "$E1" | sed "s#$WORK/robot.jsonl#$WORK/robot_tampered.jsonl#")"
printf '{"entries":[%s]}' "$E1T" > "$WORK/tamper.json"
REGT="$(apply none.json "$WORK/tamper.json")"

python3 - "$REG" "$REGT" <<'PY'
import sys, json
reg, regt = json.loads(sys.argv[1]), json.loads(sys.argv[2])
p = reg["profiles"][0]
print("=== durable did:lex identity + portable reputation ===")
print(f'board: {p["did"]}  reputation={p["reputation"]}  sessions={p["sessions"]}  '
      f'apps={",".join(p["apps"])}  rejected={p["rejected"]}')
print(f'portable reputation: atlas earned in {len(p["apps"])} apps under one identity')
print(f'attribution proven: impersonation rejected={reg["rejected"]} (earns nothing)')
print(f'tamper-evident: tampered submission credited={regt["credited"]} '
      f'rejected={regt["rejected"]} (earns nothing)')
PY

rm -rf "$WORK"
