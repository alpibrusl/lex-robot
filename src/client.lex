# lex-robot/client.lex — thin HTTP bridge to the LeRobot Python sidecar.
#
# The sidecar exposes each skill as POST <url>/skill/<name> with a JSON body,
# returning a JSON result. (Streaming sensor/state is a later WebSocket add via
# net.dial_ws — see DESIGN.md.)
#
# NO AUTH HEADER IS SENT, and "localhost" is not the reason it is safe to omit
# one — it isn't. A loopback port is reachable by every process and every user
# on the box, which is the hole lex-robot#196 names: today, anything on the Pi
# can POST /skill/move_arm. The sidecar now has a perimeter (a bearer token
# and, over a unix socket, an SO_PEERCRED allow-list — see SIDECAR.md), but
# this client can use neither yet:
#
#   - the socket needs a `net.dial_unix` builtin lex 0.10.11 does not have;
#   - a token needs either `[env]` on every skill signature (widening the
#     audited effect row of the whole surface — `lex agent-guidelines` §1.2)
#     or a new field on `t.Robot` that every literal in the repo would grow.
#
# So enabling the token gate refuses Lex callers on mutating skills. The
# sidecar says so at startup. Closing this is the follow-up in #196.

import "std.str" as str

import "std.http" as http

import "std.bytes" as bytes

import "std.map" as map

fn http_err(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

# POST a skill call; return the raw JSON response body or an error string.
#
# Uses http.send (header-capable) and asks for a long timeout via with_timeout_ms.
# CAVEAT: as of the lex 0.9.8/0.9.10 toolchain the std.http client enforces a
# hard ~10s ceiling that with_timeout_ms does not raise (verified empirically).
# So any single skill call that runs longer than ~10s will report `timeout`
# regardless of the value below. Sub-10s skills (read_*, move_to, the step-wise
# policy_action/apply_action loop) are unaffected; a monolithic `run_policy`
# rollout that solves PushT (≈15–40s) is NOT — drive it via the step-wise path
# (see examples/safe_rollout.lex) or an async sidecar until the ceiling is lifted.
fn call(sidecar_url :: Str, skill :: Str, args_json :: Str) -> [net] Result[Str, Str] {
  let url := str.join([sidecar_url, "/skill/", skill], "")
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(args_json)), timeout_ms: None }
  let req := http.with_timeout_ms(http.with_header(req0, "Content-Type", "application/json"), 120000)
  match http.send(req) {
    Err(e) => Err(str.join(["sidecar ", skill, ": ", http_err(e)], "")),
    Ok(resp) => match http.text_body(resp) {
      Err(_) => Err("sidecar response decode failed"),
      Ok(s) => Ok(s),
    },
  }
}
