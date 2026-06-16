# lex-robot/client.lex — thin HTTP bridge to the LeRobot Python sidecar.
#
# The sidecar exposes each skill as POST <url>/skill/<name> with a JSON body,
# returning a JSON result. (Streaming sensor/state is a later WebSocket add via
# net.dial_ws — see DESIGN.md.) Localhost only, so no auth headers are needed,
# which also sidesteps std.http's lack of custom-header support.

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
