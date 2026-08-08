# lex-robot/examples/fleet_clean_house_demo.lex — "clean the house," delegated
# across a closed 5-robot home fleet, coordinated by fleet_traffic.lex's
# zone-claim safety layer (epic #115, issue #119).
#
# Use case 1 from the epic: a home fleet is CLOSED and TRUSTED — every robot
# belongs to the same operator, so the authority question ("is this robot
# allowed to do X") is answered by an a2a_robot_auth.lex ConsentPolicy with a
# populated `allowed_pubkeys` allowlist (see a2a_robot_demo.lex's OPEN policy
# for the contrast — that's deliberately right for a local smoke target and
# deliberately WRONG for a real deployment; a real home fleet populates the
# allowlist with its own 5 keys instead). What none of that touches is the
# SAFETY question — "did anyone else already claim this room" — and that's
# fleet_traffic.lex / fleet_arbiter_server.lex, identity-agnostic by design.
#
# This demo exercises the safety half end-to-end against a REAL running
# fleet_arbiter_server: a coordinator assigns one room per robot (round-robin
# — the simplest correct assignment; this is not the place for a general
# task-allocation algorithm) and every robot claims its room for the
# cleaning session before "entering" it. Two robots never hold overlapping
# claims for the session — proven live against the arbiter, not asserted.
#
# The closed-allowlist half of #119 (a2a_robot_auth.lex's session auth,
# already shipped in #113) isn't re-demonstrated here with 5 full A2A
# servers + sidecars — that's 5 real HTTP+SQLite stacks for a property
# already covered by a2a_robot_demo.lex / tests/test_a2a_robot_grant.lex.
# What's new and worth a dedicated demo is the room-claim coordination.
#
# Run: scripts/fleet_clean_house_run.sh (starts the arbiter, runs this,
# tears it down), or by hand against an arbiter you started yourself:
#   lex run --allow-effects io,net,time \
#     examples/fleet_clean_house_demo.lex run "http://localhost:18910"

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.time" as time

import "../src/fleet_traffic" as ft

import "../src/fleet_client" as fleet

type Room = { name :: Str, cell :: ft.Cell }

# A 4x4m floor split into 5 non-overlapping rooms — the fixed household
# floor plan this demo assigns from. Real deployments would read this from
# a map; hardcoding it here keeps the demo self-contained.
fn kitchen() -> Room {
  { name: "kitchen", cell: { ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 2.0, y: 2.0, z: 1.0 } } }
}

fn living() -> Room {
  { name: "living", cell: { ws_min: { x: 2.0, y: 0.0, z: 0.0 }, ws_max: { x: 4.0, y: 2.0, z: 1.0 } } }
}

fn bedroom() -> Room {
  { name: "bedroom", cell: { ws_min: { x: 0.0, y: 2.0, z: 0.0 }, ws_max: { x: 2.0, y: 4.0, z: 1.0 } } }
}

fn bathroom() -> Room {
  { name: "bathroom", cell: { ws_min: { x: 2.0, y: 2.0, z: 0.0 }, ws_max: { x: 3.0, y: 4.0, z: 0.5 } } }
}

fn hallway() -> Room {
  { name: "hallway", cell: { ws_min: { x: 3.0, y: 2.0, z: 0.0 }, ws_max: { x: 4.0, y: 4.0, z: 1.0 } } }
}

# Round-robin room -> robot assignment. One robot, one room, five rooms, no
# room assigned twice — the simplest correct decomposition of "clean the
# house" into per-robot sub-tasks (see the module comment for why a
# general task-allocation algorithm is explicitly out of scope here).
fn fleet_assignments() -> List[(Str, Room)] {
  [("robot-1", kitchen()), ("robot-2", living()), ("robot-3", bedroom()), ("robot-4", bathroom()), ("robot-5", hallway())]
}

fn claim_room(arbiter_url :: Str, robot_id :: Str, room :: Room, from_ms :: Int, until_ms :: Int) -> [net, io] Bool {
  match fleet.claim(arbiter_url, robot_id, room.cell, from_ms, until_ms) {
    Err(e) => {
      let __p := io.print(str.join(["  [", robot_id, "] DENIED ", room.name, ": ", e], ""))
      false
    },
    Ok(claim_id) => {
      let __p := io.print(str.join(["  [", robot_id, "] claimed ", room.name, " (", claim_id, ")"], ""))
      true
    },
  }
}

fn run(arbiter_url :: Str) -> [io, net, time] Unit {
  let __0 := io.print("══════════════════════════════════════════════════════")
  let __1 := io.print("   CLEAN THE HOUSE  ·  5-robot home fleet, one room each")
  let __2 := io.print("══════════════════════════════════════════════════════")
  let now := time.now_ms()
  let session_until := now + 1800000
  let assignments := fleet_assignments()
  let __3 := io.print("assigning rooms:")
  let results := list.map(assignments, fn (pair :: (Str, Room)) -> [net, io] Bool {
    match pair {
      (robot_id, room) => claim_room(arbiter_url, robot_id, room, now, session_until),
    }
  })
  let all_ok := list.fold(results, true, fn (acc :: Bool, ok :: Bool) -> Bool {
    acc and ok
  })
  let __4 := io.print("")
  let __5 := if all_ok {
    io.print("all 5 rooms claimed with zero conflicts — the cleaning pass can proceed.")
  } else {
    io.print("one or more rooms were refused — see above. (Expected only if two robots were assigned overlapping cells, which fleet_assignments() never does.)")
  }
  let __6 := io.print("")
  let __7 := io.print("sanity check: an unassigned robot trying to re-claim the kitchen mid-session...")
  let intruder_ok := claim_room(arbiter_url, "unassigned-robot-6", kitchen(), now + 1000, session_until)
  if intruder_ok {
    io.print("BUG: expected the re-claim to be refused")
  } else {
    io.print("...correctly refused. The room stays robot-1's for the session.")
  }
}

