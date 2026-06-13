# examples/depot_demo.lex — humanoid connects an EV truck in a depot, gated by
# a real OCPP charging handshake (lex-robot#4, Tier 1).
#
# Perceive (read inlet) → Plan (approach pose) → Execute (move + connect, the
# connect force is grant-clamped) → Verify (OCPP StartTransaction: a non-zero
# transaction_id proves a real charging session, which the backend only grants
# when the connector is physically seated). Then a safe stop+disconnect.
#
#   python3 sidecar/depot_sidecar.py &
#   lex run --allow-effects net,io examples/depot_demo.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "../src/types" as t

import "../src/skills" as skills

import "../src/charge" as charge

fn outcome_str(o :: t.Outcome) -> Str {
  match o {
    Reached => "reached",
    Stalled(m) => str.concat("stalled: ", m),
    Denied(m) => str.concat("denied: ", m),
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
  }
}

fn run() -> [net, io] Unit {
  let cp_id := "DEPOT-CP-01"
  let robot := { sidecar_url: "http://localhost:8900", grant: depot_grant() }
  let charge_url := "http://localhost:8900"   # Tier-1 stand-in; point at lex-charge in prod
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

      # ── Verify ── the OCPP handshake: a transaction id proves a real session.
      match charge.start(charge_url, cp_id, 1, "DEPOT-FLEET") {
        Err(e) => io.print(str.concat("  [FAIL] verify — charge error: ", e)),
        Ok(None) => io.print("  [FAIL] verify — OCPP rejected (connector not seated)"),
        Ok(Some(tx)) => {
          let __v := io.print(str.join(["  [ok ] verify — OCPP StartTransaction Accepted, tx=", int.to_str(tx)], ""))
          let __s := io.print("task SUCCESS — truck charging")
          # ── Safe teardown: stop the session BEFORE unplugging.
          # (disconnect mid-charge is reversibility=supervised in the manifest.)
          let __stop := charge.stop(charge_url, cp_id, tx)
          let __d := skills.disconnect_charger(robot)
          io.print(str.concat("  teardown — stopped tx + ", outcome_str(__d)))
        },
      }
    },
  }
}
