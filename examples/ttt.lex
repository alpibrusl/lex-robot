# examples/ttt.lex — tic-tac-toe on the lex-games harness.
#
# Proves the Lex-native game thesis in one match:
#   • CHEAT-RESISTANT  — a player controls exactly one side; a move claiming the
#       other side, or made out of turn, is REFUSED by lex_games.gate before any
#       board logic runs (capability enforcement, not a runtime if-check bolted on).
#   • VERIFIABLE       — every applied move is appended to a hash-chained lex-trail
#       log (tamper-evident, replayable match record).
#   • AGENT-PLAYABLE   — side O is played by a bot; a human (or another agent)
#       plays X. Both submit through the same gated path.
#
# This slice scripts X's moves (incl. two cheat attempts) and lets a bot play O,
# to demonstrate the engine headlessly. The interactive client is the next step.
#
# Env: TTT_DASH_URL (optional dashboard for visualisation)
# Run: lex run --allow-effects env,fs_write,io,net,sql,time examples/ttt.lex run

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.list"  as list
import "std.bytes" as bytes
import "std.http"  as http
import "std.map"   as map
import "std.time"  as time

import "lex-games/src/lex_games" as game
import "lex-trail/log"    as trail

# ── board (9 chars, '.' = empty) ─────────────────────────────────────────────
fn cell(b :: Str, i :: Int) -> Str { str.slice(b, i, i + 1) }
fn set_cell(b :: Str, i :: Int, c :: Str) -> Str { str.concat(str.slice(b, 0, i), str.concat(c, str.slice(b, i + 1, 9))) }
fn empty_at(b :: Str, i :: Int) -> Bool { cell(b, i) == "." }

fn line3(b :: Str, a :: Int, c :: Int, d :: Int) -> Str {
  let x := cell(b, a)
  if x != "." and cell(b, c) == x and cell(b, d) == x { x } else { "" }
}
fn winner(b :: Str) -> Str {
  let lines := [line3(b,0,1,2), line3(b,3,4,5), line3(b,6,7,8), line3(b,0,3,6), line3(b,1,4,7), line3(b,2,5,8), line3(b,0,4,8), line3(b,2,4,6)]
  list.fold(lines, "", fn (acc :: Str, w :: Str) -> Str { if str.is_empty(acc) { w } else { acc } })
}
fn bot_pick(b :: Str) -> Int {
  list.fold([0,1,2,3,4,5,6,7,8], -1, fn (acc :: Int, i :: Int) -> Int { if acc >= 0 { acc } else { if empty_at(b, i) { i } else { acc } } })
}

# ── dashboard ────────────────────────────────────────────────────────────────
fn notify(dash :: Str, json :: Str) -> [net] Unit {
  if str.is_empty(dash) { () } else {
    let req := http.with_header(http.with_timeout_ms({ method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }, 1000), "Content-Type", "application/json")
    let _ := http.send(req)
    ()
  }
}

# State threaded through the match.
type GS = { board :: Str, turn :: Str, parent :: Str, over :: Bool }

# Submit a move through the gated path. `session_side` is the capability of the
# connection submitting; `by`/`cell` are the claimed side + target.
fn submit(s :: GS, session_side :: Str, by :: Str, cl :: Int, log :: trail.Log, dash :: Str, now :: Int) -> [net, io, sql, time] GS {
  if s.over { s } else {
    match game.gate(session_side, by, s.turn) {
      MoveReject(why) => {
        let _ := io.print(str.join(["  ⛔ REFUSED ", session_side, "→", by, "@", int.to_str(cl), ": ", why], ""))
        let _ := notify(dash, str.join(["{\"kind\":\"refused\",\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"reason\":\"", why, "\"}"], ""))
        s
      },
      MoveOk => if cl < 0 or cl > 8 or not empty_at(s.board, cl) {
        let _ := io.print(str.join(["  ⛔ REFUSED ", by, "@", int.to_str(cl), ": cell not playable"], ""))
        let _ := notify(dash, str.join(["{\"kind\":\"refused\",\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"reason\":\"cell not playable\"}"], ""))
        s
      } else {
        let nb := set_cell(s.board, cl, by)
        let head := game.record(log, s.parent, str.join(["{\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"board\":\"", nb, "\"}"], ""))
        let _ := io.print(str.join(["  ✓ ", by, " @ ", int.to_str(cl), "   board=", nb, "   [chain ", str.slice(head, 0, 8), "]"], ""))
        let _ := notify(dash, str.join(["{\"kind\":\"move\",\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"board\":\"", nb, "\",\"chain\":\"", str.slice(head, 0, 8), "\"}"], ""))
        let w := winner(nb)
        if str.is_empty(w) {
          { board: nb, turn: (if by == "X" { "O" } else { "X" }), parent: head, over: false }
        } else {
          let _ := io.print(str.join(["  ★ ", w, " WINS"], ""))
          let _ := notify(dash, str.join(["{\"kind\":\"win\",\"winner\":\"", w, "\",\"board\":\"", nb, "\"}"], ""))
          { board: nb, turn: w, parent: head, over: true }
        }
      },
    }
  }
}

# O is played by a bot (an agent move).
fn bot_move(s :: GS, log :: trail.Log, dash :: Str, now :: Int) -> [net, io, sql, time] GS {
  if s.over { s } else {
    let _ := io.print("  [bot O] thinking ...")
    submit(s, "O", "O", bot_pick(s.board), log, dash, now)
  }
}

# ── Entry point ──────────────────────────────────────────────────────────────
fn run() -> [env, net, io, sql, time, fs_write] Unit {
  let dash := match env.get("TTT_DASH_URL") { None => "", Some(u) => u }
  let now  := time.now_ms()

  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   TIC-TAC-TOE  ·  capability-gated · verifiable · agent-playable")
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := notify(dash, "{\"kind\":\"game_start\",\"board\":\".........\",\"x\":\"human\",\"o\":\"bot\"}")

  match trail.open("/tmp/lex-ttt.db") {
    Err(e) => io.print(str.concat("[ttt] trail open failed: ", e)),
    Ok(log) => {
      let s0 := { board: ".........", turn: "X", parent: "", over: false }
      # X (human capability) opens.
      let s1 := submit(s0, "X", "X", 0, log, dash, now)
      # O bot replies.
      let s2 := bot_move(s1, log, dash, now)
      # CHEAT 1: X's connection tries to move as O (capability violation) → refused.
      let _ := io.print("  -- cheat: X's client tries to play as O --")
      let s3 := submit(s2, "X", "O", 6, log, dash, now)
      # CHEAT 2: O's connection tries to move when it is X's turn → refused.
      let _ := io.print("  -- cheat: O's client tries to move out of turn --")
      let s4 := submit(s3, "O", "O", 7, log, dash, now)
      # Back to legal play.
      let s5 := submit(s4, "X", "X", 4, log, dash, now)
      let s6 := bot_move(s5, log, dash, now)
      let s7 := submit(s6, "X", "X", 8, log, dash, now)   # X completes 0-4-8 → wins
      let res := if s7.over { str.join(["winner ", s7.turn], "") } else { "in progress" }
      let _ := notify(dash, str.join(["{\"kind\":\"done\",\"result\":\"", res, "\"}"], ""))
      let _ := io.print(str.concat("\n[ttt] ", res))
      io.print("[ttt] every legal move hash-chained to /tmp/lex-ttt.db (verifiable replay)")
    },
  }
  io.print("══════════════════════════════════════════════════════")
}
