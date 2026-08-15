#!/usr/bin/env bash
# scripts/llm_planner_mock_test.sh — real end-to-end verification of
# src/llm_planner.lex's tool-dispatch path, with NO LLM API key and NO
# network access to an LLM provider required.
#
# tests/test_llm_planner.lex substitutes a scripted mock Provider (a
# Provider is just `{ name, chat }` — a genuine substitution of the same
# interface lex-llm's real OpenAI/Anthropic/etc. adapters implement, not a
# special test-only code path) that proposes move_base then speak. Both
# calls go over a REAL HTTP tasks/send round-trip into a REAL, live
# a2a_robot_server process — the actual grant (from examples/a2a_robot_demo.lex:
# move_base granted and in-bounds, speak NOT granted) decides allow/deny,
# not a stand-in. This proves the entire loop (agent construction, tool
# wrapping, wire encoding/decoding, run_loop's turn-taking) end to end.
#
# What this does NOT verify, and what stays honestly open without a real
# OpenCode API key: whether a real hosted model reliably chooses the right
# tool for an English sentence. That's `make xlerobot-llm` (needs
# OPENCODE_API_KEY), out-of-band like this repo's other ML-dependent demos.
#
# Usage: bash scripts/llm_planner_mock_test.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

TRAIL_DB=/tmp/lex-robot-a2a-trail.db
LEDGER_DB=/tmp/lex-robot-a2a-ledger.db
rm -f "$TRAIL_DB" "$LEDGER_DB"   # a stale ledger's wall-clock budget would spuriously kill this run

command -v "$LEX" >/dev/null || { echo "error: 'lex' not on PATH — see README Install" >&2; exit 1; }

python3 sidecar/xlerobot_sidecar.py >/tmp/lex-robot-llm-mock-sidecar.log 2>&1 &
SIDECAR_PID=$!
"$LEX" run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate,approval \
  examples/a2a_robot_demo.lex run >/tmp/lex-robot-llm-mock-a2a.log 2>&1 &
A2A_PID=$!
cleanup() { kill "$SIDECAR_PID" "$A2A_PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 50); do
  curl -sf http://127.0.0.1:8900/health >/dev/null 2>&1 && break
  sleep 0.2
done
for _ in $(seq 1 50); do
  curl -sf http://127.0.0.1:8766/.well-known/agent.json >/dev/null 2>&1 && break
  sleep 0.2
done

OUT="$("$LEX" run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate,stream,approval \
  tests/test_llm_planner.lex main 2>&1)"
echo "$OUT"
echo "$OUT" | grep -q "^ALL PASS:"
