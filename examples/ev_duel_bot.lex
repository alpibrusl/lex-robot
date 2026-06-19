# examples/ev_duel_bot.lex — an independent fleet operator (P2) for Charger Duel.
#
# Joins as P2 over A2A to receive a signed capability token, then on each of its
# turns claims the most efficient charger it can still fit before the deadline:
# the highest-kWh charger whose occupancy minutes fit its remaining time budget.
# Every claim goes through the gated A2A endpoint; it can only act as P2, in turn.
#
# Env: EVD_SERVER (default http://localhost:8900)
# Run: lex run --allow-effects env,io,net,time examples/ev_duel_bot.lex run

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

fn http_post(server :: Str, path :: Str, body :: Str) -> [net] Str {
  let req := http.with_header(http.with_timeout_ms({ method: "POST", url: str.concat(server, path), headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: None }, 5000), "Content-Type", "application/json")
  match http.send(req) { Err(_) => "", Ok(r) => match bytes.to_str(r.body) { Err(_) => "", Ok(s) => s } }
}
fn a2a(server :: Str, skill :: Str, args_json :: Str) -> [net] jv.Json {
  let rpc := str.join(["{\"jsonrpc\":\"2.0\",\"method\":\"tasks/send\",\"id\":\"p2\",\"params\":{\"task\":{\"kind\":\"task\",\"id\":\"p2\",\"skill\":\"", skill, "\",\"args\":", args_json, "}}}"], "")
  match jv.parse_into_errors(http_post(server, "/a2a/task", rpc)) {
    Ok(j) => match jv.get_field(j, "result") { Some(r) => match jv.get_field(r, "output") { Some(o) => o, None => JNull }, None => JNull },
    Err(_) => JNull,
  }
}
fn jstr(j :: jv.Json, k :: Str) -> Str { match jv.get_field(j, k) { Some(v) => match jv.as_str(v) { Some(s) => s, None => "" }, None => "" } }
fn jint(j :: jv.Json, k :: Str) -> Int { match jv.get_field(j, k) { Some(v) => match jv.as_int(v) { Some(n) => n, None => 0 }, None => 0 } }
fn jbool(j :: jv.Json, k :: Str) -> Bool { match jv.get_field(j, k) { Some(JBool(b)) => b, _ => false } }

# Most energy P2 can still fit (max kWh among free chargers within time budget); -1 if none.
type Best = { idx :: Int, kwh :: Int }
fn pick(pool :: List[jv.Json], budget :: Int) -> Int {
  let b := list.fold(pool, { idx: -1, kwh: -1 }, fn (acc :: Best, it :: jv.Json) -> Best {
    let owner := jstr(it, "owner")
    let mins := jint(it, "min")
    let kwh := jint(it, "kwh")
    let i := jint(it, "i")
    if str.is_empty(owner) and mins <= budget and kwh > acc.kwh { { idx: i, kwh: kwh } } else { acc }
  })
  b.idx
}

fn loop(server :: Str, token :: Str, n :: Int) -> [net, io, time] Unit {
  if n <= 0 { io.print("[P2] timeout") } else {
    let st := a2a(server, "ev_state", "{}")
    let turn := jstr(st, "turn")
    let over := jbool(st, "over")
    if str.is_empty(turn) {
      let _ := time.sleep_ms(500)
      loop(server, token, n - 1)
    } else {
      if over { io.print("[P2] game over") } else {
        if turn == "P2" {
          let pool := match jv.get_field(st, "pool") { Some(JList(xs)) => xs, _ => [] }
          let bud := match jv.get_field(st, "bud") { Some(b) => jint(b, "P2"), None => 0 }
          let c := pick(pool, bud)
          if c < 0 {
            let _ := time.sleep_ms(600)
            loop(server, token, n - 1)
          } else {
            let _ := io.print(str.join(["[P2] claiming charger ", int.to_str(c)], ""))
            let res := a2a(server, "ev_move", str.join(["{\"by\":\"P2\",\"charger\":", int.to_str(c), ",\"token\":\"", token, "\"}"], ""))
            let _ := io.print(str.concat("[P2] ← ", jstr(res, "status")))
            let _ := time.sleep_ms(700)
            loop(server, token, n - 1)
          }
        } else {
          let _ := time.sleep_ms(500)
          loop(server, token, n - 1)
        }
      }
    }
  }
}

fn run() -> [env, net, io, time] Unit {
  let server := match env.get("EVD_SERVER") { None => "http://localhost:8900", Some(u) => u }
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   CHARGER DUEL P2-BOT  ·  independent fleet operator, claims over A2A")
  let _ := io.print("══════════════════════════════════════════════════════")
  let joined := a2a(server, "ev_join", "{\"side\":\"P2\"}")
  let token := jstr(joined, "token")
  if str.is_empty(token) { io.print("[P2] could not join (taken?)") } else {
    let _ := io.print(str.concat("[P2] joined, signed token ", str.slice(token, 0, 14)))
    loop(server, token, 60)
    io.print("[P2] done")
  }
}
