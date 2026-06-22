# examples/ttt_bot.lex — an independent agent that plays side O over A2A.
#
# It holds the O capability (token "tok-O") and never touches the board directly:
# it observes the public game state, computes a move, and submits it through the
# server's gated A2A endpoint (/a2a/task → game_move). The server still enforces
# capability + turn, so even the bot can't cheat — it can only act as O, in turn.
# Together with the human playing X, this is two independent agents playing a
# server-authoritative, verifiable game.
#
# Env: TTT_SERVER (default http://localhost:8900), TTT_O_TOKEN (default tok-O)
# Run: lex run --allow-effects env,io,net,time examples/ttt_bot.lex run

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.list"  as list
import "std.bytes" as bytes
import "std.http"  as http
import "std.map"   as map
import "std.time"  as time

import "lex-schema/json_value" as jv

# ── board helpers (the bot's own game knowledge) ─────────────────────────────
fn cell(b :: Str, i :: Int) -> Str { str.slice(b, i, i + 1) }
fn setc(b :: Str, i :: Int, c :: Str) -> Str { str.concat(str.slice(b, 0, i), str.concat(c, str.slice(b, i + 1, 9))) }
fn line3(b :: Str, a :: Int, c :: Int, d :: Int) -> Str {
  let x := cell(b, a)
  if x != "." and cell(b, c) == x and cell(b, d) == x { x } else { "" }
}
fn winner(b :: Str) -> Str {
  list.fold([line3(b,0,1,2), line3(b,3,4,5), line3(b,6,7,8), line3(b,0,3,6), line3(b,1,4,7), line3(b,2,5,8), line3(b,0,4,8), line3(b,2,4,6)], "", fn (a :: Str, w :: Str) -> Str { if str.is_empty(a) { w } else { a } })
}
# Cell where placing `side` completes a line (win or block), else -1.
fn win_cell(b :: Str, side :: Str) -> Int {
  list.fold([0,1,2,3,4,5,6,7,8], -1, fn (acc :: Int, i :: Int) -> Int {
    if acc >= 0 { acc } else { if cell(b, i) == "." and winner(setc(b, i, side)) == side { i } else { acc } }
  })
}
fn pref(b :: Str) -> Int {
  list.fold([4,0,2,6,8,1,3,5,7], -1, fn (acc :: Int, i :: Int) -> Int { if acc >= 0 { acc } else { if cell(b, i) == "." { i } else { acc } } })
}
# O strategy: win if able, else block X, else centre/corner/edge.
fn pick(b :: Str) -> Int {
  let w := win_cell(b, "O")
  if w >= 0 {
    w
  } else {
    let blk := win_cell(b, "X")
    if blk >= 0 { blk } else { pref(b) }
  }
}

# ── A2A transport ────────────────────────────────────────────────────────────
fn http_post(server :: Str, path :: Str, body :: Str) -> [net] Str {
  let req := http.with_header(http.with_timeout_ms({ method: "POST", url: str.concat(server, path), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: None }, 5000), "Content-Type", "application/json")
  match http.send(req) { Err(_) => "", Ok(r) => match bytes.to_str(r.body) { Err(_) => "", Ok(s) => s } }
}
# Call a skill over A2A (/a2a/task JSON-RPC); return the `result.output` Json.
fn a2a(server :: Str, skill :: Str, args_json :: Str) -> [net] jv.Json {
  let rpc := str.join(["{\"jsonrpc\":\"2.0\",\"method\":\"tasks/send\",\"id\":\"o-bot\",\"params\":{\"task\":{\"kind\":\"task\",\"id\":\"o-bot\",\"skill\":\"", skill, "\",\"args\":", args_json, "}}}"], "")
  match jv.parse_into_errors(http_post(server, "/a2a/task", rpc)) {
    Ok(j) => match jv.get_field(j, "result") { Some(r) => match jv.get_field(r, "output") { Some(o) => o, None => JNull }, None => JNull },
    Err(_) => JNull,
  }
}
fn jstr(j :: jv.Json, key :: Str) -> Str { match jv.get_field(j, key) { Some(v) => match jv.as_str(v) { Some(s) => s, None => "" }, None => "" } }
fn jbool(j :: jv.Json, key :: Str) -> Bool { match jv.get_field(j, key) { Some(JBool(b)) => b, _ => false } }

# ── poll-and-play loop ───────────────────────────────────────────────────────
fn loop(server :: Str, token :: Str, n :: Int) -> [net, io, time] Unit {
  if n <= 0 { io.print("[O-bot] giving up (timeout)") } else {
    let st := a2a(server, "game_state", "{}")
    let board := jstr(st, "board")
    let turn  := jstr(st, "turn")
    let over  := jbool(st, "over")
    if str.is_empty(board) {
      let _ := time.sleep_ms(500)
      loop(server, token, n - 1)
    } else {
      if over {
        io.print("[O-bot] game over")
      } else {
        if turn == "O" {
          let c := pick(board)
          let _ := io.print(str.join(["[O-bot] my turn — playing O @ ", int.to_str(c)], ""))
          let args := str.join(["{\"by\":\"O\",\"cell\":", int.to_str(c), ",\"token\":\"", token, "\"}"], "")
          let res := a2a(server, "game_move", args)
          let _ := io.print(str.concat("[O-bot] ← ", jstr(res, "status")))
          let _ := time.sleep_ms(700)
          loop(server, token, n - 1)
        } else {
          let _ := time.sleep_ms(500)
          loop(server, token, n - 1)
        }
      }
    }
  }
}

fn run() -> [env, net, io, time] Unit {
  let server := match env.get("TTT_SERVER") { None => "http://localhost:8900", Some(u) => u }
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   TTT O-BOT  ·  independent agent, joins as O and plays over A2A")
  let _ := io.print("══════════════════════════════════════════════════════")
  # Join as O to receive a signed capability token (cannot act without it).
  let joined := a2a(server, "game_join", "{\"side\":\"O\"}")
  let token := jstr(joined, "token")
  if str.is_empty(token) {
    io.print("[O-bot] could not join as O (side taken?) — exiting")
  } else {
    let _ := io.print(str.concat("[O-bot] joined as O, got signed token ", str.slice(token, 0, 14)))
    loop(server, token, 120)
    io.print("[O-bot] done")
  }
}
