# src/bazaar.lex — Types and helpers for the robot bazaar A2A demo.
#
# Architecture:
#   Seller robots run in separate processes (each with its own sidecar and
#   signed agent card). Customer robot connects to each via A2A handshake,
#   queries stock, and buys the best match — all under a grant.
#
# Pure functions (item_matches, best_match, parse_*):
#   These carry no effects and are testable with `examples {}` blocks.
#   They can be run offline with:  lex run src/bazaar.lex item_matches_test
#
# In production (lex-os):
#   Each seller runs in a Firecracker microVM; its skills are sealed by its
#   grant. The customer's budget_actions caps total interactions across all
#   stalls regardless of what any individual seller claims.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-trail/src/log" as tlog

import "./a2a_card" as card

import "./a2a_consent" as consent

import "./a2a_audit" as audit

import "./a2a_session" as sess

import "./a2a_server" as a2a_server

import "std.crypto" as crypto

import "std.bytes" as bytes

# ── Types ──────────────────────────────────────────────────────────────────────
type Item = { id :: Str, name :: Str, category :: Str, price :: Int }

# Result of a stall visit.
type TxResult = Sold(Item) | NotFound | AlreadyReserved | TxDenied(Str)

type StallInfo = { url :: Str, name :: Str, pubkey_b64 :: Str }

# Accumulator for the customer's stall-hopping fold.
type ShopState = { purchase :: Option[TxResult], parent :: Str, used :: List[Str] }

# ── JSON helpers (std-only) ────────────────────────────────────────────────────
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

fn jint(json :: Str, key :: Str, dflt :: Int) -> Int {
  let seg := nth1(str.split(json, key))
  let tok := head_or(str.split(head_or(str.split(seg, ","), seg), "}"), seg)
  match str.to_int(str.trim(tok)) {
    Some(v) => v,
    None => dflt,
  }
}

# ── Pure predicates ────────────────────────────────────────────────────────────
fn item_matches(item :: Item, search :: Str, max_price :: Int) -> Bool
  examples {
    item_matches({ id: "p1", name: "Red Ceramic Bowl", category: "pottery", price: 8 }, "Bowl", 10) => true,
    item_matches({ id: "p1", name: "Red Ceramic Bowl", category: "pottery", price: 8 }, "Bowl", 5) => false,
    item_matches({ id: "p1", name: "Red Ceramic Bowl", category: "pottery", price: 8 }, "Vase", 10) => false,
    item_matches({ id: "p1", name: "Red Ceramic Bowl", category: "pottery", price: 8 }, "", 10) => true
  }
{
  str.contains(item.name, search) and item.price <= max_price
}

fn item_matches_test() -> Bool
  examples {
    item_matches_test() => true
  }
{
  item_matches({ id: "x", name: "Red Ceramic Bowl", category: "pottery", price: 8 }, "Bowl", 10) and not item_matches({ id: "x", name: "Red Ceramic Bowl", category: "pottery", price: 8 }, "Bowl", 5)
}

# ── Response parsers ───────────────────────────────────────────────────────────
fn parse_best_item(body :: Str) -> Option[Item] {
  let found := jint(body, "\"found\":", 0)
  if found == 0 {
    None
  } else {
    let id := jstr(body, "\"id\":\"", "")
    let name := jstr(body, "\"name\":\"", "")
    let category := jstr(body, "\"category\":\"", "")
    let price := jint(body, "\"price\":", 0)
    if str.is_empty(id) {
      None
    } else {
      Some({ id: id, name: name, category: category, price: price })
    }
  }
}

fn parse_reserve_status(body :: Str) -> Str {
  jstr(body, "\"status\":\"", "unknown")
}

fn parse_sale_status(body :: Str) -> Str {
  jstr(body, "\"status\":\"", "unknown")
}

# ── Display helpers ────────────────────────────────────────────────────────────
fn item_str(item :: Item) -> Str {
  str.join(["\"", item.name, "\" (", item.id, ") — ", int.to_str(item.price), " credits"], "")
}

fn tx_str(tx :: TxResult) -> Str {
  match tx {
    Sold(item) => str.concat("SOLD  ", item_str(item)),
    NotFound => "not found at this stall",
    AlreadyReserved => "item already reserved",
    TxDenied(why) => str.concat("denied: ", why),
  }
}

# ── Seller setup (sim only) ────────────────────────────────────────────────────
# In production each seller runs register_cards at its own startup.
# In the sim the demo calls this once per stall and returns the pubkey for
# bootstrap blob construction.
fn setup_seller(sidecar_url :: Str, stall_name :: Str, secret :: Bytes, pub_skills :: List[card.AgentSkill], ext_skills :: List[card.AgentSkill]) -> [net] Result[Str, Str] {
  match crypto.ed25519_public_key(secret) {
    Err(e) => Err(e),
    Ok(pk) => {
      let pub_b64 := crypto.base64url_encode(pk)
      let pub_card := { name: stall_name, endpoint: sidecar_url, pubkey_b64: pub_b64, tier: card.Public, skills: pub_skills, supports_extended: true }
      let ext_card := { name: stall_name, endpoint: sidecar_url, pubkey_b64: pub_b64, tier: card.Extended, skills: ext_skills, supports_extended: true }
      match a2a_server.register_cards(sidecar_url, pub_card, ext_card, secret) {
        Err(e) => Err(e),
        Ok(_) => Ok(pub_b64),
      }
    },
  }
}

# ── Session-level helpers ──────────────────────────────────────────────────────
fn query_stall(session :: sess.PeerSession, search :: Str, max_price :: Int, now_ms :: Int) -> [net] (Option[Item], sess.PeerSession) {
  let args := str.join(["{\"search\":\"", search, "\",\"max_price\":", int.to_str(max_price), "}"], "")
  let call := { skill: "query_stock", args_json: args }
  match sess.invoke_skill(session, call, now_ms) {
    (SkillOk(body), sess2) => (parse_best_item(body), sess2),
    (SkillDenied(_), sess2) => (None, sess2),
    (SkillFailed(_), sess2) => (None, sess2),
  }
}

fn reserve_and_buy(session :: sess.PeerSession, item :: Item, now_ms :: Int) -> [net] (TxResult, sess.PeerSession) {
  let reserve_call := { skill: "reserve_item", args_json: str.join(["{\"item_id\":\"", item.id, "\"}"], "") }
  match sess.invoke_skill(session, reserve_call, now_ms) {
    (SkillDenied(why), sess2) => (TxDenied(why), sess2),
    (SkillFailed(why), sess2) => (TxDenied(why), sess2),
    (SkillOk(body), sess2) => {
      let status := parse_reserve_status(body)
      if status == "reserved" {
        let sale_call := { skill: "complete_sale", args_json: str.join(["{\"item_id\":\"", item.id, "\",\"payment\":", int.to_str(item.price), "}"], "") }
        match sess.invoke_skill(sess2, sale_call, now_ms) {
          (SkillOk(_), sess3) => (Sold(item), sess3),
          (SkillDenied(why), sess3) => (TxDenied(why), sess3),
          (SkillFailed(why), sess3) => (TxDenied(why), sess3),
        }
      } else {
        if status == "already_reserved" {
          (AlreadyReserved, sess2)
        } else {
          (NotFound, sess2)
        }
      }
    },
  }
}

# ── Stall visit ────────────────────────────────────────────────────────────────
# Full visit: handshake → query → buy if found.
fn visit_stall(stall :: StallInfo, search :: Str, max_price :: Int, policy :: consent.ConsentPolicy, log :: tlog.Log, parent :: Str, used :: List[Str], now_ms :: Int) -> [net, sql, time] (TxResult, Str, List[Str]) {
  let blob := { endpoint: stall.url, ephemeral_token: "bazaar-token", peer_pubkey: stall.pubkey_b64, nonce: str.concat("n-", stall.name), expires_at: now_ms + 300000 }
  match audit.run_audited(blob, policy, now_ms, log, parent, used) {
    (outcome, p1, used2) => match sess.open_session(outcome, stall.name, now_ms + 60000) {
      None => (TxDenied("handshake failed"), p1, used2),
      Some(session) => match query_stall(session, search, max_price, now_ms) {
        (None, _) => (NotFound, p1, used2),
        (Some(item), sess2) => match reserve_and_buy(sess2, item, now_ms) {
          (tx, _sess3) => (tx, p1, used2),
        },
      },
    },
  }
}

