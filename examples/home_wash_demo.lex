# home_wash_demo — "wash when energy is cheap": the house as a governed robot.
#
# The HA sidecar (sidecar/ha_sidecar.py) makes every Home Assistant device a
# lex skill; here the device is a washing machine and the effect being
# governed is ENERGY SPEND. Three gates stand between an LLM's (or anyone's)
# "run the wash now" and the machine, and the demo shows each one earn its
# keep:
#
#   1. The tariff precondition — a pure, examples-tested gate
#      (home.wash_allowed): at the peak price the start is REFUSED before any
#      request is sent, with the cost math (integer cents, rounded up) on the
#      record. Same shape as the dangerous-tool demo's clamp check.
#   2. The same request in the off-peak window passes the gate, and only then
#      does the command go to the sidecar — the washer starts at 11c/kWh,
#      not 32c/kWh.
#   3. The capability wall — a grant that may read the house but not actuate
#      it: appliance_start is denied at the grant, NEVER SENT, exactly like a
#      mic-less grant refusing listen.
#
# Run it:  make home-wash   (or: bash scripts/demo.sh home_wash)
# The stub house pins "now" at 13:00 (peak) so the refusal is reproducible;
# against a real house the same program reads a live PVPC/Nordpool sensor —
# see ha_sidecar.py's real mode.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "../src/types" as t

import "../src/home" as home

# The homeowner's envelope: appliance control granted, workspace/force fields
# irrelevant for a house — zeroed, same as the sensor grants.
fn home_grant() -> t.Grant {
  { skills: ["appliance_start", "appliance_stop"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 10, budget_wall_ms: 60000 }
}

# The same house, observation only — a guest may look, not touch.
fn observer_grant() -> t.Grant {
  { skills: [], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 10, budget_wall_ms: 60000 }
}

# The owner's energy policy: never start a cycle above this price. Integer
# cents per kWh; the washer's cycle draws ~900 Wh.
fn max_price_cents_kwh() -> Int {
  15
}

fn cycle_wh() -> Int {
  900
}

# Check the tariff at `at` ("" = now) and start the washer only if the
# examples-tested gate allows it. The refusal happens HERE, before any
# actuating request exists.
fn try_wash(house :: t.Robot, at :: Str, label :: Str) -> [net, sense, actuate, io] Unit {
  match home.read_tariff(house, at) {
    Err(e) => io.print(str.concat("tariff read failed: ", e)),
    Ok(resp) => {
      let price := home.tariff_price(resp)
      let cost := home.cycle_cost_cents(price, cycle_wh())
      if price < 0 {
        io.print(str.concat("no usable tariff in: ", resp))
      } else {
        if home.wash_allowed(max_price_cents_kwh(), price) {
          let __a := io.print(str.join([label, ": ", int.to_str(price), "c/kWh — allowed (cycle ≈ ", int.to_str(cost), " cents)"], ""))
          match home.appliance_start(house, "washer.main") {
            Reached => io.print("washer started in off-peak window"),
            Denied(d) => io.print(str.concat("washer denied: ", d)),
            Stalled(s) => io.print(str.concat("washer stalled: ", s)),
            Killed(k) => io.print(str.concat("washer killed: ", k)),
            Timeout => io.print("washer start timed out"),
          }
        } else {
          io.print(str.join([label, ": ", int.to_str(price), "c/kWh — REFUSED: peak tariff above the ", int.to_str(max_price_cents_kwh()), "c/kWh ceiling (cycle would cost ", int.to_str(cost), " cents; never sent)"], ""))
        }
      }
    },
  }
}

fn run() -> [net, sense, actuate, io] Unit {
  let house := { sidecar_url: "http://localhost:8900", grant: home_grant() }
  let guest := { sidecar_url: "http://localhost:8900", grant: observer_grant() }
  let __1 := try_wash(house, "", "now")
  let __2 := try_wash(house, "02:30", "at 02:30")
  let __3 := match home.read_state(guest, "washer.main") {
    Ok(s) => io.print(str.concat("observer reads state: ", s)),
    Err(e) => io.print(str.concat("observer read failed: ", e)),
  }
  let __4 := match home.appliance_start(guest, "washer.main") {
    Reached => io.print("observer started the washer — THIS MUST NOT HAPPEN"),
    Denied(d) => io.print(str.concat("observer → denied: ", d)),
    Stalled(s) => io.print(str.concat("observer → stalled: ", s)),
    Killed(k) => io.print(str.concat("observer → killed: ", k)),
    Timeout => io.print("observer → timeout"),
  }
  ()
}

