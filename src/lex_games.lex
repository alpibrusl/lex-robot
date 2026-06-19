# src/lex_games.lex — a tiny harness for server-authoritative turn games.
#
# The two cross-cutting concerns that make a Lex game cheat-resistant and
# verifiable live here, game-agnostic; a specific game plugs in its own board
# and rules (see examples/ttt.lex):
#
#   gate()    — capability + turn enforcement. A connection controls exactly one
#               side; it CANNOT submit a move as another side, nor out of turn.
#               This is the "anti-cheat by construction" property: the illegal
#               call is refused before any game logic runs.
#   record()  — append each APPLIED move to a hash-chained lex-trail log, so the
#               whole match is a tamper-evident, replayable record.
#
# Effects: gate is pure; record is [sql, time].

import "std.str" as str

import "lex-trail/log" as trail

# Result of the capability + turn check.
type MoveCheck = MoveOk | MoveReject(Str)

# Capability + turn gate. `session_side` is the side this connection is allowed
# to control (its capability); `move_by` is the side the move claims to act as;
# `turn` is whose move it currently is.
fn gate(session_side :: Str, move_by :: Str, turn :: Str) -> MoveCheck {
  if move_by != session_side {
    MoveReject(str.join(["capability denied: this player controls ", session_side, ", cannot act as ", move_by], ""))
  } else {
    if move_by != turn {
      MoveReject(str.join(["out of turn: it is ", turn, "'s move"], ""))
    } else {
      MoveOk
    }
  }
}

fn is_ok(c :: MoveCheck) -> Bool {
  match c { MoveOk => true, MoveReject(_) => false }
}

fn reason(c :: MoveCheck) -> Str {
  match c { MoveOk => "", MoveReject(r) => r }
}

# Append an applied move to the hash-chained replay log; returns the new chain
# head (use it as the parent of the next move). On error the parent is unchanged.
fn record(log :: trail.Log, parent :: Str, payload :: Str) -> [sql, time] Str {
  let par := if str.is_empty(parent) { None } else { Some(parent) }
  match trail.append(log, "move", par, payload) {
    Ok(ev) => ev.id,
    Err(_) => parent,
  }
}
