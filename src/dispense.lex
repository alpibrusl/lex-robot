# src/dispense.lex — evidence-gated lab/pharmacy dispensing (issue #7).
#
# The GMP claim this module encodes: a dispense is "done" only when a real
# sensor says so. `dispense` actuates; `read_scale` measures; the Verify
# gate passes only when measured == target within tolerance, with bounded
# top-up retries on a short dispense. Every attempt is appended to a
# hash-chained lex-trail — the compliance record IS the run.
#
# Three walls stand before the pump, same shape as the wash demo's tariff
# gate and the dangerous-tool clamp check — each a pure, examples-tested
# function that refuses BEFORE any request leaves the box:
#   1. the skill allowlist in the grant (dispense/read_scale),
#   2. the well allowlist (which wells this grant may touch),
#   3. the single-dispense volume ceiling.
#
# Volumes are integer microliters — never floats in a dose.

import "std.str" as str

import "std.int" as int

import "lex-schema/json_value" as jv

import "../src/types" as t

import "../src/grant" as grant

import "../src/client" as client

# One well's order: fill to `target_ul` within ±`tol_ul`.
type WellTarget = { well :: Str, target_ul :: Int, tol_ul :: Int }

# ── The pure gates (the walls; each carries its vectors) ─────────────────────
# Verify gate: is the measured volume within target ± tolerance?
fn within_tolerance(target_ul :: Int, tol_ul :: Int, measured_ul :: Int) -> Bool
  examples {
    within_tolerance(300, 5, 300) => true,
    within_tolerance(300, 5, 295) => true,
    within_tolerance(300, 5, 305) => true,
    within_tolerance(300, 5, 294) => false,
    within_tolerance(300, 5, 306) => false
  }
{
  if measured_ul >= target_ul - tol_ul {
    measured_ul <= target_ul + tol_ul
  } else {
    false
  }
}

# Capability allowlist over wells: this grant may touch these wells only.
fn well_allowed(allowed :: List[Str], well :: Str) -> Bool
  examples {
    well_allowed(["A1", "B2"], "B2") => true,
    well_allowed(["A1", "B2"], "D4") => false,
    well_allowed([], "A1") => false
  }
{
  grant.skill_allowed({ skills: allowed, ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.0, y: 0.0, z: 0.0 }, max_velocity: 0.0, max_force: 0.0, max_grip_force: 0.0, budget_actions: 0, budget_wall_ms: 0 }, well)
}

# Single-dispense ceiling: one actuation may move at most `max_ul`.
fn volume_allowed(max_ul :: Int, volume_ul :: Int) -> Bool
  examples {
    volume_allowed(500, 500) => true,
    volume_allowed(500, 501) => false,
    volume_allowed(500, 0) => false
  }
{
  if volume_ul > 0 {
    volume_ul <= max_ul
  } else {
    false
  }
}

# How much a top-up must add to reach the target from a short measure.
fn topup_ul(target_ul :: Int, measured_ul :: Int) -> Int
  examples {
    topup_ul(300, 210) => 90,
    topup_ul(300, 300) => 0,
    topup_ul(300, 310) => 0
  }
{
  if measured_ul >= target_ul {
    0
  } else {
    target_ul - measured_ul
  }
}

# ── Sidecar skills (grant-gated, like src/skills.lex) ────────────────────────
fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0 - 1,
  }
}

# Actuate the pump into `well`. The walls run HERE — a refusal means the
# request never existed.
fn dispense(r :: t.Robot, allowed_wells :: List[Str], max_ul :: Int, well :: Str, volume_ul :: Int) -> [net, sense, actuate] t.Outcome {
  if grant.skill_allowed(r.grant, "dispense") {
    if well_allowed(allowed_wells, well) {
      if volume_allowed(max_ul, volume_ul) {
        let args := str.join(["{\"well\":\"", well, "\",\"volume_ul\":", int.to_str(volume_ul), "}"], "")
        match client.call(r.sidecar_url, "dispense", args) {
          Err(e) => Stalled(e),
          Ok(body) => if str.contains(str.replace(body, " ", ""), "\"outcome\":\"reached\"") {
            Reached
          } else {
            Stalled(body)
          },
        }
      } else {
        Denied(str.join(["REFUSED: ", int.to_str(volume_ul), " µl above the ", int.to_str(max_ul), " µl single-dispense ceiling (never sent)"], ""))
      }
    } else {
      Denied(str.join(["REFUSED: well ", well, " not in the granted wells (never sent)"], ""))
    }
  } else {
    Denied("denied: skill dispense not in grant (never sent)")
  }
}

# Read the (simulated) scale under `well` — the evidence the Verify gate
# trusts. Nothing the pump reports counts; only this measurement does.
fn read_scale(r :: t.Robot, well :: Str) -> [net, sense] Result[Int, Str] {
  if grant.skill_allowed(r.grant, "read_scale") {
    let args := str.join(["{\"well\":\"", well, "\"}"], "")
    match client.call(r.sidecar_url, "read_scale", args) {
      Err(e) => Err(e),
      Ok(body) => match jv.parse(body) {
        Err(_) => Err("unparseable scale reading"),
        Ok(j) => {
          let n := jint(j, "measured_ul")
          if n >= 0 {
            Ok(n)
          } else {
            Err(str.concat("no measured_ul in: ", body))
          }
        },
      },
    }
  } else {
    Err("denied: skill read_scale not in grant (never sent)")
  }
}

