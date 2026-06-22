# src/a2a_server.lex — Sign this robot's A2A cards and register them with the sidecar.
#
# Called once on startup so the sidecar can serve signed cards at
#   GET /a2a/public-card
#   GET /a2a/extended-card
# without doing any cryptography itself. Crypto stays in Lex (std.crypto).
#
# Wire: two raw-text POSTs to the sidecar — body is "<card_json>\n<sig_b64>",
# the same format a2a_handshake.lex expects from a peer's card endpoint.
#
# Effect: [net] (two HTTP POSTs; signing is pure)

import "std.str" as str

import "std.bytes" as bytes

import "std.map" as map

import "std.http" as http

import "./a2a_card" as card

fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("net: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

# Sign a card and build the wire blob: "<card_json>\n<sig_b64>".
fn sign_blob(c :: card.RobotCard, secret :: Bytes) -> Result[Str, Str] {
  let cj := card.card_to_json(c)
  match card.sign_card(cj, secret) {
    Err(e) => Err(e),
    Ok(sig) => Ok(str.join([cj, "\n", sig], "")),
  }
}

# POST a pre-signed blob (raw text) to a sidecar register endpoint.
fn push_card(sidecar_url :: Str, path :: Str, blob :: Str) -> [net] Result[Str, Str] {
  let url := str.join([sidecar_url, path], "")
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(blob)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 5000), "Content-Type", "text/plain; charset=utf-8")
  match http.send(req) {
    Err(e) => Err(http_err_str(e)),
    Ok(_) => Ok("ok"),
  }
}

# Sign both cards and push them to the sidecar. Call once on startup before
# accepting any A2A handshakes. `secret` is the robot's ed25519 seed (32 bytes).
fn register_cards(sidecar_url :: Str, pub_card :: card.RobotCard, ext_card :: card.RobotCard, secret :: Bytes) -> [net] Result[Str, Str] {
  match sign_blob(pub_card, secret) {
    Err(e) => Err(str.concat("sign public: ", e)),
    Ok(pub_blob) => match push_card(sidecar_url, "/a2a/register-public-card", pub_blob) {
      Err(e) => Err(str.concat("push public: ", e)),
      Ok(_) => match sign_blob(ext_card, secret) {
        Err(e) => Err(str.concat("sign extended: ", e)),
        Ok(ext_blob) => push_card(sidecar_url, "/a2a/register-extended-card", ext_blob),
      },
    },
  }
}

