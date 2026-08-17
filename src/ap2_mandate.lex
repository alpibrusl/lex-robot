# src/ap2_mandate.lex — the shopper's side of the AP2 (Agent Payments
# Protocol) mandate flow in the bazaar (issue #24), built on lex-jose's
# mandate module (#23).
#
# Roles (all simulated by sidecar/sim_sidecar.py):
#   shopper (this module)   — seals a CheckoutMandate for the exact cart it
#                             reserved, HS256 under the agent secret its
#                             credential provider issued at enrollment.
#   credential provider     — verifies the sealed checkout, enforces the
#    (LEX_ROLE=credential_provider on :8910)   per-instrument spend ceiling,
#                             and only then signs a PaymentMandate under the
#                             payment network's key. A refusal means NO
#                             mandate exists — there is nothing to present.
#   stall / merchant        — verifies the network's signature on the payment
#    (LEX_AP2=1)              mandate, its hash binding to the exact checkout
#                             token presented, expiry, and price coverage —
#                             before any sale completes.
#
# Trust topology, stated honestly (HS256 everywhere so the stdlib-only
# sidecar can verify): the stall never checks the shopper's signature
# directly — it trusts the payment NETWORK's signature, and the network's
# credential provider verified the shopper's sealed checkout before issuing.
# The payment mandate's `checkout_hash` binds the two tokens: present a
# different checkout than the one the payment was issued for and the stall
# refuses. Swapping HS256 for ES256/EdDSA is a jwa.Alg change in this file —
# lex-jose carries all four algorithms.
#
# Money is integer credits (the bazaar's cents) — never floats.

import "std.str" as str

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-jose/jwa" as jwa

import "lex-jose/mandate" as m

import "../src/types" as t

import "../src/grant" as grant

import "../src/client" as client

# ── Checkout construction (pure) ──────────────────────────────────────────────
# A single-item cart for the stock the shopper just reserved. `now` is unix
# seconds from the caller's clock; the mandate expires five minutes later.
fn checkout_for_item(merchant :: Str, item_id :: Str, name :: Str, price :: Int, now :: Int) -> m.CheckoutMandate
  examples {
    checkout_for_item("pottery", "pot-001", "Red Ceramic Bowl", 8, 1000) => { merchant_id: "pottery", items: [{ sku: "pot-001", description: "Red Ceramic Bowl", qty: 1, unit_cents: 8 }], total_cents: 8, currency: "CR", expires_at: 1300 }
  }
{
  { merchant_id: merchant, items: [{ sku: item_id, description: name, qty: 1, unit_cents: price }], total_cents: price, currency: "CR", expires_at: now + 300 }
}

# Seal the checkout under the shopper's enrollment secret. Deterministic —
# lex-jose refuses a cart whose total lies about its items.
fn seal_checkout(agent_secret :: Bytes, cm :: m.CheckoutMandate) -> Result[Str, Str] {
  m.seal_checkout(HS256, agent_secret, cm)
}

# ── Stall skills the shopper drives (grant-gated, like src/skills.lex) ────────
fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

# What query_stock found (found == false ⇒ the rest is empty/zero).
type StockHit = { found :: Bool, id :: Str, name :: Str, price :: Int }

fn parse_stock(body :: Str) -> StockHit
  examples {
    parse_stock("{\"stall\":\"pottery\",\"found\":1,\"id\":\"pot-001\",\"name\":\"Red Ceramic Bowl\",\"category\":\"pottery\",\"price\":8}") => { found: true, id: "pot-001", name: "Red Ceramic Bowl", price: 8 },
    parse_stock("{\"stall\":\"pottery\",\"found\":0}") => { found: false, id: "", name: "", price: 0 }
  }
{
  match jv.parse(body) {
    Err(_) => { found: false, id: "", name: "", price: 0 },
    Ok(j) => if jint(j, "found") == 1 {
      { found: true, id: jstr(j, "id"), name: jstr(j, "name"), price: jint(j, "price") }
    } else {
      { found: false, id: "", name: "", price: 0 }
    },
  }
}

fn query_stock(r :: t.Robot, search :: Str, max_price :: Int) -> [net] Result[StockHit, Str] {
  if grant.skill_allowed(r.grant, "query_stock") {
    let args := str.join(["{\"search\":\"", search, "\",\"max_price\":", int.to_str(max_price), "}"], "")
    match client.call(r.sidecar_url, "query_stock", args) {
      Err(e) => Err(e),
      Ok(body) => Ok(parse_stock(body)),
    }
  } else {
    Err("denied: skill query_stock not in grant (never sent)")
  }
}

fn reserve_item(r :: t.Robot, item_id :: Str) -> [net] Result[Str, Str] {
  if grant.skill_allowed(r.grant, "reserve_item") {
    let args := str.join(["{\"item_id\":\"", item_id, "\"}"], "")
    match client.call(r.sidecar_url, "reserve_item", args) {
      Err(e) => Err(e),
      Ok(body) => match jv.parse(body) {
        Err(_) => Err("unparseable reserve response"),
        Ok(j) => if jstr(j, "status") == "reserved" {
          Ok("reserved")
        } else {
          Err(jstr(j, "status"))
        },
      },
    }
  } else {
    Err("denied: skill reserve_item not in grant (never sent)")
  }
}

# ── Credential provider ───────────────────────────────────────────────────────
# Ask the credential provider to issue a PaymentMandate for a sealed
# checkout. The provider verifies the checkout's signature and re-derives
# its total, then enforces the instrument's spend ceiling — a refusal comes
# back as Err and NO mandate exists.
fn request_payment_mandate(provider_url :: Str, checkout_jwt :: Str, instrument_id :: Str) -> [net] Result[Str, Str] {
  let args := str.join(["{\"checkout_jwt\":\"", checkout_jwt, "\",\"instrument_id\":\"", instrument_id, "\"}"], "")
  match client.call(provider_url, "issue_payment_mandate", args) {
    Err(e) => Err(e),
    Ok(body) => match jv.parse(body) {
      Err(_) => Err("unparseable credential provider response"),
      Ok(j) => if jstr(j, "status") == "issued" {
        Ok(jstr(j, "payment_jwt"))
      } else {
        Err(jstr(j, "why"))
      },
    },
  }
}

# ── Mandate-backed sale ───────────────────────────────────────────────────────
# Complete a sale presenting both mandates. The stall's verification happens
# server-side; a mandate failure surfaces as Err with the stall's reason and
# no sale exists. Returns the receipt id on success.
fn complete_sale_with_mandates(r :: t.Robot, item_id :: Str, payment :: Int, checkout_jwt :: Str, payment_jwt :: Str) -> [net] Result[Str, Str] {
  if grant.skill_allowed(r.grant, "complete_sale") {
    let args := str.join(["{\"item_id\":\"", item_id, "\",\"payment\":", int.to_str(payment), ",\"checkout_jwt\":\"", checkout_jwt, "\",\"payment_jwt\":\"", payment_jwt, "\"}"], "")
    match client.call(r.sidecar_url, "complete_sale", args) {
      Err(e) => Err(e),
      Ok(body) => match jv.parse(body) {
        Err(_) => Err("unparseable sale response"),
        Ok(j) => {
          let status := jstr(j, "status")
          if status == "sold" {
            Ok(jstr(j, "receipt"))
          } else {
            if str.is_empty(jstr(j, "why")) {
              Err(status)
            } else {
              Err(str.join([status, ": ", jstr(j, "why")], ""))
            }
          }
        },
      },
    }
  } else {
    Err("denied: skill complete_sale not in grant (never sent)")
  }
}

