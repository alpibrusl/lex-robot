# dispense_demo — evidence-gated + audited lab/pharmacy dispensing (issue #7).
#
# Pipetting where "done" is only true when the SCALE says so: each well's
# dispense passes Verify only when the measured volume lands within target ±
# tolerance, a short dispense gets a bounded top-up retry, and every attempt
# is appended to a hash-chained lex-trail — a tamper-evident GMP record.
# Same protocol-coupled-Verify pattern as the EV OCPP gate, pointed at a
# scale instead of a charger session list.
#
# The acts:
#   1. The plate run: A1 200±5, B2 300±5, C3 150±5. The sidecar's B2 pump
#      shorts its first dispense (delivers 70%) — the scale catches it, one
#      top-up brings it in-band, Verify passes. SUCCESS requires all three.
#   2. Well D4 (not in the granted wells)  → refused, never sent.
#   3. 900 µl (above the 500 µl ceiling)   → refused, never sent.
#   4. Chain audit: every event's content hash re-verifies (chain intact);
#      a forged copy of a dispense record — same id, doctored measured_ul —
#      fails ev.is_valid: the tampered entry is DETECTED.
#
# Run it:  bash scripts/demo.sh dispense
#
# Volumes are integer microliters — never floats in a dose.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-trail/src/log" as tlog

import "lex-trail/src/event" as ev

import "../src/types" as t

import "../src/dispense" as disp

# The pharmacist's envelope: dispense + read the scale, nothing else.
fn tech_grant() -> t.Grant {
  { skills: ["dispense", "read_scale"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 30, budget_wall_ms: 60000 }
}

# Which wells this grant may touch, and the single-dispense ceiling.
fn granted_wells() -> List[Str] {
  ["A1", "B2", "C3"]
}

fn max_single_ul() -> Int {
  500
}

fn plate() -> List[disp.WellTarget] {
  [{ well: "A1", target_ul: 200, tol_ul: 5 }, { well: "B2", target_ul: 300, tol_ul: 5 }, { well: "C3", target_ul: 150, tol_ul: 5 }]
}

# Append one chained audit event; the chain survives an append failure.
fn trail(log :: tlog.Log, parent :: Str, kind :: Str, payload_json :: Str) -> [sql, time] Str {
  match tlog.append(log, kind, Some(parent), payload_json) {
    Ok(e) => e.id,
    Err(_) => parent,
  }
}

fn dispense_payload(well :: Str, target_ul :: Int, dispensed_ul :: Int, measured_ul :: Int, attempt :: Int, verdict :: Str) -> Str {
  str.join(["{\"well\":\"", well, "\",\"target_ul\":", int.to_str(target_ul), ",\"dispensed_ul\":", int.to_str(dispensed_ul), ",\"measured_ul\":", int.to_str(measured_ul), ",\"attempt\":", int.to_str(attempt), ",\"verdict\":\"", verdict, "\"}"], "")
}

# Dispense `volume` into `well`, read the scale, Verify against the target.
# On a short measure, retry with a top-up — at most `retries_left` times.
# Returns (passed, chain head).
fn fill_well(r :: t.Robot, w :: disp.WellTarget, volume_ul :: Int, attempt :: Int, retries_left :: Int, log :: tlog.Log, parent :: Str) -> [net, sense, actuate, io, sql, time] (Bool, Str) {
  match disp.dispense(r, granted_wells(), max_single_ul(), w.well, volume_ul) {
    Denied(d) => {
      let __p := io.print(str.concat("  ", d))
      (false, trail(log, parent, "dispense_refused", dispense_payload(w.well, w.target_ul, volume_ul, 0 - 1, attempt, "refused")))
    },
    Stalled(s) => {
      let __p := io.print(str.join(["  ", w.well, ": pump stalled — ", s], ""))
      (false, trail(log, parent, "dispense_stalled", dispense_payload(w.well, w.target_ul, volume_ul, 0 - 1, attempt, "stalled")))
    },
    Killed(k) => {
      let __p := io.print(str.join(["  ", w.well, ": killed — ", k], ""))
      (false, parent)
    },
    Timeout => {
      let __p := io.print(str.join(["  ", w.well, ": dispense timed out"], ""))
      (false, parent)
    },
    Reached => match disp.read_scale(r, w.well) {
      Err(e) => {
        let __p := io.print(str.join(["  ", w.well, ": scale read failed — ", e], ""))
        (false, parent)
      },
      Ok(measured) => if disp.within_tolerance(w.target_ul, w.tol_ul, measured) {
        let __p := io.print(str.join(["  ", w.well, ": ", int.to_str(measured), "/", int.to_str(w.target_ul), " µl — within ±", int.to_str(w.tol_ul), " (Verify passed, attempt ", int.to_str(attempt), ")"], ""))
        (true, trail(log, parent, "dispense_verified", dispense_payload(w.well, w.target_ul, volume_ul, measured, attempt, "pass")))
      } else {
        let head := trail(log, parent, "dispense_short", dispense_payload(w.well, w.target_ul, volume_ul, measured, attempt, "short"))
        let topup := disp.topup_ul(w.target_ul, measured)
        if retries_left > 0 {
          if topup > 0 {
            let __p := io.print(str.join(["  ", w.well, ": short — ", int.to_str(measured), "/", int.to_str(w.target_ul), " µl; top-up ", int.to_str(topup), " µl"], ""))
            fill_well(r, w, topup, attempt + 1, retries_left - 1, log, head)
          } else {
            let __p := io.print(str.join(["  ", w.well, ": OVER-DISPENSED ", int.to_str(measured), "/", int.to_str(w.target_ul), " µl — no retry can remove volume; well FAILED"], ""))
            (false, head)
          }
        } else {
          let __p := io.print(str.join(["  ", w.well, ": still short after retries — well FAILED"], ""))
          (false, head)
        }
      },
    },
  }
}

type RunState = { all_pass :: Bool, parent :: Str }

fn run_plate(r :: t.Robot, log :: tlog.Log, root :: Str) -> [net, sense, actuate, io, sql, time] RunState {
  list.fold(plate(), { all_pass: true, parent: root }, fn (st :: RunState, w :: disp.WellTarget) -> [net, sense, actuate, io, sql, time] RunState {
    match fill_well(r, w, w.target_ul, 1, 2, log, st.parent) {
      (passed, head) => { all_pass: if st.all_pass {
        passed
      } else {
        false
      }, parent: head },
    }
  })
}

# Audit: recompute every event's content hash, then show that a forged copy
# of a real record — same id, doctored payload — fails ev.is_valid.
fn audit(log :: tlog.Log) -> [io, sql] Unit {
  match tlog.range(log, 0, 9999999999999) {
    Err(e) => io.print(str.concat("audit read failed: ", e)),
    Ok(evs) => {
      let n := list.len(evs)
      let valid := list.fold(evs, 0, fn (acc :: Int, e :: ev.Event) -> Int {
        if ev.is_valid(e) {
          acc + 1
        } else {
          acc
        }
      })
      let __c := io.print(str.join(["audit: ", int.to_str(n), " events, ", int.to_str(valid), " valid → ", if valid == n {
        "chain intact (tamper-evident)"
      } else {
        "TAMPERED"
      }], ""))
      match list.head(list.reverse(evs)) {
        None => io.print("audit: empty chain"),
        Some(last) => {
          let forged := { id: last.id, kind: last.kind, parent: last.parent, payload_json: str.replace(last.payload_json, "\"measured_ul\":", "\"measured_ul\":9"), ts_ms: last.ts_ms }
          if ev.is_valid(forged) {
            io.print("forged record passed verify — THIS MUST NOT HAPPEN")
          } else {
            io.print("TAMPERED entry detected: forged measured_ul fails the content-hash check")
          }
        },
      }
    },
  }
}

fn run() -> [net, sense, actuate, io, sql, fs_write, time] Unit {
  let r := { sidecar_url: "http://localhost:8900", grant: tech_grant() }
  let __h := io.print("── evidence-gated dispensing: the scale is the referee ──")
  match tlog.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => match tlog.append(log, "plate_started", None, "{\"plate\":\"demo-plate-1\"}") {
      Err(e) => io.print(str.concat("trail root failed: ", e)),
      Ok(root) => {
        let st := run_plate(r, log, root.id)
        let __v := if st.all_pass {
          io.print("task SUCCESS — all 3 wells within tolerance (Verify gate passed)")
        } else {
          io.print("task FAILED — a well did not verify")
        }
        let __a2 := io.print("[refusals] outside the envelope:")
        let __d4 := match disp.dispense(r, granted_wells(), max_single_ul(), "D4", 100) {
          Denied(d) => io.print(str.concat("  ", d)),
          Reached => io.print("  D4 dispensed — THIS MUST NOT HAPPEN"),
          Stalled(s) => io.print(str.concat("  D4 stalled: ", s)),
          Killed(k) => io.print(str.concat("  D4 killed: ", k)),
          Timeout => io.print("  D4 timeout"),
        }
        let __big := match disp.dispense(r, granted_wells(), max_single_ul(), "A1", 900) {
          Denied(d) => io.print(str.concat("  ", d)),
          Reached => io.print("  900 µl dispensed — THIS MUST NOT HAPPEN"),
          Stalled(s) => io.print(str.concat("  900 µl stalled: ", s)),
          Killed(k) => io.print(str.concat("  900 µl killed: ", k)),
          Timeout => io.print("  900 µl timeout"),
        }
        audit(log)
      },
    },
  }
}

