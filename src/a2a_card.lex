# src/a2a_card.lex — A2A Agent Card types + signing/verification (issue #17).
#
# Two-tier card model (A2A spec §agent-discovery):
#   Public   — served at /.well-known/agent-card.json; limited skill list.
#   Extended — from {endpoint}/authenticatedExtendedCard; strict superset of
#              Public skills, returned only after the peer authenticates.
#
# Cards are ed25519-signed by the agent's key. `verify_card` checks the
# signature against the `peer_pubkey` delivered in the bootstrap blob (§#16),
# so a fetched card is never trusted blindly — tampering or wrong-key fails.
#
# All functions are pure (no effects). Signing/verification use std.crypto
# ed25519 builtins which are deterministic (RFC 8032) — no [random] needed.

import "std.str" as str

import "std.bytes" as bytes

import "std.list" as list

import "std.crypto" as crypto

# ── Types ──────────────────────────────────────────────────────────────────────
type CardTier = Public | Extended

type AgentSkill = { name :: Str, description :: Str }

type RobotCard = { name :: Str, endpoint :: Str, pubkey_b64 :: Str, tier :: CardTier, skills :: List[AgentSkill], supports_extended :: Bool }

# ── JSON helpers (std-only; no lex-schema dep) ─────────────────────────────────
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

fn jstr(json :: Str, key :: Str, dflt :: Str) -> Str {
  let seg := nth1(str.split(json, key))
  let tok := head_or(str.split(seg, "\""), seg)
  if str.is_empty(tok) {
    dflt
  } else {
    tok
  }
}

# ── Serialisation ──────────────────────────────────────────────────────────────
fn tier_str(tier :: CardTier) -> Str {
  match tier {
    Public => "public",
    Extended => "extended",
  }
}

fn bool_str(b :: Bool) -> Str {
  if b {
    "true"
  } else {
    "false"
  }
}

fn skill_to_json(s :: AgentSkill) -> Str {
  str.join(["{\"name\":\"", s.name, "\",\"description\":\"", s.description, "\"}"], "")
}

fn skills_to_json(skills :: List[AgentSkill]) -> Str {
  str.join(["[", str.join(list.map(skills, skill_to_json), ","), "]"], "")
}

# Canonical JSON for a RobotCard (deterministic field order — used as the
# signing payload so both sides hash the same bytes).
fn card_to_json(c :: RobotCard) -> Str
  examples {
    card_to_json({ name: "R", endpoint: "http://r:8900", pubkey_b64: "AA", tier: Public, skills: [], supports_extended: false }) => "{\"name\":\"R\",\"endpoint\":\"http://r:8900\",\"pubkey_b64\":\"AA\",\"tier\":\"public\",\"supports_extended\":false,\"skills\":[]}"
  }
{
  str.join(["{\"name\":\"", c.name, "\",\"endpoint\":\"", c.endpoint, "\",\"pubkey_b64\":\"", c.pubkey_b64, "\",\"tier\":\"", tier_str(c.tier), "\",\"supports_extended\":", bool_str(c.supports_extended), ",\"skills\":", skills_to_json(c.skills), "}"], "")
}

# ── Signing / verification ─────────────────────────────────────────────────────
# Sign a canonical card JSON string; return the ed25519 signature as base64url.
fn sign_card(card_json :: Str, secret :: Bytes) -> Result[Str, Str] {
  match crypto.ed25519_sign(secret, bytes.from_str(card_json)) {
    Ok(sig) => Ok(crypto.base64url_encode(sig)),
    Err(e) => Err(e),
  }
}

# Verify a base64url signature over `card_json` against a base64url public key.
# Returns false on any decode failure, wrong key, or tampered JSON.
fn verify_card(card_json :: Str, pubkey_b64 :: Str, sig_b64 :: Str) -> Bool {
  match crypto.base64url_decode(pubkey_b64) {
    Err(_) => false,
    Ok(pk) => match crypto.base64url_decode(sig_b64) {
      Err(_) => false,
      Ok(sig) => crypto.ed25519_verify(pk, bytes.from_str(card_json), sig),
    },
  }
}

# ── Signing round-trip acceptance tests ────────────────────────────────────────
fn sign_verify_roundtrip() -> Bool
  examples {
    sign_verify_roundtrip() => true
  }
{
  let secret := bytes.from_str("01234567890123456789012345678901")
  let card := { name: "robot-A", endpoint: "http://robot-a:8900", pubkey_b64: "", tier: Public, skills: [], supports_extended: false }
  let json := card_to_json(card)
  match crypto.ed25519_public_key(secret) {
    Err(_) => false,
    Ok(pk) => {
      let pk_b64 := crypto.base64url_encode(pk)
      match sign_card(json, secret) {
        Err(_) => false,
        Ok(sig_b64) => verify_card(json, pk_b64, sig_b64),
      }
    },
  }
}

fn sign_tampered_fails() -> Bool
  examples {
    sign_tampered_fails() => true
  }
{
  let secret := bytes.from_str("01234567890123456789012345678901")
  let json := card_to_json({ name: "A", endpoint: "http://a:8900", pubkey_b64: "", tier: Public, skills: [], supports_extended: false })
  match crypto.ed25519_public_key(secret) {
    Err(_) => false,
    Ok(pk) => {
      let pk_b64 := crypto.base64url_encode(pk)
      match sign_card(json, secret) {
        Err(_) => false,
        Ok(sig_b64) => not verify_card(str.concat(json, "x"), pk_b64, sig_b64),
      }
    },
  }
}

fn sign_wrong_key_fails() -> Bool
  examples {
    sign_wrong_key_fails() => true
  }
{
  let secret1 := bytes.from_str("01234567890123456789012345678901")
  let secret2 := bytes.from_str("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ")
  let json := card_to_json({ name: "A", endpoint: "http://a:8900", pubkey_b64: "", tier: Public, skills: [], supports_extended: false })
  match crypto.ed25519_public_key(secret2) {
    Err(_) => false,
    Ok(pk2) => {
      let pk2_b64 := crypto.base64url_encode(pk2)
      match sign_card(json, secret1) {
        Err(_) => false,
        Ok(sig_b64) => not verify_card(json, pk2_b64, sig_b64),
      }
    },
  }
}

# ── Parsing ────────────────────────────────────────────────────────────────────
fn tier_of(s :: Str) -> Option[CardTier] {
  if s == "public" {
    Some(Public)
  } else {
    if s == "extended" {
      Some(Extended)
    } else {
      None
    }
  }
}

# Parse individual skill objects from the portion of card JSON after "skills":[
fn parse_skills(after_skills_bracket :: Str) -> List[AgentSkill] {
  let segs := list.tail(str.split(after_skills_bracket, "{\"name\":\""))
  list.fold(segs, [], fn (acc :: List[AgentSkill], seg :: Str) -> List[AgentSkill] {
    let name := head_or(str.split(seg, "\""), seg)
    let desc := jstr(seg, "\"description\":\"", "")
    if str.is_empty(name) {
      acc
    } else {
      list.concat(acc, [{ name: name, description: desc }])
    }
  })
}

# Parse a RobotCard from a canonical JSON string (as produced by card_to_json).
# Returns Err on missing required fields or unknown tier.
fn parse_card(json :: Str) -> Result[RobotCard, Str]
  examples {
    parse_card(card_to_json({ name: "robot-A", endpoint: "http://robot-a:8900", pubkey_b64: "AAAA", tier: Public, skills: [{ name: "move_to", description: "Move arm to pose" }], supports_extended: true })) => Ok({ name: "robot-A", endpoint: "http://robot-a:8900", pubkey_b64: "AAAA", tier: Public, skills: [{ name: "move_to", description: "Move arm to pose" }], supports_extended: true })
  }
{
  let name := jstr(json, "\"name\":\"", "")
  let endpoint := jstr(json, "\"endpoint\":\"", "")
  let pk_b64 := jstr(json, "\"pubkey_b64\":\"", "")
  let tier_s := jstr(json, "\"tier\":\"", "")
  let sup_ext := str.contains(json, "\"supports_extended\":true") or str.contains(json, "\"supports_extended\": true")
  let after_sk := nth1(str.split(json, "\"skills\":["))
  let skills := parse_skills(after_sk)
  if str.is_empty(name) {
    Err("missing name")
  } else {
    if str.is_empty(endpoint) {
      Err("missing endpoint")
    } else {
      match tier_of(tier_s) {
        None => Err(str.concat("unknown tier: ", tier_s)),
        Some(tier) => Ok({ name: name, endpoint: endpoint, pubkey_b64: pk_b64, tier: tier, skills: skills, supports_extended: sup_ext }),
      }
    }
  }
}

# ── Extended-card superset check ───────────────────────────────────────────────
fn contains_skill(names :: List[Str], name :: Str) -> Bool {
  list.fold(names, false, fn (acc :: Bool, n :: Str) -> Bool {
    if acc {
      true
    } else {
      n == name
    }
  })
}

# True iff every skill in `public_card` is also in `extended_card`.
# A2A requires Extended to be a strict superset of Public skills.
fn is_superset(extended :: List[AgentSkill], public :: List[AgentSkill]) -> Bool
  examples {
    is_superset([{ name: "move_to", description: "" }, { name: "grasp", description: "" }], [{ name: "move_to", description: "" }]) => true,
    is_superset([{ name: "move_to", description: "" }], [{ name: "move_to", description: "" }, { name: "grasp", description: "" }]) => false,
    is_superset([], []) => true
  }
{
  let ext_names := list.map(extended, fn (s :: AgentSkill) -> Str {
    s.name
  })
  list.fold(public, true, fn (acc :: Bool, s :: AgentSkill) -> Bool {
    if not acc {
      false
    } else {
      contains_skill(ext_names, s.name)
    }
  })
}

