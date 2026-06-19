# examples/arena_demo.lex — the Robot Arena: shared control as a lex-games match.
#
# The games→robots bridge. One arm, several would-be controllers (a human
# TELEoperator and an LLM PLANner). Who may drive the arm RIGHT NOW is exactly
# the "whose turn is it" question lex-games already answers: each controller holds
# a signed, match-bound capability token for its side, and game.gate refuses any
# command that claims a side the token doesn't grant, or that acts out of turn —
# so a rogue agent cannot seize the arm. Commands that DO pass the control gate
# are then bounded by the robot's grant (workspace + force clamps, src/grant.lex),
# and every accepted command is appended to a hash-chained lex-trail episode that
# replays and verifies — a tamper-evident record of who moved the arm, when.
#
#   gate()  = control-authority arbitration (handoff / lockout)
#   grant   = physical safety envelope (the existing robot governance)
#   record  = replayable, tamper-evident episode
#
# Run: lex run --allow-effects crypto,fs_write,io,sql,time examples/arena_demo.lex run

import "std.io"     as io
import "std.str"    as str
import "std.int"    as int
import "std.float"  as flt
import "std.bytes"  as bytes
import "std.time"   as time
import "std.crypto" as crypto

import "../src/types"     as t
import "../src/grant"     as grant
import "../src/lex_games" as game

import "lex-trail/log" as trail

fn arena_secret() -> Bytes { bytes.from_str("lexrobot-arena-control-seed-0000") }
fn arena_pubkey() -> [crypto] Str { match crypto.ed25519_public_key(arena_secret()) { Ok(pk) => crypto.base64url_encode(pk), Err(_) => "" } }

fn vstr(p :: t.Vec3) -> Str { str.join(["(", flt.to_str(p.x), ",", flt.to_str(p.y), ",", flt.to_str(p.z), ")"], "") }

# The shared arm's grant: a unit workspace and a 15 N force ceiling.
fn arena_grant() -> t.Grant {
  { skills: ["move_to", "grasp"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 1.0, y: 1.0, z: 1.0 },
    max_velocity: 1.0, max_force: 15.0, max_grip_force: 20.0, budget_actions: 50, budget_wall_ms: 60000 }
}

type Arena = { parent :: Str, turn :: Str }

# One controller's attempt on the arm. First the CONTROL gate (capability + turn),
# then — only if it holds authority — the physical GRANT, then record the episode.
fn step(log :: trail.Log, g :: t.Grant, pub :: Str, mid :: Str, now :: Int, st :: Arena,
        by :: Str, token :: Str, kind :: Str, pose :: t.Pose, force :: Float, label :: Str)
    -> [io, sql, time, fs_write, crypto] Arena {
  let _ := io.print(str.join(["  ", by, " · ", label], ""))
  let side := game.match_token_side(pub, token, mid, now)
  match game.gate(side, by, st.turn) {
    MoveReject(why) => {
      let _ := io.print(str.concat("    ⛔ REFUSED (control): ", why))
      st
    },
    MoveOk => {
      # Holds authority this turn → now the physical grant decides.
      let verdict := if kind == "grasp" {
        let cf := grant.clamp_force(g, force)
        if cf < force { str.join(["CLAMPED grasp ", flt.to_str(force), "N → ", flt.to_str(cf), "N"], "") } else { str.join(["EXECUTED grasp ", flt.to_str(cf), "N"], "") }
      } else {
        if grant.in_workspace(g, pose.pos) { str.concat("EXECUTED move ", vstr(pose.pos)) } else { str.concat("BLOCKED by grant — outside workspace ", vstr(pose.pos)) }
      }
      let _ := io.print(str.concat("    ✓ control ok → ", verdict))
      let payload := str.join(["{\"by\":\"", by, "\",\"kind\":\"", kind, "\",\"verdict\":\"", verdict, "\"}"], "")
      let head := game.record(log, st.parent, payload)
      { parent: head, turn: if st.turn == "TELE" { "PLAN" } else { "TELE" } }
    },
  }
}

fn pose_at(x :: Float, y :: Float, z :: Float) -> t.Pose { { pos: { x: x, y: y, z: z }, rx: 0.0, ry: 0.0, rz: 0.0 } }

fn run() -> [io, sql, time, fs_write, crypto] Unit {
  let _ := io.print("══════════════════════════════════════════════════════")
  let _ := io.print("   ROBOT ARENA · shared arm control as a lex-games match")
  let _ := io.print("══════════════════════════════════════════════════════")
  let g := arena_grant()
  let pub := arena_pubkey()
  let now := time.now_ms()
  let mid := "arena-1"
  let exp := now + 3600000
  # Each controller is issued a signed, match-bound capability for ITS side only.
  let tele := game.issue_match_token(arena_secret(), "TELE", mid, exp)
  let plan := game.issue_match_token(arena_secret(), "PLAN", mid, exp)
  let _ := io.print(str.join(["  tokens issued — TELE ", str.slice(tele, 0, 12), "…  PLAN ", str.slice(plan, 0, 12), "…  (control starts: PLAN)"], ""))
  let _ := io.print("──────────────────────────────────────────────────────")
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let s0 := { parent: "", turn: "PLAN" }
      # 1. PLAN drives, in turn, in-bounds → executes; control hands to TELE.
      let s1 := step(log, g, pub, mid, now, s0, "PLAN", plan, "move", pose_at(0.5, 0.1, 0.2), 0.0, "move to approach pose")
      # 2. A rogue agent tries to grab the arm as PLAN — but it's TELE's turn and it
      #    only holds (at most) a different token → refused before the grant is touched.
      let s2 := step(log, g, pub, mid, now, s1, "PLAN", tele, "move", pose_at(0.5, 0.5, 0.2), 0.0, "rogue: act as PLAN with the wrong token")
      # 3. TELE takes its turn, in-bounds → executes; hands back to PLAN.
      let s3 := step(log, g, pub, mid, now, s2, "TELE", tele, "move", pose_at(0.3, 0.4, 0.2), 0.0, "teleop nudge")
      # 4. PLAN holds authority but proposes an out-of-bounds reach → grant blocks it.
      let s4 := step(log, g, pub, mid, now, s3, "PLAN", plan, "move", pose_at(0.5, 1.5, 0.2), 0.0, "reach behind the wall")
      # 5. Another rogue attempt, this time claiming TELE with PLAN's token → refused.
      let s5 := step(log, g, pub, mid, now, s4, "TELE", plan, "move", pose_at(0.2, 0.2, 0.2), 0.0, "rogue: act as TELE with the wrong token")
      # 6. TELE grasps too hard → grant clamps the force to the ceiling.
      let s6 := step(log, g, pub, mid, now, s5, "TELE", tele, "grasp", pose_at(0.0, 0.0, 0.0), 99.0, "grip it hard")
      let _ := io.print("──────────────────────────────────────────────────────")
      let v := game.verify_log(log)
      let _ := io.print(str.join(["  episode: ", int_str(v.count), " accepted commands, chain ", (if v.valid { "VALID — tamper-evident" } else { "BROKEN" })], ""))
      let _ := trail.close(log)
      io.print("  arena complete — control arbitrated, arm bounded, episode verifiable")
    },
  }
}

fn int_str(n :: Int) -> Str { int.to_str(n) }
