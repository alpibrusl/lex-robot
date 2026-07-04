# src/identity.lex — durable did:lex identity (platform kernel, #73).
#
# Today reputation is DID-keyed but attribution is merely *claimed*: a submission
# names a did:lex and the registry trusts that the named agent produced it. The
# kernel needs identity an agent *owns* — so a submission is SIGNED, not claimed.
#
# An identity is an ed25519 keypair. did:lex:agent:<name> is the handle; the key
# is what makes it ownable. A reputation submission signs a canonical claim that
# binds the identity, the app, the game/verifier, and the HASH of the exact trail
# — so a forged, swapped, or tampered trail breaks the signature, and only the
# holder of the did's key can earn under it. The registry (examples/agent_registry)
# binds a did to its key on first sight (trust-on-first-use) and thereafter
# refuses any submission signed by a different key: impersonation earns nothing.
#
# ed25519 is deterministic (RFC 8032) — no [random] — so a seed reproduces a
# keypair for demos; in production the secret is generated once and kept.

import "std.str" as str

import "std.bytes" as bytes

import "std.crypto" as crypto

# An owned identity: the handle, its public key, and the secret the holder keeps.
type Ident = { did :: Str, pubkey_b64 :: Str, secret :: Bytes }

fn did_of(name :: Str) -> Str {
  str.concat("did:lex:agent:", name)
}

# Deterministic keypair from a seed.
fn derive(name :: Str, seed :: Str) -> [crypto] Result[Ident, Str] {
  let secret := crypto.sha256(bytes.from_str(seed))
  match crypto.ed25519_public_key(secret) {
    Err(e) => Err(e),
    Ok(pk) => Ok({ did: did_of(name), pubkey_b64: crypto.base64url_encode(pk), secret: secret }),
  }
}

# A stable string digest of a trail's bytes (base64url of sha256).
fn hash_trail(content :: Str) -> [crypto] Str {
  crypto.base64url_encode(crypto.sha256(bytes.from_str(content)))
}

# The canonical claim a submission signs: identity | app | game | trail-hash.
fn claim_of(did :: Str, app :: Str, game :: Str, trail_hash :: Str) -> Str {
  str.join([did, "|", app, "|", game, "|", trail_hash], "")
}

# Sign a claim with the identity's secret; return the base64url signature.
fn sign_claim(secret :: Bytes, claim :: Str) -> [crypto] Result[Str, Str] {
  match crypto.ed25519_sign(secret, bytes.from_str(claim)) {
    Err(e) => Err(e),
    Ok(sig) => Ok(crypto.base64url_encode(sig)),
  }
}

# Verify a base64url signature over `claim` against a base64url public key. A
# malformed key or signature is simply an invalid signature (false), never a crash.
fn verify_claim(pubkey_b64 :: Str, claim :: Str, sig_b64 :: Str) -> [crypto] Bool {
  match crypto.base64url_decode(pubkey_b64) {
    Err(_) => false,
    Ok(pk) => match crypto.base64url_decode(sig_b64) {
      Err(_) => false,
      Ok(sig) => crypto.ed25519_verify(pk, bytes.from_str(claim), sig),
    },
  }
}

