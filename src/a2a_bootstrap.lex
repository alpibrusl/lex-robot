# src/a2a_bootstrap.lex — A2A OOB bootstrap channel (issue #16).
#
# The first contact between two robots happens out-of-band: one displays a
# BootstrapBlob (encoded as compact base64url JSON), the other captures it.
# QR code is the primary transport via the sidecar; NFC/BLE/UWB/visual-fiducial
# drop in later through the BootstrapChannel variant without touching the
# rest of the handshake.
#
# Design: the blob only carries what is needed to START a verifiable exchange.
# Card contents and key-agreement live in a2a_card.lex and a2a_handshake.lex.
#
# Effects:
#   emit_qr / receive_qr — [net]  (sidecar HTTP render_qr / scan_qr)
#   receive_qr           — [net, sense]
#   All encode / decode  — pure (no effects)

import "std.str" as str

import "std.bytes" as bytes

import "std.list" as list

import "std.int" as int

import "std.crypto" as crypto

import "./types" as t

import "./client" as client

# ── Bootstrap blob ─────────────────────────────────────────────────────────────
# Minimum payload to start a verifiable A2A exchange — small enough for one QR
# scan, momentarily visible, never carries the full card.
type BootstrapBlob = { endpoint :: Str, ephemeral_token :: Str, peer_pubkey :: Str, nonce :: Str, expires_at :: Int }

# ── Channel variant (pluggable transport) ──────────────────────────────────────
# QrChannel:     display/scan a QR code via the sidecar (primary path).
# CachedChannel: reuse a previously received blob — skip the QR on re-pair.
type BootstrapChannel = QrChannel | CachedChannel(BootstrapBlob)

fn nth1(xs :: List[Str]) -> Str {
  match list.head(list.tail(xs)) {
    Some(v) => v,
    None => "",
  }
}

fn head_or(xs :: List[Str], dflt :: Str) -> Str {
  match list.head(xs) {
    Some(v) => v,
    None => dflt,
  }
}

# Extract a quoted-string field from a flat JSON object.
# key must include the opening quote, e.g. "\"endpoint\":\"".
fn jstr(json :: Str, key :: Str, dflt :: Str) -> Str {
  let seg := nth1(str.split(json, key))
  let tok := head_or(str.split(seg, "\""), seg)
  if str.is_empty(tok) {
    dflt
  } else {
    tok
  }
}

# Extract an integer field from a flat JSON object.
fn jint(json :: Str, key :: Str, dflt :: Int) -> Int {
  let seg := nth1(str.split(json, key))
  let tok := head_or(str.split(head_or(str.split(seg, ","), seg), "}"), seg)
  match str.to_int(str.trim(tok)) {
    Some(v) => v,
    None => dflt,
  }
}

# ── Encode / decode ────────────────────────────────────────────────────────────
# Canonical JSON for a blob (deterministic field order, no spaces).
fn blob_to_json(b :: BootstrapBlob) -> Str {
  str.join(["{\"endpoint\":\"", b.endpoint, "\",\"ephemeral_token\":\"", b.ephemeral_token, "\",\"peer_pubkey\":\"", b.peer_pubkey, "\",\"nonce\":\"", b.nonce, "\",\"expires_at\":", int.to_str(b.expires_at), "}"], "")
}

# Encode: BootstrapBlob → base64url(canonical-JSON). One QR scan worth of data.
fn encode(b :: BootstrapBlob) -> Str {
  crypto.base64url_encode(bytes.from_str(blob_to_json(b)))
}

# Decode: base64url → BootstrapBlob. Returns Err on invalid base64url, bad UTF-8,
# or a missing `endpoint` field.
fn decode(s :: Str) -> Result[BootstrapBlob, Str]
  examples {
    decode("") => Err("empty blob"),
    decode(encode({ endpoint: "http://robot-b:8900", ephemeral_token: "tok123", peer_pubkey: "AAABBB", nonce: "n1", expires_at: 9999999 })) => Ok({ endpoint: "http://robot-b:8900", ephemeral_token: "tok123", peer_pubkey: "AAABBB", nonce: "n1", expires_at: 9999999 })
  }
{
  if str.is_empty(s) {
    Err("empty blob")
  } else {
    match crypto.base64url_decode(s) {
      Err(e) => Err(str.concat("base64url: ", e)),
      Ok(bs) => match bytes.to_str(bs) {
        Err(e) => Err(str.concat("utf8: ", e)),
        Ok(json) => {
          let ep := jstr(json, "\"endpoint\":\"", "")
          let tok := jstr(json, "\"ephemeral_token\":\"", "")
          let pk := jstr(json, "\"peer_pubkey\":\"", "")
          let nc := jstr(json, "\"nonce\":\"", "")
          let exp := jint(json, "\"expires_at\":", 0)
          if str.is_empty(ep) {
            Err("missing endpoint")
          } else {
            Ok({ endpoint: ep, ephemeral_token: tok, peer_pubkey: pk, nonce: nc, expires_at: exp })
          }
        },
      },
    }
  }
}

# ── Expiry ─────────────────────────────────────────────────────────────────────
fn is_expired(b :: BootstrapBlob, now_ms :: Int) -> Bool
  examples {
    is_expired({ endpoint: "x", ephemeral_token: "t", peer_pubkey: "k", nonce: "n", expires_at: 1000 }, 999) => false,
    is_expired({ endpoint: "x", ephemeral_token: "t", peer_pubkey: "k", nonce: "n", expires_at: 1000 }, 1001) => true,
    is_expired({ endpoint: "x", ephemeral_token: "t", peer_pubkey: "k", nonce: "n", expires_at: 1000 }, 1000) => false
  }
{
  now_ms > b.expires_at
}

# ── QR sidecar calls ──────────────────────────────────────────────────────────
# render_qr: encode blob → ask sidecar to display a QR code containing it.
fn emit_qr(r :: t.Robot, b :: BootstrapBlob) -> [net] Result[Str, Str] {
  let payload := encode(b)
  client.call(r.sidecar_url, "render_qr", str.join(["{\"payload\":\"", payload, "\"}"], ""))
}

# scan_qr: ask the sidecar camera to capture a QR code and decode the blob.
fn receive_qr(r :: t.Robot) -> [net, sense] Result[BootstrapBlob, Str] {
  match client.call(r.sidecar_url, "scan_qr", "{}") {
    Err(e) => Err(e),
    Ok(resp) => {
      let payload := jstr(resp, "\"payload\":\"", "")
      if str.is_empty(payload) {
        Err("empty QR payload from sidecar")
      } else {
        decode(payload)
      }
    },
  }
}

# receive_cached: skip the QR entirely; return the stored blob unchanged.
# Used when the two robots have paired before and kept each other's identity.
fn receive_cached(blob :: BootstrapBlob) -> Result[BootstrapBlob, Str]
  examples {
    receive_cached({ endpoint: "http://robot-a:8900", ephemeral_token: "t", peer_pubkey: "k", nonce: "n", expires_at: 0 }) => Ok({ endpoint: "http://robot-a:8900", ephemeral_token: "t", peer_pubkey: "k", nonce: "n", expires_at: 0 })
  }
{
  Ok(blob)
}

