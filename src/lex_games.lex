# src/lex_games.lex — a tiny harness for server-authoritative turn games.
#
# The two cross-cutting concerns that make a Lex game cheat-resistant and
# verifiable live here, game-agnostic; a specific game plugs in its own board
# and rules (see examples/ttt.lex):
#
#   gate()    — capability + turn enforcement. A connection controls exactly one
#               side; it CANNOT submit a move as another side, nor out of turn.
#               This is the "anti-cheat by construction" property: the illegal
#               call is refused before any game logic runs.
#   record()  — append each APPLIED move to a hash-chained lex-trail log, so the
#               whole match is a tamper-evident, replayable record.
#
# Effects: gate is pure; record is [sql, time].

import "std.str" as str

import "std.list" as list

import "std.bytes" as bytes

import "std.int" as int

import "std.crypto" as crypto

import "lex-trail/log" as trail

import "lex-trail/event" as ev

# Result of the capability + turn check.
type MoveCheck = MoveOk | MoveReject(Str)

# Capability + turn gate. `session_side` is the side this connection is allowed
# to control (its capability); `move_by` is the side the move claims to act as;
# `turn` is whose move it currently is.
fn gate(session_side :: Str, move_by :: Str, turn :: Str) -> MoveCheck {
  if move_by != session_side {
    MoveReject(str.join(["capability denied: this player controls ", session_side, ", cannot act as ", move_by], ""))
  } else {
    if move_by != turn {
      MoveReject(str.join(["out of turn: it is ", turn, "'s move"], ""))
    } else {
      MoveOk
    }
  }
}

fn is_ok(c :: MoveCheck) -> Bool {
  match c { MoveOk => true, MoveReject(_) => false }
}

fn reason(c :: MoveCheck) -> Str {
  match c { MoveOk => "", MoveReject(r) => r }
}

# Append an applied move to the hash-chained replay log; returns the new chain
# head (use it as the parent of the next move). On error the parent is unchanged.
fn record(log :: trail.Log, parent :: Str, payload :: Str) -> [sql, time] Str {
  let par := if str.is_empty(parent) { None } else { Some(parent) }
  match trail.append(log, "move", par, payload) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
}

# ── Capability tokens (the side grant is a real Ed25519-signed artifact) ──────
# issue_token signs a grant for a side; token_side verifies it and recovers the
# side. A forged or edited token fails verification → no side → the gate refuses.
# Format: base64url("game:<side>") "." base64url(signature).
fn issue_token(secret :: Bytes, side :: Str) -> Str {
  let payload := str.concat("game:", side)
  match crypto.ed25519_sign(secret, bytes.from_str(payload)) {
    Ok(sig) => str.join([crypto.base64url_encode(bytes.from_str(payload)), ".", crypto.base64url_encode(sig)], ""),
    Err(_)  => "",
  }
}

fn token_side(pubkey_b64 :: Str, token :: Str) -> Str {
  let parts := str.split(token, ".")
  match list.head(parts) {
    None => "",
    Some(pb) => match list.head(list.tail(parts)) {
      None => "",
      Some(sb) => verify_side(pubkey_b64, pb, sb),
    },
  }
}

fn verify_side(pubkey_b64 :: Str, pb :: Str, sb :: Str) -> Str {
  match crypto.base64url_decode(pb) {
    Err(_) => "",
    Ok(payb) => match bytes.to_str(payb) {
      Err(_) => "",
      Ok(payload) => match crypto.base64url_decode(pubkey_b64) {
        Err(_) => "",
        Ok(pk) => match crypto.base64url_decode(sb) {
          Err(_) => "",
          Ok(sig) => if crypto.ed25519_verify(pk, bytes.from_str(payload), sig) {
            match str.strip_prefix(payload, "game:") { Some(s) => s, None => "" }
          } else {
            ""
          },
        },
      },
    },
  }
}

# ── Hardened, match-bound tokens ──────────────────────────────────────────────
# The plain token above is a reusable bearer grant for a side. A hardened token
# also binds the grant to a specific MATCH and an EXPIRY, so a token issued for
# one match (or after it ended) cannot be replayed against another. The payload
# is "game:<side>:<match_id>:<expires_at_ms>"; verification additionally requires
# the match to match and the token to be unexpired.
fn issue_match_token(secret :: Bytes, side :: Str, match_id :: Str, expires_at_ms :: Int) -> Str {
  let payload := str.join(["game:", side, ":", match_id, ":", int_to_str(expires_at_ms)], "")
  match crypto.ed25519_sign(secret, bytes.from_str(payload)) {
    Ok(sig) => str.join([crypto.base64url_encode(bytes.from_str(payload)), ".", crypto.base64url_encode(sig)], ""),
    Err(_)  => "",
  }
}

# Recover the side from a hardened token, but only if the signature verifies, the
# match_id matches, and now_ms < expiry. Otherwise "" (the gate then refuses).
fn match_token_side(pubkey_b64 :: Str, token :: Str, match_id :: Str, now_ms :: Int) -> Str {
  let parts := str.split(token, ".")
  match list.head(parts) {
    None => "",
    Some(pb) => match list.head(list.tail(parts)) {
      None => "",
      Some(sb) => verify_match(pubkey_b64, pb, sb, match_id, now_ms),
    },
  }
}

fn verify_match(pubkey_b64 :: Str, pb :: Str, sb :: Str, match_id :: Str, now_ms :: Int) -> Str {
  match crypto.base64url_decode(pb) {
    Err(_) => "",
    Ok(payb) => match bytes.to_str(payb) {
      Err(_) => "",
      Ok(payload) => match crypto.base64url_decode(pubkey_b64) {
        Err(_) => "",
        Ok(pk) => match crypto.base64url_decode(sb) {
          Err(_) => "",
          Ok(sig) => if crypto.ed25519_verify(pk, bytes.from_str(payload), sig) {
            claim_side(payload, match_id, now_ms)
          } else {
            ""
          },
        },
      },
    },
  }
}

# Parse "game:<side>:<match_id>:<expiry>" and enforce match + expiry.
fn claim_side(payload :: Str, match_id :: Str, now_ms :: Int) -> Str {
  let fields := str.split(payload, ":")
  let tag := nth_or(fields, 0)
  let side := nth_or(fields, 1)
  let mid := nth_or(fields, 2)
  let exp := nth_or(fields, 3)
  if tag == "game" and mid == match_id and now_ms < str_to_int_or(exp, 0) { side } else { "" }
}

# i-th element of a Str list, or "" if out of range (no list.drop dependency).
fn nth_or(xs :: List[Str], i :: Int) -> Str {
  if i <= 0 {
    match list.head(xs) { Some(s) => s, None => "" }
  } else {
    nth_or(list.tail(xs), i - 1)
  }
}

fn int_to_str(n :: Int) -> Str { int.to_str(n) }
fn str_to_int_or(s :: Str, d :: Int) -> Int { match str.to_int(s) { Some(n) => n, None => d } }

# ── Replay / verify ───────────────────────────────────────────────────────────
# Re-walk a match's recorded events and confirm every one is content-valid: each
# event's id is the hash of (kind, parent, payload, ts), so any edit to a recorded
# move — or to its parent link — breaks is_valid. Returns (count, valid): valid is
# false the moment any link is tampered. This is the demonstrable half of
# "tamper-evident": not asserted, re-checked.
type Verdict = { count :: Int, valid :: Bool }
fn verify_log(log :: trail.Log) -> [sql] Verdict {
  match trail.range(log, 0, 9999999999999) {
    Err(_) => { count: 0, valid: false },
    Ok(evs) => list.fold(evs, { count: 0, valid: true }, fn (acc :: Verdict, e :: ev.Event) -> Verdict {
      { count: acc.count + 1, valid: acc.valid and ev.is_valid(e) }
    }),
  }
}

# All recorded events oldest-first (or []). The basis for REPLAY: a game's
# verifier folds these recorded moves through its own deterministic rules to
# recompute the authoritative score — the score is never trusted from a client.
# verify_log proves the chain wasn't tampered; replay proves what the score IS.
fn all_events(log :: trail.Log) -> [sql] List[ev.Event] {
  match trail.range(log, 0, 9999999999999) { Err(_) => [], Ok(evs) => evs }
}
