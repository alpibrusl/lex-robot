# examples/llm_arena_bot.lex — an LLM-driven Tic-Tac-Toe arena player.
#
# Joins a side over A2A (gated, signed token — it can only act as its side, in
# turn) and picks each move with an OpenCode Zen "Go plan" open-weights model.
# Two instances on DIFFERENT models play a full model-vs-model match, refereed
# and hash-chained by the sidecar — a verifiable LLM-vs-LLM party.
#
# The model supplies the move; a built-in heuristic is the safety net — if the
# model's reply is unparseable or names an illegal cell, the bot falls back to
# win/block/centre so it ALWAYS plays a legal move (and can't cheat: the server
# still enforces capability + turn).
#
# Env:
#   TTT_SERVER         game server (default http://localhost:8900)
#   SIDE               X | O   (default O)
#   OPENCODE_MODEL     e.g. glm-5.2, kimi-k2.7-code, qwen3.7-max (default glm-5.2)
#   OPENCODE_API_KEY   the Go-plan key; if unset, the bot plays pure heuristic
#
# Run: lex run --allow-effects env,io,net,time,llm,proc,fs_read,fs_write,sql,crypto,random,concurrent \
#        examples/llm_arena_bot.lex run

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.list"  as list
import "std.bytes" as bytes
import "std.http"  as http
import "std.map"   as map
import "std.time"  as time
import "std.iter"  as iter

import "lex-schema/json_value"        as jv
import "lex-llm/src/agent"            as llm_agent
import "lex-llm/src/message"          as msg
import "lex-llm/src/delta"            as d
import "lex-llm/src/provider"         as prov
import "lex-llm/src/providers/openai" as oai

# ── board helpers (generalized for either side) ──────────────────────────────
fn cell(b :: Str, i :: Int) -> Str { str.slice(b, i, i + 1) }
fn setc(b :: Str, i :: Int, c :: Str) -> Str { str.concat(str.slice(b, 0, i), str.concat(c, str.slice(b, i + 1, 9))) }
fn line3(b :: Str, a :: Int, c :: Int, e :: Int) -> Str {
  let x := cell(b, a)
  if x != "." and cell(b, c) == x and cell(b, e) == x { x } else { "" }
}
fn winner(b :: Str) -> Str {
  list.fold([line3(b,0,1,2), line3(b,3,4,5), line3(b,6,7,8), line3(b,0,3,6), line3(b,1,4,7), line3(b,2,5,8), line3(b,0,4,8), line3(b,2,4,6)], "", fn (a :: Str, w :: Str) -> Str { if str.is_empty(a) { w } else { a } })
}
fn win_cell(b :: Str, side :: Str) -> Int {
  list.fold([0,1,2,3,4,5,6,7,8], -1, fn (acc :: Int, i :: Int) -> Int {
    if acc >= 0 { acc } else { if cell(b, i) == "." and winner(setc(b, i, side)) == side { i } else { acc } }
  })
}
fn pref(b :: Str) -> Int {
  list.fold([4,0,2,6,8,1,3,5,7], -1, fn (acc :: Int, i :: Int) -> Int { if acc >= 0 { acc } else { if cell(b, i) == "." { i } else { acc } } })
}
fn opp(side :: Str) -> Str { if side == "X" { "O" } else { "X" } }
# Heuristic fallback: win if able, else block, else centre/corner/edge.
fn pick(b :: Str, side :: Str) -> Int {
  let w := win_cell(b, side)
  if w >= 0 { w } else {
    let blk := win_cell(b, opp(side))
    if blk >= 0 { blk } else { pref(b) }
  }
}

# ── prompt + parse ───────────────────────────────────────────────────────────
fn opencode_zen_url() -> Str { "https://opencode.ai/zen/go/v1/chat/completions" }

fn grid_str(b :: Str) -> Str {
  list.fold([0,1,2,3,4,5,6,7,8], "", fn (acc :: Str, i :: Int) -> Str {
    str.join([acc, if str.is_empty(acc) { "" } else { ", " }, int.to_str(i), ":", cell(b, i)], "")
  })
}

fn last_seg(s :: Str, sep :: Str) -> Str {
  list.fold(str.split(s, sep), "", fn (_acc :: Str, seg :: Str) -> Str { seg })
}

# Pull the chosen cell from "...MOVE=<n>...": take the text after the last
# "MOVE", then after the last "=", trim, read the first character as 0-8.
# Returns -1 if not found (→ heuristic fallback).
fn parse_move(text :: Str) -> Int {
  let tail := str.trim(last_seg(last_seg(text, "MOVE"), "="))
  if str.is_empty(tail) { 0 - 1 } else {
    match str.to_int(str.slice(tail, 0, 1)) {
      Some(n) => if n >= 0 and n <= 8 { n } else { 0 - 1 },
      None    => 0 - 1,
    }
  }
}

# Read the agent's final assistant text out of the step stream.
fn extract_text(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDone(m) => match m { AssistantMsg(t, _) => t, _ => acc },
      _ => acc,
    }
  })
}

# Ask the model for a move; validate it's a legal empty cell, else heuristic.
fn llm_cell(b :: Str, side :: Str, model_name :: Str, key :: Str) -> [net, llm, io, proc] Int {
  let sys := str.join([
    "You are a world-class Tic-Tac-Toe player. Play to win or draw, never to lose. ",
    "Reason briefly, then end your reply with a single final line in EXACTLY this form: MOVE=<cell>  ",
    "where <cell> is one empty cell index 0-8."], "")
  let user := str.join([
    "You are '", side, "'. Board cells (index:mark, '.'=empty): ", grid_str(b), ".\n",
    "It is your turn. Win if you can, otherwise block your opponent, otherwise take the strongest square. ",
    "End with: MOVE=<cell>"], "")
  let provider := oai.make_provider({ api_key: key, base_url: opencode_zen_url() })
  let model    := prov.make_model_ref("opencode-go", model_name)
  # Generous max_tokens: GO models reason, and a low cap truncates the move.
  let opts     := { temperature: Some(0.3), top_p: None, max_steps: Some(1), max_tokens: Some(6000) }
  let agent    := llm_agent.make_agent(str.concat("ttt-", side), sys, model, provider, [], opts)
  let steps    := iter.to_list(llm_agent.run_loop(agent, [UserMsg(user)]))
  let chosen   := parse_move(extract_text(steps))
  if chosen >= 0 and chosen <= 8 and cell(b, chosen) == "." { chosen } else { pick(b, side) }
}

# ── A2A transport ────────────────────────────────────────────────────────────
fn http_post(server :: Str, path :: Str, body :: Str) -> [net] Str {
  let req := http.with_header(http.with_timeout_ms({ method: "POST", url: str.concat(server, path), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: None }, 5000), "Content-Type", "application/json")
  match http.send(req) { Err(_) => "", Ok(r) => match bytes.to_str(r.body) { Err(_) => "", Ok(s) => s } }
}
fn a2a(server :: Str, skill :: Str, args_json :: Str) -> [net] jv.Json {
  let rpc := str.join(["{\"jsonrpc\":\"2.0\",\"method\":\"tasks/send\",\"id\":\"llm-bot\",\"params\":{\"task\":{\"kind\":\"task\",\"id\":\"llm-bot\",\"skill\":\"", skill, "\",\"args\":", args_json, "}}}"], "")
  match jv.parse_into_errors(http_post(server, "/a2a/task", rpc)) {
    Ok(j) => match jv.get_field(j, "result") { Some(r) => match jv.get_field(r, "output") { Some(o) => o, None => JNull }, None => JNull },
    Err(_) => JNull,
  }
}
fn jstr(j :: jv.Json, key :: Str) -> Str { match jv.get_field(j, key) { Some(v) => match jv.as_str(v) { Some(s) => s, None => "" }, None => "" } }
fn jbool(j :: jv.Json, key :: Str) -> Bool { match jv.get_field(j, key) { Some(JBool(b)) => b, _ => false } }

# ── poll-and-play loop ───────────────────────────────────────────────────────
fn play_loop(server :: Str, side :: Str, model_name :: Str, key :: Str, token :: Str, n :: Int) -> [net, io, time, llm, proc] Unit {
  if n <= 0 { io.print(str.concat("[", str.concat(side, "-bot] giving up (timeout)"))) } else {
    let st    := a2a(server, "game_state", "{}")
    let board := jstr(st, "board")
    let turn  := jstr(st, "turn")
    let over  := jbool(st, "over")
    if str.is_empty(board) {
      let _ := time.sleep_ms(500)
      play_loop(server, side, model_name, key, token, n - 1)
    } else {
      if over {
        io.print(str.join(["[", side, "-bot] game over — winner: ", jstr(st, "winner")], ""))
      } else {
        if turn == side {
          let c := if str.is_empty(key) { pick(board, side) } else { llm_cell(board, side, model_name, key) }
          let _ := io.print(str.join(["[", side, "-bot · ", model_name, "] turn → cell ", int.to_str(c)], ""))
          let args := str.join(["{\"by\":\"", side, "\",\"cell\":", int.to_str(c), ",\"token\":\"", token, "\"}"], "")
          let res := a2a(server, "game_move", args)
          let _ := io.print(str.concat("   ← ", jstr(res, "status")))
          let _ := time.sleep_ms(600)
          play_loop(server, side, model_name, key, token, n - 1)
        } else {
          let _ := time.sleep_ms(500)
          play_loop(server, side, model_name, key, token, n - 1)
        }
      }
    }
  }
}

fn run() -> [env, net, io, time, llm, proc] Unit {
  let server := match env.get("TTT_SERVER")    { None => "http://localhost:8900", Some(u) => u }
  let side   := match env.get("SIDE")           { None => "O", Some(s) => if str.is_empty(s) { "O" } else { s } }
  let model  := match env.get("OPENCODE_MODEL") { None => "glm-5.2", Some(m) => if str.is_empty(m) { "glm-5.2" } else { m } }
  let key    := match env.get("OPENCODE_API_KEY") { None => "", Some(k) => k }
  let mode   := if str.is_empty(key) { "heuristic" } else { model }
  let _ := io.print(str.join(["[", side, "-bot] joining as ", side, " — player: ", mode], ""))
  let joined := a2a(server, "game_join", str.join(["{\"side\":\"", side, "\"}"], ""))
  let token := jstr(joined, "token")
  if str.is_empty(token) {
    io.print(str.join(["[", side, "-bot] could not join as ", side, " (side taken?) — exiting"], ""))
  } else {
    let _ := io.print(str.join(["[", side, "-bot] joined, signed token ", str.slice(token, 0, 12), "…"], ""))
    # Generous poll budget: a slow reasoning opponent can take >60s per move, so
    # the bot must out-wait several of those before declaring a timeout.
    play_loop(server, side, model, key, token, 2400)
    io.print(str.join(["[", side, "-bot] done"], ""))
  }
}
