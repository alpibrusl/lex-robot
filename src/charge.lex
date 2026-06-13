# charge.lex — OCPP charging client for the real lex-charge service (ev-fleet).
#
# Uses the header-capable http API (http.send + with_auth/with_header), so it
# talks to the *authenticated* lex-charge directly — no proxy needed:
#   POST <charge_url>/v1/chargers/<cp_id>/start  Bearer <jwt>  { connector_id, id_tag }
#   GET  <charge_url>/v1/sessions/active          Bearer <jwt>
#   POST <charge_url>/v1/chargers/<cp_id>/stop    Bearer <jwt>
#
# charge_url + token point at either the real lex-charge or the depot sidecar
# stand-in (which mirrors these routes). A session that appears in
# /v1/sessions/active for the cp_id is real OCPP evidence the connection worked.

import "std.str" as str

import "std.int" as int

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

fn base_req(method :: Str, url :: Str) -> { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] } {
  { method: method, url: url, headers: map.new(), body: None, timeout_ms: Some(15000) }
}

fn body_str(resp :: HttpResponse) -> Str {
  match http.text_body(resp) {
    Ok(s) => s,
    Err(_) => "",
  }
}

# Strip spaces so checks work against both compact JSON (real lex-charge) and
# spaced JSON (the Python stand-in's json.dumps).
fn compact(s :: Str) -> Str {
  str.replace(s, " ", "")
}

fn auth(req :: { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] }, token :: Str) -> { method :: Str, url :: Str, headers :: Map[Str, Str], body :: Option[Bytes], timeout_ms :: Option[Int] } {
  # Connection: close avoids the client hanging on keep-alive sockets that the
  # server doesn't close (seen against the lex-web HTTP server via the docker proxy).
  let req2 := http.with_header(req, "Connection", "close")
  if str.is_empty(token) {
    req2
  } else {
    http.with_auth(req2, "Bearer", token)
  }
}

# Issue an OCPP remote-start. Returns true if lex-charge accepted it (sent:true).
fn start(charge_url :: Str, cp_id :: Str, connector_id :: Int, id_tag :: Str, token :: Str) -> [net] Result[Bool, Str] {
  let url := str.join([charge_url, "/v1/chargers/", cp_id, "/start"], "")
  let payload := str.join(["{\"connector_id\":", int.to_str(connector_id), ",\"id_tag\":\"", id_tag, "\"}"], "")
  let req0 := base_req("POST", url)
  let req1 := { method: req0.method, url: req0.url, headers: req0.headers, body: Some(bytes.from_str(payload)), timeout_ms: req0.timeout_ms }
  let req := auth(http.with_header(req1, "Content-Type", "application/json"), token)
  match http.send(req) {
    Err(e) => Err(http_err(e)),
    Ok(resp) => {
      let b := compact(body_str(resp))
      Ok(if str.contains(b, "\"sent\":true") { true } else { str.contains(b, "\"Accepted\"") })
    },
  }
}

# Confirm via the real session list that this cp_id has an active session.
fn confirm_active(charge_url :: Str, cp_id :: Str, token :: Str) -> [net] Result[Bool, Str] {
  let url := str.concat(charge_url, "/v1/sessions/active")
  let req := auth(base_req("GET", url), token)
  match http.send(req) {
    Err(e) => Err(http_err(e)),
    Ok(resp) => Ok(str.contains(compact(body_str(resp)), str.join(["\"cp_id\":\"", cp_id, "\""], ""))),
  }
}

fn stop(charge_url :: Str, cp_id :: Str, token :: Str) -> [net] Result[Unit, Str] {
  let url := str.join([charge_url, "/v1/chargers/", cp_id, "/stop"], "")
  let req0 := base_req("POST", url)
  let req1 := { method: req0.method, url: req0.url, headers: req0.headers, body: Some(bytes.from_str("{}")), timeout_ms: req0.timeout_ms }
  let req := auth(http.with_header(req1, "Content-Type", "application/json"), token)
  match http.send(req) {
    Err(e) => Err(http_err(e)),
    Ok(_) => Ok(()),
  }
}
