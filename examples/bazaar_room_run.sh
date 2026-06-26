#!/usr/bin/env bash
# bazaar_room_run.sh — a live WebSocket bazaar: a contention-arbiter room + three
# remote buyer agents racing for scarce inventory, each governing its own spend.
#
#   room    → examples/bazaar_room.lex arbitrates who reserves each scarce item
#   buyers  → alice/bob/carol dial in and compete; each settles its OWN purchases
#             against its OWN budget token, writing its OWN trail
#   verify  → replay each buyer's trail (gbazaar) + aggregate seller reputation
#
# Usage: LEX=lex ./examples/bazaar_room_run.sh
set -u
LEX="${LEX:-lex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${NB_PORT:-8910}"
DIR="$(mktemp -d)"
ROOM="--allow-effects env,net,concurrent,io"
BUYER="--allow-effects concurrent,crypto,env,fs_write,io,net,sql,time"

pkill -f bazaar_room 2>/dev/null; sleep 1
if lsof -i ":$PORT" >/dev/null 2>&1; then echo "port $PORT busy" >&2; exit 1; fi

echo "== room: contention arbiter on :$PORT =="
NB_PORT="$PORT" $LEX run $ROOM "$HERE/bazaar_room.lex" run >"$DIR/room.log" 2>&1 &
ROOM_PID=$!
trap 'kill $ROOM_PID 2>/dev/null; pkill -f bazaar_room 2>/dev/null' EXIT
for _ in $(seq 1 40); do grep -q "arbiter on" "$DIR/room.log" 2>/dev/null && break; sleep 0.3; done

echo "== buyers: alice / bob / carol race in =="
for who in alice bob carol; do
  BUYER_ID="$who" NB_PORT="$PORT" BAZAAR_DIR="$DIR" $LEX run $BUYER "$HERE/bazaar_room_buyer.lex" run >"$DIR/$who.log" 2>&1 &
  sleep 0.5
done

# let the race play out, then read the room transcript
sleep 6
echo
echo "-- room transcript --"; grep "\[room\]" "$DIR/room.log"
echo
echo "-- per-buyer --"; for who in alice bob carol; do grep -E "won \+ paid|DENIED|item .*: (SOLD|RELEASED)|left the bazaar" "$DIR/$who.log" | sed "s/^/  /"; done
kill $ROOM_PID 2>/dev/null; pkill -f bazaar_room 2>/dev/null; sleep 1

echo
echo "== verify each buyer's governed trail =="
for f in "$DIR"/bazaar_*.jsonl; do
  printf "  %s: " "$(basename "$f" .jsonl)"
  $LEX run --allow-effects io "$HERE/bazaar_verify.lex" verify "\"$f\"" | grep -oE '"(verified|compliant|settled|approved)":(true|false|[0-9]+)' | tr '\n' ' '; echo
done

echo
echo "== seller reputation across all buyers =="
printf '[' > "$DIR/sessions.json"
first=1; for f in "$DIR"/bazaar_*.jsonl; do [ $first = 1 ] || printf ',' >> "$DIR/sessions.json"; printf '{"trail":"%s"}' "$f" >> "$DIR/sessions.json"; first=0; done
printf ']' >> "$DIR/sessions.json"
$LEX run --allow-effects io "$HERE/bazaar_rank.lex" rank "\"$DIR/sessions.json\"" | grep '^{'

echo
echo "trails in: $DIR"
