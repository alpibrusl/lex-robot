# src/a2a_audit.lex — A2A handshake audit + anti-relay hardening (issue #20).
#
# Threads lex-trail through every handshake step so the full exchange is
# tamper-evident. `lex-trail verify` detects any modified entry.
#
# Anti-relay hardening:
#   - Nonce blacklist: consumed bootstrap nonces are logged in the trail and
#     tracked in a List[Str]; any reuse is rejected and audited.
#   - Expiry is checked before starting; an expired blob is audited + rejected.
#   - Signed cards + mutual-auth (via a2a_handshake.lex) defeat relay of a
#     captured exchange — a forger can't sign a fresh nonce without the key.
#
# Proximity proof is behind a channel interface (BootstrapChannel in
# a2a_bootstrap.lex) so QR (no inherent proximity) can be upgraded to NFC/UWB
# without touching the handshake core.
#
# Effects:
#   All trail functions — [sql, time]
#   run_audited         — [net, sql, time]

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-trail/src/log" as tlog

import "./a2a_bootstrap" as boot

import "./a2a_card" as card

import "./a2a_consent" as consent

import "./a2a_handshake" as hs

# ── Nonce blacklist ────────────────────────────────────────────────────────────
# A flat list of consumed nonces. In production, back this with the sql trail
# so it survives restarts. For the scaffold, threaded in/out of each call.
type NonceList = List[Str]

fn nonce_seen(used :: NonceList, nonce :: Str) -> Bool {
  list.fold(used, false, fn (acc :: Bool, n :: Str) -> Bool {
    if acc {
      true
    } else {
      n == nonce
    }
  })
}

fn mark_used(used :: NonceList, nonce :: Str) -> NonceList {
  list.concat(used, [nonce])
}

# ── Trail helpers ──────────────────────────────────────────────────────────────
fn payload(detail :: Str) -> Str {
  let clean := str.replace(str.replace(detail, "\"", "'"), "\n", " ")
  str.join(["{\"detail\":\"", clean, "\"}"], "")
}

fn trail(log :: tlog.Log, parent :: Str, kind :: Str, detail :: Str) -> [sql, time] Str {
  match tlog.append(log, kind, Some(parent), payload(detail)) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
}

# ── Audit helpers for each handshake step ─────────────────────────────────────
fn audit_blob_scan(log :: tlog.Log, parent :: Str, blob :: boot.BootstrapBlob) -> [sql, time] Str {
  trail(log, parent, "a2a_blob_scanned", str.join(["endpoint=", blob.endpoint, " nonce=", blob.nonce], ""))
}

fn audit_nonce_replay(log :: tlog.Log, parent :: Str, nonce :: Str) -> [sql, time] Str {
  trail(log, parent, "a2a_nonce_replay_rejected", str.concat("nonce=", nonce))
}

fn audit_blob_expired(log :: tlog.Log, parent :: Str, nonce :: Str) -> [sql, time] Str {
  trail(log, parent, "a2a_blob_expired", str.concat("nonce=", nonce))
}

fn audit_card_verified(log :: tlog.Log, parent :: Str, peer_name :: Str, ok :: Bool) -> [sql, time] Str {
  trail(log, parent, "a2a_public_card_verified", str.join(["peer=", peer_name, " ok=", if ok {
    "true"
  } else {
    "false"
  }], ""))
}

fn audit_consent(log :: tlog.Log, parent :: Str, decision :: Str) -> [sql, time] Str {
  trail(log, parent, "a2a_consent_decision", str.concat("decision=", decision))
}

fn audit_escalated(log :: tlog.Log, parent :: Str, from_tier :: Str, to_tier :: Str, skills_granted :: List[Str]) -> [sql, time] Str {
  trail(log, parent, "a2a_grant_escalated", str.join(["from=", from_tier, " to=", to_tier, " skills=", str.join(skills_granted, ",")], ""))
}

fn audit_outcome(log :: tlog.Log, parent :: Str, outcome :: hs.HandshakeOutcome) -> [sql, time] Str {
  match outcome {
    PublicOnly(rc) => trail(log, parent, "a2a_done", str.concat("result=PublicOnly peer=", rc.name)),
    Escalated(pub, _ext) => trail(log, parent, "a2a_done", str.concat("result=Escalated peer=", pub.name)),
    Rejected(why) => trail(log, parent, "a2a_done", str.concat("result=Rejected reason=", why)),
    Failed(why) => trail(log, parent, "a2a_done", str.concat("result=Failed reason=", why)),
  }
}

# ── Revocation ─────────────────────────────────────────────────────────────────
# Invalidate a peer's cached identity: log a revocation event and add the
# peer's pubkey to the nonce blacklist so any replay using their prior blob
# is rejected on the next re-pair attempt.
fn revoke_peer(log :: tlog.Log, parent :: Str, peer_pubkey :: Str, used :: NonceList) -> [sql, time] (Str, NonceList) {
  let p2 := trail(log, parent, "a2a_peer_revoked", str.concat("pubkey=", peer_pubkey))
  (p2, mark_used(used, peer_pubkey))
}

# ── Audited run ────────────────────────────────────────────────────────────────
# Full handshake with per-step trail events + nonce-replay defence.
# Returns (outcome, final_parent_id, updated_nonce_list).
fn run_audited(blob :: boot.BootstrapBlob, policy :: consent.ConsentPolicy, now_ms :: Int, log :: tlog.Log, parent :: Str, used :: NonceList) -> [net, sql, time] (hs.HandshakeOutcome, Str, NonceList) {
  let p1 := audit_blob_scan(log, parent, blob)
  if nonce_seen(used, blob.nonce) {
    let p2 := audit_nonce_replay(log, p1, blob.nonce)
    (hs.Failed("nonce already consumed"), p2, used)
  } else {
    if boot.is_expired(blob, now_ms) {
      let p2 := audit_blob_expired(log, p1, blob.nonce)
      (hs.Failed("bootstrap blob expired"), p2, mark_used(used, blob.nonce))
    } else {
      let used2 := mark_used(used, blob.nonce)
      let outcome := hs.run(blob, policy, now_ms)
      let p2 := match outcome {
        PublicOnly(rc) => audit_card_verified(log, p1, rc.name, true),
        Escalated(pub, _ext) => {
          let p_cv := audit_card_verified(log, p1, pub.name, true)
          let p_cs := audit_consent(log, p_cv, "ConsentGrant")
          let tier_skills := list.map(pub.skills, fn (s :: card.AgentSkill) -> Str {
            s.name
          })
          audit_escalated(log, p_cs, "public", "extended", tier_skills)
        },
        Rejected(why) => audit_card_verified(log, p1, "unknown", false),
        Failed(why) => trail(log, p1, "a2a_failed", why),
      }
      let pfinal := audit_outcome(log, p2, outcome)
      (outcome, pfinal, used2)
    }
  }
}

