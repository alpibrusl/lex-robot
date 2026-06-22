# src/a2a_consent.lex — A2A consent gate + tiered grant escalation (issue #19).
#
# The decision to share more capabilities is deterministic and rule-based — no
# model in the security path so every trust decision is auditable and reproducible.
#
# ConsentPolicy carries the local rules; `decide` runs them against the peer's
# verified card; `escalate` builds the peer-session Grant by INTERSECTING with
# the local ceiling — escalation can only NARROW, never amplify.
#
# All functions are pure (no effects).

import "std.str" as str

import "std.list" as list

import "./types" as t

import "./grant" as grant

import "./a2a_card" as card

# ── Policy type ────────────────────────────────────────────────────────────────
type ConsentPolicy = { allowed_pubkeys :: List[Str], allowed_skills :: List[Str], max_tier :: card.CardTier, require_https :: Bool, max_budget_actions :: Int, max_budget_ms :: Int }

# ── Consent decision ───────────────────────────────────────────────────────────
# ConsentGrant       — proceed with the peer's full requested tier.
# DowngradeToPublic  — capped at the public tier (max_tier policy override).
# Refuse(why)        — handshake terminates; no capabilities shared.
type ConsentDecision = ConsentGrant | DowngradeToPublic | Refuse(Str)

fn contains_str(xs :: List[Str], s :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == s
    }
  })
}

fn all_skills_allowed(policy :: ConsentPolicy, skills :: List[card.AgentSkill]) -> Option[Str] {
  list.fold(skills, None, fn (acc :: Option[Str], sk :: card.AgentSkill) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => if list.is_empty(policy.allowed_skills) {
        None
      } else {
        if contains_str(policy.allowed_skills, sk.name) {
          None
        } else {
          Some(str.concat("skill not in policy allowlist: ", sk.name))
        }
      },
    }
  })
}

# ── decide ─────────────────────────────────────────────────────────────────────
# Pure, total, deterministic — same card + same policy always yields the same
# decision. Checks in priority order: pubkey allowlist, HTTPS, skill allowlist,
# tier ceiling.
fn decide(policy :: ConsentPolicy, peer :: card.RobotCard) -> ConsentDecision
  examples {
    decide({ allowed_pubkeys: ["known-key"], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 10, max_budget_ms: 30000 }, { name: "X", endpoint: "http://x:8900", pubkey_b64: "other-key", tier: card.Public, skills: [], supports_extended: false }) => Refuse("peer pubkey not in allowlist"),
    decide({ allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 10, max_budget_ms: 30000 }, { name: "Y", endpoint: "http://y:8900", pubkey_b64: "any-key", tier: card.Public, skills: [], supports_extended: false }) => ConsentGrant,
    decide({ allowed_pubkeys: [], allowed_skills: ["move_to"], max_tier: card.Extended, require_https: false, max_budget_actions: 10, max_budget_ms: 30000 }, { name: "Z", endpoint: "http://z:8900", pubkey_b64: "k", tier: card.Public, skills: [{ name: "move_to", description: "" }, { name: "self_destruct", description: "" }], supports_extended: false }) => Refuse("skill not in policy allowlist: self_destruct"),
    decide({ allowed_pubkeys: [], allowed_skills: [], max_tier: card.Public, require_https: false, max_budget_actions: 10, max_budget_ms: 30000 }, { name: "W", endpoint: "http://w:8900", pubkey_b64: "k", tier: card.Extended, skills: [], supports_extended: true }) => DowngradeToPublic
  }
{
  if not list.is_empty(policy.allowed_pubkeys) and not contains_str(policy.allowed_pubkeys, peer.pubkey_b64) {
    Refuse("peer pubkey not in allowlist")
  } else {
    if policy.require_https and str.starts_with(peer.endpoint, "http://") {
      Refuse("peer endpoint is not HTTPS")
    } else {
      match all_skills_allowed(policy, peer.skills) {
        Some(reason) => Refuse(reason),
        None => match policy.max_tier {
          Public => DowngradeToPublic,
          Extended => ConsentGrant,
        },
      }
    }
  }
}

# ── escalate ───────────────────────────────────────────────────────────────────
# Build the peer-session Grant from a base ceiling and the peer's verified card.
# SAFETY INVARIANT: the result is a strict subset of `ceiling` — force/velocity/
# workspace bounds are taken directly from ceiling and never widened.
#
# Skill set = intersection of ceiling.skills ∩ peer.skills (only what both agree).
# Budget   = min(ceiling.budget_*, policy.max_budget_*) — the tighter of the two.
fn escalate(ceiling :: t.Grant, peer :: card.RobotCard, policy :: ConsentPolicy) -> t.Grant
  examples {
    escalate({ skills: ["move_to", "grasp"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.5, max_force: 10.0, max_grip_force: 15.0, budget_actions: 20, budget_wall_ms: 60000 }, { name: "P", endpoint: "http://p:8900", pubkey_b64: "k", tier: card.Extended, skills: [{ name: "move_to", description: "" }, { name: "self_destruct", description: "" }], supports_extended: false }, { allowed_pubkeys: [], allowed_skills: [], max_tier: card.Extended, require_https: false, max_budget_actions: 5, max_budget_ms: 10000 }) => { skills: ["move_to"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 }, max_velocity: 0.5, max_force: 10.0, max_grip_force: 15.0, budget_actions: 5, budget_wall_ms: 10000 }
  }
{
  let peer_names := list.map(peer.skills, fn (s :: card.AgentSkill) -> Str {
    s.name
  })
  let shared_skills := list.filter(ceiling.skills, fn (sk :: Str) -> Bool {
    contains_str(peer_names, sk)
  })
  let acts_cap := if policy.max_budget_actions < ceiling.budget_actions {
    policy.max_budget_actions
  } else {
    ceiling.budget_actions
  }
  let ms_cap := if policy.max_budget_ms < ceiling.budget_wall_ms {
    policy.max_budget_ms
  } else {
    ceiling.budget_wall_ms
  }
  { skills: shared_skills, ws_min: ceiling.ws_min, ws_max: ceiling.ws_max, max_velocity: ceiling.max_velocity, max_force: ceiling.max_force, max_grip_force: ceiling.max_grip_force, budget_actions: acts_cap, budget_wall_ms: ms_cap }
}

