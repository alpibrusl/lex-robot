# examples/depot_demo.lex — humanoid connects an EV truck in a depot, gated by
# a real OCPP charging handshake (lex-robot#4, Tier 1).
#
# Perceive (read inlet) → Plan (approach pose) → Execute (move + connect, the
# connect force is grant-clamped) → Verify (OCPP StartTransaction: a non-zero
# transaction_id proves a real charging session, which the backend only grants
# when the connector is physically seated). Then a safe stop+disconnect.
#
#   python3 sidecar/depot_sidecar.py &
#   lex run --allow-effects env,net,sense,actuate,io examples/depot_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.env" as env

import "../src/types" as t

import "../src/skills" as skills

import "../src/charge" as charge

fn outcome_str(o :: t.Outcome) -> Str {
  match o {
    Reached => "reached",
    Stalled(m) => str.concat("stalled: ", m),
    Denied(m) => str.concat("denied: ", m),
    Killed(m) => str.concat("killed: ", m),
    Timeout => "timeout",
  }
}

fn is_reached(o :: t.Outcome) -> Bool {
  match o { Reached => true, _ => false }
}

fn depot_grant() -> t.Grant {
  {
    skills: ["move_to", "connect_charger", "disconnect_charger", "read_inlet"],
    ws_min: { x: 0.0, y: 0.0, z: 0.0 },
    ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 1.0,
    max_force: 15.0,        # connector force ceiling — clamps connect_charger
    max_grip_force: 20.0,
    budget_actions: 200,
    budget_wall_ms: 120000,
  }
}

fn env_or(key :: Str, dflt :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => if str.is_empty(v) { dflt } else { v },
    None => dflt,
  }
}

fn run() -> [env, net, sense, actuate, io] Unit {
  # Defaults → the depot sidecar stand-in. Set these to hit the REAL lex-charge:
  #   LEX_CHARGE_URL=http://localhost:18000  LEX_CHARGE_TOKEN=<jwt>  LEX_DEPOT_CP=CP-RTM-01
  let cp_id := env_or("LEX_DEPOT_CP", "DEPOT-CP-01")
  let charge_url := env_or("LEX_CHARGE_URL", "http://localhost:8900")
  let token := env_or("LEX_CHARGE_TOKEN", "")
  let robot := { sidecar_url: "http://localhost:8900", grant: depot_grant() }
  let __reset := skills.reset_depot(robot)

  # ── Perceive ──
  let __h := io.print("=== humanoid: connect EV truck in depot ===")
  match skills.read_inlet(robot) {
    Err(e) => io.print(str.concat("perceive FAILED: ", e)),
    Ok(inlet) => {
      let __p := io.print(str.join(["  [ok ] perceive — inlet at (", flt.to_str(inlet.pos.x), ",", flt.to_str(inlet.pos.y), ",", flt.to_str(inlet.pos.z), ")"], ""))

      # ── Plan ── target = the inlet pose
      let __pl := io.print("  [ok ] plan — approach the inlet")

      # ── Execute ── move the arm to the inlet, then seat the connector.
      # Request 99N — the grant clamps it to 15N before it reaches the arm.
      let mv := skills.move_to(robot, inlet)
      let __m := io.print(str.join(["  [", if is_reached(mv) { "ok " } else { "FAIL" }, "] execute.move — ", outcome_str(mv)], ""))
      let conn := skills.connect_charger(robot, 99.0)
      let __c := io.print(str.join(["  [", if is_reached(conn) { "ok " } else { "FAIL" }, "] execute.connect (req 99N->clamped 15N) — ", outcome_str(conn)], ""))

      # ── Verify ── the OCPP handshake against lex-charge: remote-start accepted,
      # then confirm a real active session exists for this cp_id.
      match charge.start(charge_url, cp_id, 1, "DEPOT-FLEET", token) {
        Err(e) => io.print(str.concat("  [FAIL] verify — charge error: ", e)),
        Ok(false) => io.print("  [FAIL] verify — lex-charge rejected the remote start"),
        Ok(true) => {
          let __vs := io.print("  [ok ] verify.start — lex-charge accepted (sent)")
          match charge.confirm_active(charge_url, cp_id, token) {
            Err(e) => io.print(str.concat("  [FAIL] verify.confirm — ", e)),
            Ok(false) => io.print(str.concat("  [FAIL] verify.confirm — no active session for ", cp_id)),
            Ok(true) => {
              let __v := io.print(str.join(["  [ok ] verify.confirm — active OCPP session for ", cp_id], ""))
              let __s := io.print("task SUCCESS — truck charging")
              # Safe teardown: stop the session BEFORE unplugging
              # (disconnect mid-charge is reversibility=supervised).
              let __stop := charge.stop(charge_url, cp_id, token)
              let __d := skills.disconnect_charger(robot)
              io.print(str.concat("  teardown — stopped session + ", outcome_str(__d)))
            },
          }
        },
      }
    },
  }
}
