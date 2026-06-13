# lex-robot/client.lex — thin HTTP bridge to the LeRobot Python sidecar.
#
# The sidecar exposes each skill as POST <url>/skill/<name> with a JSON body,
# returning a JSON result. (Streaming sensor/state is a later WebSocket add via
# net.dial_ws — see DESIGN.md.) Localhost only, so no auth headers are needed,
# which also sidesteps std.http's lack of custom-header support.

import "std.str" as str

import "std.http" as http

import "std.bytes" as bytes

fn http_err(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

# POST a skill call; return the raw JSON response body or an error string.
fn call(sidecar_url :: Str, skill :: Str, args_json :: Str) -> [net] Result[Str, Str] {
  let url := str.join([sidecar_url, "/skill/", skill], "")
  match http.post(url, bytes.from_str(args_json), "application/json") {
    Err(e) => Err(str.join(["sidecar ", skill, ": ", http_err(e)], "")),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => Err("sidecar response decode failed"),
      Ok(s) => Ok(s),
    },
  }
}
