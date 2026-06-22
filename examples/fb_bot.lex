# examples/fb_bot.lex — one player of the HOME squad in Strategy Football.
#
# Two instances (FB_ROLE=H0 and FB_ROLE=H1) form a team. Each joins over A2A for a
# hardened, match-bound token, then plays its own player. They COORDINATE over the
# hub: the off-ball player announces its openness (fb_signal — an agent-to-agent
# message), and the ball-carrier reads the human-chosen STRATEGY plus the field to
# decide pass / dribble / shoot. A player can only act as itself, in turn, this
# match — the capability gate refuses anything else.
#
# Env: FB_SERVER (default http://localhost:8900), FB_ROLE (H0 | H1)
# Run: FB_ROLE=H0 lex run --allow-effects env,io,net,time examples/fb_bot.lex run

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
  let rpc := str.join(["{\"jsonrpc\":\"2.0\",\"method\":\"tasks/send\",\"id\":\"fb\",\"params\":{\"task\":{\"kind\":\"task\",\"id\":\"fb\",\"skill\":\"", skill, "\",\"args\":", args_json, "}}}"], "")
  match jv.parse_into_errors(http_post(server, "/a2a/task", rpc)) {
    Ok(j) => match jv.get_field(j, "result") { Some(r) => match jv.get_field(r, "output") { Some(o) => o, None => JNull }, None => JNull },
    Err(_) => JNull,
  }
}
fn jstr(j :: jv.Json, k :: Str) -> Str { match jv.get_field(j, k) { Some(v) => match jv.as_str(v) { Some(s) => s, None => "" }, None => "" } }
fn jint(j :: jv.Json, k :: Str) -> Int { match jv.get_field(j, k) { Some(v) => match jv.as_int(v) { Some(n) => n, None => 0 }, None => 0 } }
fn jbool(j :: jv.Json, k :: Str) -> Bool { match jv.get_field(j, k) { Some(JBool(b)) => b, _ => false } }

type Act = { act :: Str, arg :: Str }

fn strat_of(st :: jv.Json) -> Str { let s := jstr(st, "strategy") if str.is_empty(s) { "direct" } else { s } }

# Decide this player's action from the field + the human strategy.
fn decide(st :: jv.Json, me :: Str, tm :: Str, strategy :: Str) -> Act {
  let mz := jint(st, me)
  let tz := jint(st, tm)
  let d0 := jint(st, "D0")
  let d1 := jint(st, "D1")
  let next_blocked := d0 == mz + 1 or d1 == mz + 1
  let unmarked := not (d0 == mz or d1 == mz)
  # lane me→tm clear iff no defender in zones (mz, tz] (for a forward pass)
  let between_clear := not ((d0 > mz and d0 <= tz) or (d1 > mz and d1 <= tz))
  # the give-and-go: a long ball to the striker camped at z4, skipping the presser
  let striker_open := tz == 4 and not (d0 == 4 or d1 == 4) and between_clear
  # the human strategy sets how high the playmaker carries before releasing it
  let carry_to := if strategy == "direct" { 3 } else { 2 }
  let carrier := jstr(st, "ball") == me
  if carrier {
    if mz >= 3 and unmarked { { act: "SHOOT", arg: "" } } else {
    if striker_open { { act: "PASS", arg: tm } } else {
    if mz < carry_to and not next_blocked { { act: "MOVE", arg: "fwd" } } else {
    { act: "HOLD", arg: "" } } } }
  } else {
    # off the ball: sprint to the box (z4) and camp there for the through ball
    if mz < 4 and not next_blocked { { act: "MOVE", arg: "fwd" } } else { { act: "HOLD", arg: "" } }
  }
}

fn loop(server :: Str, me :: Str, tm :: Str, token :: Str, n :: Int) -> [net, io, time] Unit {
  if n <= 0 { io.print(str.concat("[", str.concat(me, "] timeout"))) } else {
    let st := a2a(server, "fb_state", "{}")
    if jbool(st, "over") {
      io.print(str.join(["[", me, "] full time — ", (if jstr(st, "result") == "home" { "WE SCORED ⚽" } else { "defense held" })], ""))
    } else {
      let carrier := jstr(st, "ball") == me
      # Coordination: when off the ball, announce openness to the teammate (A2A relay).
      let _ := if not carrier {
        let mz := jint(st, me)
        let open := not (jint(st, "D0") == mz or jint(st, "D1") == mz)
        let _ := a2a(server, "fb_signal", str.join(["{\"by\":\"", me, "\",\"msg\":\"", (if open { "open@" } else { "marked@" }), int.to_str(mz), "\"}"], ""))
        ()
      } else { () }
      if jstr(st, "turn") == me {
        let d := decide(st, me, tm, strat_of(st))
        let res := a2a(server, "fb_move", str.join(["{\"by\":\"", me, "\",\"action\":\"", d.act, "\",\"arg\":\"", d.arg, "\",\"token\":\"", token, "\"}"], ""))
        let _ := io.print(str.join(["[", me, "] ", d.act, " ", d.arg, " → ", jstr(res, "status")], ""))
        let _ := time.sleep_ms(650)
        loop(server, me, tm, token, n - 1)
      } else {
        let _ := time.sleep_ms(400)
        loop(server, me, tm, token, n - 1)
      }
    }
  }
}

fn run() -> [env, net, io, time] Unit {
  let server := match env.get("FB_SERVER") { None => "http://localhost:8900", Some(u) => u }
  let me := match env.get("FB_ROLE") { None => "H0", Some(r) => r }
  let tm := if me == "H0" { "H1" } else { "H0" }
  let _ := io.print(str.join(["══ FOOTBALL SQUAD AGENT ", me, " (teammate ", tm, ", over A2A) ══"], ""))
  let joined := a2a(server, "fb_join", str.join(["{\"side\":\"", me, "\"}"], ""))
  let token := jstr(joined, "token")
  if str.is_empty(token) { io.print(str.join(["[", me, "] could not join (taken?)"], "")) } else {
    let _ := io.print(str.join(["[", me, "] joined match ", jstr(joined, "match"), ", signed token ", str.slice(token, 0, 14)], ""))
    loop(server, me, tm, token, 120)
    io.print(str.concat("[", str.concat(me, "] done")))
  }
}
