# src/control_plane.lex — issue / scope / revoke capability tokens (platform
# kernel, #73). Pure: no effects except [crypto] for signing/verification.
#
# Today a Grant is a literal hardcoded into whichever demo constructs it — there
# is no notion of who authorized it, for how long, or how to take it back. This
# adds the missing verb set: an ISSUER (a did:lex, holding a signing key — see
# src/identity.lex) grants a scoped, time-boxed, revocable TOKEN to a SUBJECT
# did:lex. The token carries the actual Grant (workspace box, force/grip caps,
# skill list — grant.lex's existing authority envelope, unchanged), so nothing
# about capability CHECKING at the point of actuation changes: the control
# plane governs how a Grant came to exist, not what it permits.
#
# Composability, not replacement: `verify` returns the embedded Grant only once
# the TOKEN's own authority checks out (signature, subject match, unexpired, not
# revoked). The caller still runs every existing grant.lex check (in_workspace,
# clamp_force, …) against that Grant before actuating — a validly-issued token
# for the wrong workspace still gets its commands refused at the physical layer.
# The two layers answer different questions: "was this agent ever handed this
# authority, by whom, and is it still live?" vs. "does this specific command
# stay inside that authority?"
#
# Revocation is a list of revoked token_ids the verifier is handed at check
# time — the control plane doesn't need to keep the list itself; whoever calls
# `verify` (a gate, a registry, a review dashboard) supplies the current
# revocation state, exactly like the reputation registry supplies prior state.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.json" as json

import "./types" as t

import "./identity" as id

# A capability token: `grant` is the actual authority envelope (grant.lex's
# Grant, unchanged); everything else is the control plane's own bookkeeping.
type Token = { token_id :: Str, subject_did :: Str, issuer_did :: Str, grant :: t.Grant, expires_at_ms :: Int, sig :: Str }

# The canonical bytes the issuer signs — every field the verifier re-checks is
# IN the claim, so a token can't be replayed for a different subject, issuer,
# grant, or expiry without invalidating the signature.
fn claim_of(token_id :: Str, subject_did :: Str, issuer_did :: Str, grant :: t.Grant, expires_at_ms :: Int) -> Str {
  str.join([token_id, "|", subject_did, "|", issuer_did, "|", json.stringify(grant), "|", int.to_str(expires_at_ms)], "")
}

# Issue a token: the issuer signs a claim binding {token_id, subject, grant,
# expiry}. `now_ms` + `ttl_ms` are supplied by the caller so this stays pure.
fn issue(issuer :: id.Ident, subject_did :: Str, token_id :: Str, grant :: t.Grant, now_ms :: Int, ttl_ms :: Int) -> [crypto] Result[Token, Str] {
  let expires := now_ms + ttl_ms
  let claim := claim_of(token_id, subject_did, issuer.did, grant, expires)
  match id.sign_claim(issuer.secret, claim) {
    Err(e) => Err(e),
    Ok(sig) => Ok({ token_id: token_id, subject_did: subject_did, issuer_did: issuer.did, grant: grant, expires_at_ms: expires, sig: sig }),
  }
}

# Re-derive whether a presented token is currently authoritative:
#   1. it was issued to THIS subject (a token for another agent is refused —
#      possession of the bytes is not possession of the authority);
#   2. its token_id is not in the caller-supplied revocation list;
#   3. it has not expired as of `now_ms`;
#   4. the issuer's signature over the reconstructed claim is valid.
# Only if all four hold does the embedded Grant become usable — the caller
# still runs it through grant.lex's own checks before actuating anything.
fn verify(issuer_pubkey_b64 :: Str, expected_subject_did :: Str, tok :: Token, now_ms :: Int, revoked_ids :: List[Str]) -> [crypto] Result[t.Grant, Str] {
  if tok.subject_did != expected_subject_did {
    Err("token not issued to this subject")
  } else {
    if list_contains(revoked_ids, tok.token_id) {
      Err("token revoked")
    } else {
      if now_ms >= tok.expires_at_ms {
        Err("token expired")
      } else {
        let claim := claim_of(tok.token_id, tok.subject_did, tok.issuer_did, tok.grant, tok.expires_at_ms)
        if id.verify_claim(issuer_pubkey_b64, claim, tok.sig) {
          Ok(tok.grant)
        } else {
          Err("signature invalid")
        }
      }
    }
  }
}

fn list_contains(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, s :: Str) -> Bool {
    acc or s == x
  })
}

