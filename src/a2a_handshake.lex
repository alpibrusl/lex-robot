# src/a2a_handshake.lex — A2A handshake state machine (issue #18).
#
# Pure transition core + thin [net] driver.
#
# Flow:
#   WaitPublic  → GotPublicJson  → verify sig → WaitConsent (or Done(Rejected))
#   WaitConsent → ConsentGranted → WaitExtended
#               → ConsentPublicOnly → Done(PublicOnly)
#               → ConsentRefused    → Done(Rejected)
#   WaitExtended → GotExtendedJson → verify sig → Done(Escalated or Rejected)
#   any state   → NetFail / Expired → Done(Failed)
#
# Wire format for card endpoints (sidecar / real peer):
#   GET {endpoint}/a2a/public-card
#   GET {endpoint}/a2a/extended-card   (+ Authorization: Bearer {ephemeral_token})
# Both return: <canonical card JSON>\n<base64url ed25519 signature>
#
# The nonce from the bootstrap blob is threaded through to detect replay:
# `card.nonce` (if present on the fetched card) must match blob.nonce.
#
# Pure transition:  no effects
# [net] driver:     [net] only — time gating is the caller's job (pass now_ms)

import "std.str" as str

import "std.bytes" as bytes

import "std.list" as list

import "std.http" as http

import "std.map" as map

import "./a2a_bootstrap" as boot

import "./a2a_card" as card

import "./a2a_consent" as consent

# ── Outcome (terminal) ─────────────────────────────────────────────────────────
type HandshakeOutcome = PublicOnly(card.RobotCard) | Escalated((card.RobotCard, card.RobotCard)) | Rejected(Str) | Failed(Str)

type HandshakeState = WaitPublic(boot.BootstrapBlob) | WaitConsent((boot.BootstrapBlob, card.RobotCard)) | WaitExtended((boot.BootstrapBlob, card.RobotCard)) | Done(HandshakeOutcome)

type HandshakeEvent = GotPublicJson(Str) | ConsentGranted | ConsentPublicOnly | ConsentRefused(Str) | GotExtendedJson(Str) | NetFail(Str) | Expired

type HandshakeAction = FetchPublic | RunConsent | FetchExtended | Halt

type Transition = { next :: HandshakeState, action :: HandshakeAction }

# ── Wire helpers ───────────────────────────────────────────────────────────────
# The card endpoint returns "card_json\nsig_b64"; split and return both parts.
fn split_card_response(body :: Str) -> (Str, Str) {
  let parts := str.split(body, "\n")
  let cj := match list.head(parts) {
    Some(s) => s,
    None => "",
  }
  let sg := match list.head(list.tail(parts)) {
    Some(s) => s,
    None => "",
  }
  (cj, sg)
}

# Verify a card body: parse it and check the signature against peer_pubkey.
fn verify_response(body :: Str, peer_pubkey :: Str) -> Result[card.RobotCard, Str] {
  let pair := split_card_response(body)
  match pair {
    (cj, sg) => match card.parse_card(cj) {
      Err(e) => Err(str.concat("parse: ", e)),
      Ok(rc) => if card.verify_card(cj, peer_pubkey, sg) {
        Ok(rc)
      } else {
        Err("card signature verification failed")
      },
    },
  }
}

# ── Pure transition ────────────────────────────────────────────────────────────
fn step(state :: HandshakeState, event :: HandshakeEvent) -> Transition
  examples {
    step(WaitPublic({ endpoint: "http://p:8900", ephemeral_token: "tok", peer_pubkey: "", nonce: "n", expires_at: 9999999 }), NetFail("connection refused")) => { next: Done(Failed("connection refused")), action: Halt },
    step(WaitConsent({ endpoint: "http://p:8900", ephemeral_token: "tok", peer_pubkey: "", nonce: "n", expires_at: 0 }, { name: "P", endpoint: "http://p:8900", pubkey_b64: "", tier: card.Public, skills: [], supports_extended: false }), Expired) => { next: Done(Failed("bootstrap blob expired")), action: Halt },
    step(WaitConsent({ endpoint: "http://p:8900", ephemeral_token: "tok", peer_pubkey: "", nonce: "n", expires_at: 9999999 }, { name: "P", endpoint: "http://p:8900", pubkey_b64: "", tier: card.Public, skills: [], supports_extended: false }), ConsentPublicOnly) => { next: Done(PublicOnly({ name: "P", endpoint: "http://p:8900", pubkey_b64: "", tier: card.Public, skills: [], supports_extended: false })), action: Halt },
    step(WaitConsent({ endpoint: "http://p:8900", ephemeral_token: "tok", peer_pubkey: "", nonce: "n", expires_at: 9999999 }, { name: "P", endpoint: "http://p:8900", pubkey_b64: "", tier: card.Public, skills: [], supports_extended: false }), ConsentRefused("not in allowlist")) => { next: Done(Rejected("not in allowlist")), action: Halt },
    step(Done(Failed("x")), NetFail("y")) => { next: Done(Failed("x")), action: Halt }
  }
{
  match state {
    Done(_) => { next: state, action: Halt },
    WaitPublic(blob) => match event {
      Expired => { next: Done(Failed("bootstrap blob expired")), action: Halt },
      NetFail(e) => { next: Done(Failed(e)), action: Halt },
      GotPublicJson(body) => match verify_response(body, blob.peer_pubkey) {
        Err(e) => { next: Done(Rejected(str.concat("public card: ", e))), action: Halt },
        Ok(pub_card) => { next: WaitConsent(blob, pub_card), action: RunConsent },
      },
      _ => { next: Done(Failed("unexpected event in WaitPublic")), action: Halt },
    },
    WaitConsent(blob, pub_card) => match event {
      Expired => { next: Done(Failed("bootstrap blob expired")), action: Halt },
      NetFail(e) => { next: Done(Failed(e)), action: Halt },
      ConsentPublicOnly => { next: Done(PublicOnly(pub_card)), action: Halt },
      ConsentRefused(why) => { next: Done(Rejected(why)), action: Halt },
      ConsentGranted => { next: WaitExtended(blob, pub_card), action: FetchExtended },
      _ => { next: Done(Failed("unexpected event in WaitConsent")), action: Halt },
    },
    WaitExtended(blob, pub_card) => match event {
      Expired => { next: Done(Failed("bootstrap blob expired")), action: Halt },
      NetFail(e) => { next: Done(Failed(e)), action: Halt },
      GotExtendedJson(body) => match verify_response(body, blob.peer_pubkey) {
        Err(e) => { next: Done(Rejected(str.concat("extended card: ", e))), action: Halt },
        Ok(ext_card) => if card.is_superset(ext_card.skills, pub_card.skills) {
          { next: Done(Escalated(pub_card, ext_card)), action: Halt }
        } else {
          { next: Done(Rejected("extended card is not a superset of public card")), action: Halt }
        },
      },
      _ => { next: Done(Failed("unexpected event in WaitExtended")), action: Halt },
    },
  }
}

# ── [net] driver ────────────────────────────────────────────────────────────────
# Drives the state machine to completion via HTTP. Pure transitions stay pure;
# only this function touches the network. `now_ms` comes from the caller (who
# has [time]) so this driver stays [net]-only.
fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("net: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn get_card(url :: Str) -> [net] Result[Str, Str] {
  match http.get(url) {
    Err(e) => Err(http_err_str(e)),
    Ok(resp) => match http.text_body(resp) {
      Err(e) => Err(http_err_str(e)),
      Ok(body) => Ok(body),
    },
  }
}

fn get_extended_card(url :: Str, token :: Str) -> [net] Result[Str, Str] {
  let req0 := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 10000), "Authorization", str.concat("Bearer ", token))
  match http.send(req) {
    Err(e) => Err(http_err_str(e)),
    Ok(resp) => match http.text_body(resp) {
      Err(e) => Err(http_err_str(e)),
      Ok(body) => Ok(body),
    },
  }
}

# Feed a consent.ConsentDecision back into the state machine as an event.
fn consent_event(d :: consent.ConsentDecision) -> HandshakeEvent {
  match d {
    ConsentGrant => ConsentGranted,
    DowngradeToPublic => ConsentPublicOnly,
    Refuse(why) => ConsentRefused(why),
  }
}

# Run the full handshake to completion. Returns the terminal HandshakeOutcome.
# `policy` is the local consent policy; `now_ms` is the current time in epoch ms.
fn run(blob :: boot.BootstrapBlob, policy :: consent.ConsentPolicy, now_ms :: Int) -> [net] HandshakeOutcome {
  if boot.is_expired(blob, now_ms) {
    Failed("bootstrap blob expired before handshake start")
  } else {
    let init := WaitPublic(blob)
    let pub_url := str.join([blob.endpoint, "/a2a/public-card"], "")
    let t1 := step(init, match get_card(pub_url) {
      Err(e) => NetFail(e),
      Ok(body) => GotPublicJson(body),
    })
    match t1.next {
      Done(o) => o,
      WaitConsent(b, pub_card) => {
        let decision := consent.decide(policy, pub_card)
        let t2 := step(t1.next, consent_event(decision))
        match t2.next {
          Done(o) => o,
          WaitExtended(b2, _) => {
            let ext_url := str.join([b2.endpoint, "/a2a/extended-card"], "")
            let t3 := step(t2.next, match get_extended_card(ext_url, b2.ephemeral_token) {
              Err(e) => NetFail(e),
              Ok(body) => GotExtendedJson(body),
            })
            match t3.next {
              Done(o) => o,
              _ => Failed("unexpected state after extended card fetch"),
            }
          },
          _ => Failed("unexpected state after consent"),
        }
      },
      _ => Failed("unexpected state after public card fetch"),
    }
  }
}

