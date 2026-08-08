# lex-robot/src/fleet_traffic.lex — the shared physical-space safety layer
# (epic #115, issue #116).
#
# Two multi-robot scenarios need this: a closed home fleet delegating a
# household goal across several robots, and a robot visiting a bazaar run by
# strangers. Neither scenario's *authority* model is symmetric (closed
# allowlist vs. signed-card handshake — see a2a_robot_auth.lex /
# a2a_handshake.lex), but both need the same thing underneath: two robots
# must not claim overlapping floor space at overlapping times. That's a
# safety property, not an authority one — refusing to honor a stranger's
# claim to "protect" one fleet would make collisions *more* likely, not
# less, so this module is deliberately identity-agnostic. It answers "do
# these two claims conflict", not "is this robot allowed to claim".
#
# Pure module — no effects. `resolve` is the one function every caller
# needs: given the claims already granted, does a new candidate conflict
# with any of them. On conflict, the candidate is refused outright — this
# never reassigns or preempts an existing claim (mirrors a2a_consent.lex's
# escalate: narrow or refuse, never override). Priority-based preemption is
# deliberately out of scope: a resolver that can silently steal an
# in-progress claim is exactly the kind of "protect my own fleet at a
# stranger's expense" behavior this module exists to rule out.

import "std.str" as str

import "std.list" as list

import "./types" as t

# A floor-space box, same axis-aligned shape as Grant's ws_min/ws_max —
# just claimed territory instead of a reach limit.
type Cell = { ws_min :: t.Vec3, ws_max :: t.Vec3 }

# A robot's claim on a set of cells for a time window. `robot_id` is
# whatever the caller uses to identify itself in `fleet/claim` — a signed
# card's pubkey, a hostname, anything stable; this module doesn't verify
# it, only compares it (see module comment: safety, not authority).
type ZoneClaim = { robot_id :: Str, cells :: List[Cell], from_ms :: Int, until_ms :: Int }

# Two half-open time windows [from, until) overlap iff each starts before
# the other ends.
fn interval_overlap(a_from :: Int, a_until :: Int, b_from :: Int, b_until :: Int) -> Bool {
  a_from < b_until and b_from < a_until
}

# Box-intersection test (do the two boxes share any volume), not a
# containment test — grant.lex's in_box_3d asks "is this point inside",
# this asks "do these two regions overlap at all".
fn cells_overlap(a :: Cell, b :: Cell) -> Bool
  examples {
    cells_overlap({ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }, { ws_min: { x: 0.5, y: 0.5, z: 0.0 }, ws_max: { x: 1.5, y: 1.5, z: 1.0 } }) => true,
    cells_overlap({ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }, { ws_min: { x: 1.0, y: 0.0, z: 0.0 }, ws_max: { x: 2.0, y: 1.0, z: 1.0 } }) => false
  }
{
  if a.ws_max.x <= b.ws_min.x {
    false
  } else {
    if b.ws_max.x <= a.ws_min.x {
      false
    } else {
      if a.ws_max.y <= b.ws_min.y {
        false
      } else {
        if b.ws_max.y <= a.ws_min.y {
          false
        } else {
          if a.ws_max.z <= b.ws_min.z {
            false
          } else {
            if b.ws_max.z <= a.ws_min.z {
              false
            } else {
              true
            }
          }
        }
      }
    }
  }
}

fn any_cells_overlap(as_ :: List[Cell], bs :: List[Cell]) -> Bool {
  list.fold(as_, false, fn (acc :: Bool, a :: Cell) -> Bool {
    if acc {
      true
    } else {
      list.fold(bs, false, fn (acc2 :: Bool, b :: Cell) -> Bool {
        if acc2 {
          true
        } else {
          cells_overlap(a, b)
        }
      })
    }
  })
}

# Two claims conflict iff they belong to different robots, their time
# windows overlap, and at least one pair of their cells overlaps. A claim
# never conflicts with another claim from the same robot_id (re-claiming
# or extending your own space isn't a collision).
fn claims_conflict(a :: ZoneClaim, b :: ZoneClaim) -> Bool
  examples {
    claims_conflict({ robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 0, until_ms: 1000 }, { robot_id: "r2", cells: [{ ws_min: { x: 0.5, y: 0.5, z: 0.0 }, ws_max: { x: 1.5, y: 1.5, z: 1.0 } }], from_ms: 500, until_ms: 1500 }) => true,
    claims_conflict({ robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 0, until_ms: 1000 }, { robot_id: "r2", cells: [{ ws_min: { x: 0.5, y: 0.5, z: 0.0 }, ws_max: { x: 1.5, y: 1.5, z: 1.0 } }], from_ms: 1000, until_ms: 1500 }) => false,
    claims_conflict({ robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 0, until_ms: 1000 }, { robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 0, until_ms: 2000 }) => false
  }
{
  if a.robot_id == b.robot_id {
    false
  } else {
    if not interval_overlap(a.from_ms, a.until_ms, b.from_ms, b.until_ms) {
      false
    } else {
      any_cells_overlap(a.cells, b.cells)
    }
  }
}

fn find_conflict(existing :: List[ZoneClaim], candidate :: ZoneClaim) -> Option[ZoneClaim] {
  list.fold(existing, None, fn (acc :: Option[ZoneClaim], e :: ZoneClaim) -> Option[ZoneClaim] {
    match acc {
      Some(_) => acc,
      None => if claims_conflict(e, candidate) {
        Some(e)
      } else {
        None
      },
    }
  })
}

# The one function callers need: does `candidate` conflict with anything
# already granted? Refuses outright on the first conflict found — no
# preemption, no reassignment (see module comment).
fn resolve(existing :: List[ZoneClaim], candidate :: ZoneClaim) -> Result[Unit, Str]
  examples {
    resolve([], { robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 0, until_ms: 1000 }) => Ok(()),
    resolve([{ robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 0, until_ms: 1000 }], { robot_id: "r2", cells: [{ ws_min: { x: 0.5, y: 0.5, z: 0.0 }, ws_max: { x: 1.5, y: 1.5, z: 1.0 } }], from_ms: 500, until_ms: 1500 }) => Err("zone conflict with robot r1"),
    resolve([{ robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 0, until_ms: 1000 }], { robot_id: "r1", cells: [{ ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 } }], from_ms: 1000, until_ms: 2000 }) => Ok(())
  }
{
  match find_conflict(existing, candidate) {
    None => Ok(()),
    Some(e) => Err(str.concat("zone conflict with robot ", e.robot_id)),
  }
}

