# home.lex — the house's appliances as granted capabilities (ha_sidecar.py).
#
# An appliance command is an actuation with real-world costs — water, heat,
# energy cents — so it goes through the same Grant machinery as an arm reach:
# `appliance_start` must be NAMED IN THE GRANT, and on top of the capability
# check sits an energy-policy precondition (`wash_allowed`) in the same shape
# as the dangerous-tool demo's clamp check: a pure, examples-tested gate the
# caller runs BEFORE the command, so a peak-tariff start is refused and never
# sent. Prices are integer cents per kWh throughout — never floats in a
# budget (lex-os convention).

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "./types" as t

import "./grant" as grant

import "./client" as client

# ── energy policy: the pure gate ─────────────────────────────────────────────
# May a cycle start at this price? The ceiling is the owner's call, carried
# next to (not inside) the Grant — t.Grant bounds force and reach; the tariff
# ceiling bounds spend-per-kWh, and refusing above it is a precondition
# refusal, not a capability one. Both are auditable; they answer different
# questions.
fn wash_allowed(max_price_cents_kwh :: Int, price_cents_kwh :: Int) -> Bool
  examples {
    wash_allowed(15, 11) => true,
    wash_allowed(15, 15) => true,
    wash_allowed(15, 32) => false,
    wash_allowed(0, 1) => false
  }
{
  price_cents_kwh <= max_price_cents_kwh
}

# Estimated cycle cost in integer cents, rounded up — a budget check must
# never round its own spend downward.
fn cycle_cost_cents(price_cents_kwh :: Int, cycle_wh :: Int) -> Int
  examples {
    cycle_cost_cents(11, 900) => 10,
    cycle_cost_cents(32, 900) => 29,
    cycle_cost_cents(10, 1000) => 10,
    cycle_cost_cents(0, 900) => 0
  }
{
  (price_cents_kwh * cycle_wh + 999) / 1000
}

# ── tiny flat-JSON int extractor ─────────────────────────────────────────────
fn jint(json :: Str, key :: Str, dflt :: Int) -> Int {
  let parts := str.split(json, key)
  match list.head(list.tail(parts)) {
    None => dflt,
    Some(seg) => {
      let tok := match list.head(str.split(match list.head(str.split(seg, ",")) {
        Some(s) => s,
        None => seg,
      }, "}")) {
        Some(s) => s,
        None => seg,
      }
      match str.to_int(str.trim(tok)) {
        Some(v) => v,
        None => dflt,
      }
    },
  }
}

# Pull "price_cents_kwh" out of a read_tariff response; -1 when absent, so a
# malformed answer can never look like a legal (cheap) price.
fn tariff_price(json :: Str) -> Int
  examples {
    tariff_price("{\"price_cents_kwh\":11,\"period\":\"valley\"}") => 11,
    tariff_price("{\"error\":\"no sensor\"}") => -1
  }
{
  jint(json, "\"price_cents_kwh\":", -1)
}

fn outcome_of(resp :: Str) -> t.Outcome {
  if str.contains(resp, "\"reached\"") {
    Reached
  } else {
    if str.contains(resp, "\"denied\"") {
      Denied(resp)
    } else {
      if str.contains(resp, "\"timeout\"") {
        Timeout
      } else {
        Stalled(resp)
      }
    }
  }
}

# ── sensing (ungated, like read_base: state carries no authority) ────────────
fn read_state(r :: t.Robot, entity :: Str) -> [net, sense] Result[Str, Str] {
  client.call(r.sidecar_url, "read_state", str.join(["{\"entity\":\"", entity, "\"}"], ""))
}

fn read_tariff(r :: t.Robot, at :: Str) -> [net, sense] Result[Str, Str] {
  if str.is_empty(at) {
    client.call(r.sidecar_url, "read_tariff", "{}")
  } else {
    client.call(r.sidecar_url, "read_tariff", str.join(["{\"at\":\"", at, "\"}"], ""))
  }
}

# ── actuation (grant-gated: a refusal is never sent) ─────────────────────────
fn appliance_start(r :: t.Robot, entity :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "appliance_start") {
    match client.call(r.sidecar_url, "appliance_start", str.join(["{\"entity\":\"", entity, "\"}"], "")) {
      Err(e) => Stalled(e),
      Ok(resp) => outcome_of(resp),
    }
  } else {
    Denied("skill appliance_start not in grant")
  }
}

fn appliance_stop(r :: t.Robot, entity :: Str) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "appliance_stop") {
    match client.call(r.sidecar_url, "appliance_stop", str.join(["{\"entity\":\"", entity, "\"}"], "")) {
      Err(e) => Stalled(e),
      Ok(resp) => outcome_of(resp),
    }
  } else {
    Denied("skill appliance_stop not in grant")
  }
}

