# examples/heist_bot.lex — the Muscle (P2) for the Co-op Infiltration heist.
#
# A cooperative partner, not a rival. Joins as P2 over A2A to receive a signed
# capability token for the MUSCLE role, then watches the infiltration: whenever
# the current stage is a physical one (its turn), it clears it through the gated
# A2A endpoint. It holds no capability for the electronic stages — those are the
# Hacker's (P1) job — so it simply waits its turn. Win comes only if both clear
# their stages in order before the alarm trips three times.
#
# Env: HEIST_SERVER (default http://localhost:8900)
# Run: lex run --allow-effects env,io,net,time examples/heist_bot.lex run

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
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

fn loop(server :: Str, token :: Str, n :: Int) -> [net, io, time] Unit {
  if n <= 0 { io.print("[MUSCLE] timeout") } else {
    let st := a2a(server, "hx_state", "{}")
    let turn := jstr(st, "turn")
    let over := jbool(st, "over")
    if over { io.print(str.concat("[MUSCLE] operation ended: ", jstr(st, "result"))) } else {
      if turn == "P2" {
        let at := jint(st, "at")
        let _ := io.print(str.join(["[MUSCLE] clearing physical stage ", int.to_str(at)], ""))
        let res := a2a(server, "hx_move", str.join(["{\"by\":\"P2\",\"token\":\"", token, "\"}"], ""))
        let _ := io.print(str.concat("[MUSCLE] ← ", jstr(res, "status")))
        let _ := time.sleep_ms(700)
        loop(server, token, n - 1)
      } else {
        let _ := time.sleep_ms(500)
        loop(server, token, n - 1)
      }
    }
  }
}

fn run() -> [env, net, io, time] Unit {
  let server := match env.get("HEIST_SERVER") { None => "http://localhost:8900", Some(u) => u }
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   HEIST MUSCLE (P2)  ·  co-op partner, clears physical stages over A2A")
  let _ := io.print("══════════════════════════════════════════════════════")
  let joined := a2a(server, "hx_join", "{\"side\":\"P2\"}")
  let token := jstr(joined, "token")
  if str.is_empty(token) { io.print("[MUSCLE] could not join (taken?)") } else {
    let _ := io.print(str.join(["[MUSCLE] joined as ", jstr(joined, "role"), ", signed token ", str.slice(token, 0, 14)], ""))
    loop(server, token, 80)
    io.print("[MUSCLE] done")
  }
}
