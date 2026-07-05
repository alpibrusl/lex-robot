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
#
# Claims are signed as real JWTs (lex-jose, EdDSA) rather than a hand-rolled
# detached signature: `sign_claim`/`verify_claim` wrap `jwt.encode`/`jwt.decode`,
# so a "claim" is a genuine RFC 7519 token any JOSE-aware tool can inspect, and
# verification re-checks the protected header's `alg` (algorithm-substitution
# defense) as part of the standard, not as something this module has to get
# right on its own. src/control_plane.lex's tokens ride the same two functions.

import "std.str" as str

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-jose/jwt" as jwt

import "lex-jose/jwa" as jwa

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

# The canonical claim a submission signs: a JSON claims document binding
# identity, app, game, and trail-hash — the JWT's payload (RFC 7519 claims are
# a JSON object; this is a real one, not a private encoding).
fn claim_of(did :: Str, app :: Str, game :: Str, trail_hash :: Str) -> Str {
  str.join(["{\"did\":\"", did, "\",\"app\":\"", app, "\",\"game\":\"", game, "\",\"trail_hash\":\"", trail_hash, "\"}"], "")
}

# Sign a claim as a JWT (EdDSA) with the identity's secret; return the compact
# token (header.claims.signature, base64url).
fn sign_claim(secret :: Bytes, claim :: Str) -> [crypto] Result[Str, Str] {
  jwt.encode(jwa.EdDSA, secret, claim)
}

# Verify a JWT against a base64url public key and check its DECODED claims
# equal `claim` exactly — so a token whose outer fields were altered after
# signing (even if the bytes still parse as a JWT) is refused: what's checked
# is what was actually inside the signature, not what's merely presented
# alongside it. A malformed key or token is simply an invalid claim (false),
# never a crash.
fn verify_claim(pubkey_b64 :: Str, claim :: Str, token :: Str) -> [crypto] Bool {
  match crypto.base64url_decode(pubkey_b64) {
    Err(_) => false,
    Ok(pk) => match jwt.decode(jwa.EdDSA, pk, token) {
      Err(_) => false,
      Ok(decoded_claim) => decoded_claim == claim,
    },
  }
}

