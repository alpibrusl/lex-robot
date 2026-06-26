#!/usr/bin/env bash
# refresh_boards.sh — regenerate the lobby's two live leaderboards from REAL runs,
# so play.lexlang.org reflects actual sessions instead of seed samples.
#
#   examples/sellers.json   ← governed bazaar sessions  → bazaar_season  (TOP SELLERS)
#   examples/standings.json ← N-player Bazaar matches    → nbazaar_season (MODEL LEADERBOARD)
#
# The sidecar serves those files at /api/sellers and /api/standings (see
# sidecar/sim_sidecar.lex), so writing them here updates both boards live.
# Intended to run on the arena box on a timer (cron / systemd) — e.g. every 15m:
#
#   */15 * * * *  cd /opt/lex-robot && LEX=lex scripts/refresh_boards.sh >> /var/log/boards.log 2>&1
#
# Self-contained + deterministic (heuristic bots, scripted market) so a cron run
# never needs an API key. Writes atomically (temp file → mv) so the sidecar never
# serves a half-written board.
set -u
LEX="${LEX:-lex}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EX="$ROOT/examples"
TARGET="${TARGET:-$EX}"
WORK="$(mktemp -d)"
trap 'pkill -f nplayer_bazaar 2>/dev/null; rm -rf "$WORK"' EXIT

write_atomic() { # <dest> ; json on stdin
  cat > "$WORK/.staged" && mv "$WORK/.staged" "$1" && echo "  wrote $1"
}

# ── TOP SELLERS: governed bazaar sessions → seller reputation ────────────────
echo "== refreshing sellers.json (governed bazaar sessions) =="
MKT="--allow-effects io,sql,time,net,crypto,fs_write,env"
BAZAAR_TRAIL="$WORK/s1.jsonl" $LEX run $MKT "$EX/bazaar_market.lex" run >/dev/null
BAZAAR_TRAIL="$WORK/s2.jsonl" $LEX run $MKT "$EX/bazaar_market.lex" run >/dev/null
printf '[{"trail":"%s"},{"trail":"%s"}]' "$WORK/s1.jsonl" "$WORK/s2.jsonl" > "$WORK/sessions.json"
if sellers="$($LEX run --allow-effects io "$EX/bazaar_rank.lex" rank "\"$WORK/sessions.json\"" | grep '^{')"; then
  printf '%s\n' "$sellers" | write_atomic "$TARGET/sellers.json"
else
  echo "  (skipped sellers.json — rank failed)"
fi

# ── MODEL LEADERBOARD: N-player Bazaar matches → ELO standings ───────────────
echo "== refreshing standings.json (N-player Bazaar matches) =="
play_match() { # <port> <seats> <trail> <strat...>
  local port="$1" seats="$2" trail="$3"; shift 3
  pkill -f nplayer_bazaar 2>/dev/null; sleep 1
  NB_SEATS="$seats" NB_PORT="$port" NB_TRAIL="$trail" \
    $LEX run --allow-effects env,net,concurrent,io,fs_write "$EX/nplayer_bazaar.lex" run >"$WORK/ref-$port.log" 2>&1 &
  local ref=$!
  for _ in $(seq 1 40); do grep -q "referee on" "$WORK/ref-$port.log" 2>/dev/null && break; sleep 0.3; done
  for strat in "$@"; do
    BOT_STRAT="$strat" NB_PORT="$port" $LEX run --allow-effects env,net,concurrent,io "$EX/nplayer_bazaar_bot.lex" run >/dev/null 2>&1 &
    sleep 0.4
  done
  for _ in $(seq 1 60); do [ -s "$trail" ] && break; sleep 0.5; done
  sleep 1; kill $ref 2>/dev/null; pkill -f nplayer_bazaar 2>/dev/null
}
play_match 8902 3 "$WORK/m1.jsonl" 0 1 0
play_match 8903 2 "$WORK/m2.jsonl" 0 1
if [ -s "$WORK/m1.jsonl" ] && [ -s "$WORK/m2.jsonl" ]; then
  cat > "$WORK/round1.json" <<JSON
[ { "trail": "$WORK/m1.jsonl", "seats": ["greedy","ratio","greedy-2"] } ]
JSON
  cat > "$WORK/round2.json" <<JSON
[ { "trail": "$WORK/m2.jsonl", "seats": ["greedy","ratio"] } ]
JSON
  $LEX run --allow-effects io "$EX/nbazaar_rank.lex" rank "\"$WORK/none.json\"" "\"$WORK/round1.json\"" | grep '^{' > "$WORK/s1board.json"
  if standings="$($LEX run --allow-effects io "$EX/nbazaar_rank.lex" rank "\"$WORK/s1board.json\"" "\"$WORK/round2.json\"" | grep '^{')"; then
    printf '%s\n' "$standings" | write_atomic "$TARGET/standings.json"
  else
    echo "  (skipped standings.json — season failed)"
  fi
else
  echo "  (skipped standings.json — a match produced no trail)"
fi

echo "done."
