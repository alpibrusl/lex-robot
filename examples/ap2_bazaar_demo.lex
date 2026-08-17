# ap2_bazaar_demo — AP2 Checkout + Payment Mandate exchange in the bazaar
# (issue #24), on lex-jose's mandate types (#23).
#
# Three parties, three refusal walls, one happy path:
#
#   shopper (this program)     — reserves stock, seals a CheckoutMandate for
#                                the exact cart, asks its credential provider
#                                for a PaymentMandate, presents both to the
#                                stall. Grant-gated like every robot skill.
#   credential provider :8910  — the payment-side grant: verifies the sealed
#                                checkout and refuses to sign a PaymentMandate
#                                above the instrument's ceiling. A refusal
#                                means NO mandate exists to present.
#   pottery stall       :8900  — LEX_AP2=1: no sale completes without a
#                                network-signed payment mandate hash-bound to
#                                the exact checkout presented.
#
# The acts:
#   1. Bowl (8 cr) on card-lex-1 (ceiling 100)     → mandates issued, SOLD.
#   2. Vase (12 cr) on card-lex-petty (ceiling 10) → provider REFUSES; the
#      mandate is never signed, so there is nothing to present.
#   3. Sale attempt with no mandates at all        → stall REFUSES.
#   4. Payment mandate issued for the teapot at 22, presented with a
#      re-sealed checkout claiming 1              → hash binding REFUSES.
#   5. Observer grant without complete_sale        → denied at the grant,
#                                                    never sent.
#
# Run it:  bash scripts/demo.sh ap2

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.time" as time

import "std.bytes" as bytes

import "../src/types" as t

import "../src/ap2_mandate" as ap2

# The shopper's envelope: bazaar commerce skills only — no actuation fields
# matter at a market stall, zeroed like the sensor grants.
fn shopper_grant() -> t.Grant {
  { skills: ["query_stock", "reserve_item", "complete_sale"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 20, budget_wall_ms: 60000 }
}

# The same stall, browse-only: may query, never buy.
fn observer_grant() -> t.Grant {
  { skills: ["query_stock"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 5, budget_wall_ms: 60000 }
}

fn env_or(key :: Str, dflt :: Str) -> [env] Str {
  match env.get(key) {
    None => dflt,
    Some(v) => if str.is_empty(v) {
      dflt
    } else {
      v
    },
  }
}

# The enrollment secret the credential provider issued this shopper (the
# sidecar's demo default; override both sides via LEX_AP2_AGENT_SECRET).
fn agent_secret() -> [env] Bytes {
  bytes.from_str(env_or("LEX_AP2_AGENT_SECRET", "ap2-agent-secret-demo"))
}

# Reserve `search` and buy it through the full mandate flow on `instrument`.
fn shop(r :: t.Robot, cp_url :: Str, search :: Str, instrument :: Str, now :: Int) -> [net, io, env] Unit {
  match ap2.query_stock(r, search, 30) {
    Err(e) => io.print(str.concat("query failed: ", e)),
    Ok(hit) => if hit.found {
      let __f := io.print(str.join(["found ", hit.name, " at ", int.to_str(hit.price), " cr"], ""))
      match ap2.reserve_item(r, hit.id) {
        Err(e) => io.print(str.concat("reserve failed: ", e)),
        Ok(_) => {
          let cm := ap2.checkout_for_item("pottery", hit.id, hit.name, hit.price, now)
          match ap2.seal_checkout(agent_secret(), cm) {
            Err(e) => io.print(str.concat("seal failed: ", e)),
            Ok(checkout_jwt) => {
              let __c := io.print(str.join(["checkout mandate sealed for ", hit.name, " (", int.to_str(hit.price), " cr)"], ""))
              match ap2.request_payment_mandate(cp_url, checkout_jwt, instrument) {
                Err(why) => io.print(str.join(["REFUSED by credential provider: ", why, " — no mandate exists, nothing to present"], "")),
                Ok(payment_jwt) => {
                  let __p := io.print(str.concat("payment mandate issued on ", instrument))
                  match ap2.complete_sale_with_mandates(r, hit.id, hit.price, checkout_jwt, payment_jwt) {
                    Err(e) => io.print(str.concat("REFUSED by stall: ", e)),
                    Ok(receipt) => io.print(str.join(["sale completed: ", hit.name, " for ", int.to_str(hit.price), " cr (receipt ", receipt, ")"], "")),
                  }
                },
              }
            },
          }
        },
      }
    } else {
      io.print(str.concat("not in stock: ", search))
    },
  }
}

# Act 4: get a VALID payment mandate for the real checkout, then present a
# different (re-sealed, self-consistent, cheaper) checkout with it. The
# stall's hash binding must refuse — the network signed a promise about ONE
# specific cart.
fn binding_tamper(r :: t.Robot, cp_url :: Str, now :: Int) -> [net, io, env] Unit {
  match ap2.query_stock(r, "Teapot", 30) {
    Err(e) => io.print(str.concat("query failed: ", e)),
    Ok(hit) => if hit.found {
      match ap2.reserve_item(r, hit.id) {
        Err(e) => io.print(str.concat("reserve failed: ", e)),
        Ok(_) => {
          let honest := ap2.checkout_for_item("pottery", hit.id, hit.name, hit.price, now)
          let cheaper := ap2.checkout_for_item("pottery", hit.id, hit.name, 1, now)
          match ap2.seal_checkout(agent_secret(), honest) {
            Err(e) => io.print(str.concat("seal failed: ", e)),
            Ok(honest_jwt) => match ap2.request_payment_mandate(cp_url, honest_jwt, "card-lex-1") {
              Err(why) => io.print(str.concat("REFUSED by credential provider: ", why)),
              Ok(payment_jwt) => {
                let __p := io.print(str.join(["payment mandate issued for the honest checkout (", int.to_str(hit.price), " cr)"], ""))
                match ap2.seal_checkout(agent_secret(), cheaper) {
                  Err(e) => io.print(str.concat("seal failed: ", e)),
                  Ok(cheaper_jwt) => match ap2.complete_sale_with_mandates(r, hit.id, 1, cheaper_jwt, payment_jwt) {
                    Err(e) => io.print(str.concat("REFUSED by stall: ", e)),
                    Ok(receipt) => io.print(str.concat("tampered checkout SOLD — THIS MUST NOT HAPPEN: ", receipt)),
                  },
                }
              },
            },
          }
        },
      }
    } else {
      io.print("teapot not in stock")
    },
  }
}

fn run() -> [net, io, time, env] Unit {
  let stall_url := env_or("LEX_STALL_URL", "http://localhost:8900")
  let cp_url := env_or("LEX_AP2_CP_URL", "http://localhost:8910")
  let now := time.now()
  let shopper := { sidecar_url: stall_url, grant: shopper_grant() }
  let observer := { sidecar_url: stall_url, grant: observer_grant() }
  let __h := io.print("── AP2 bazaar: Checkout + Payment Mandates at the pottery stall ──")
  let __a1 := io.print("[act 1] bowl on card-lex-1 (ceiling 100):")
  let __r1 := shop(shopper, cp_url, "Bowl", "card-lex-1", now)
  let __a2 := io.print("[act 2] vase on card-lex-petty (ceiling 10):")
  let __r2 := shop(shopper, cp_url, "Vase", "card-lex-petty", now)
  let __a3 := io.print("[act 3] sale attempt with no mandates:")
  let __r3 := match ap2.complete_sale_with_mandates(shopper, "pot-002", 12, "", "") {
    Err(e) => io.print(str.concat("REFUSED by stall: ", e)),
    Ok(receipt) => io.print(str.concat("mandate-less SOLD — THIS MUST NOT HAPPEN: ", receipt)),
  }
  let __a4 := io.print("[act 4] valid payment mandate, swapped checkout:")
  let __r4 := binding_tamper(shopper, cp_url, now)
  let __a5 := io.print("[act 5] observer grant tries to buy:")
  let __r5 := match ap2.complete_sale_with_mandates(observer, "pot-002", 12, "", "") {
    Err(e) => io.print(e),
    Ok(_) => io.print("observer bought — THIS MUST NOT HAPPEN"),
  }
  ()
}

