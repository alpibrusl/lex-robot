# lex-robot/a2a_robot_auth.lex — session-based auth for a2a_robot_server.lex's
# public A2A door: how do we stop a random agent from connecting to a
# publicly reachable robot and asking for nonsense or attacking it.
#
# Model: a caller self-presents an Ed25519-signed RobotCard (a2a_card.lex) to
# the new `session/open` JSON-RPC method. The signature proves possession of
# the private key matching the card's OWN declared pubkey — it does NOT by
# itself prove the caller is anyone you should trust (a Sybil attacker mints
# a fresh keypair for free). Real access control is a2a_consent.lex's
# ConsentPolicy.allowed_pubkeys — an operator-curated allowlist. An EMPTY
# allowlist means "any signed card is accepted" and is a MISCONFIGURATION for
# a genuinely public endpoint; it exists because a2a_consent.lex is shared
# with the peer_meet-style demos, where an open policy is sometimes the
# point, and because examples/a2a_robot_demo.lex (CI-exercised) intentionally
# runs one so llm_planner.lex's own ad-hoc identity (see that module) needs
# no pre-shared setup to pass smoke.sh.
#
# Once verified + consented, a2a_consent.escalate computes a session Grant —
# the INTERSECTION of the caller's declared skills and the operator's
# ceiling Grant, budget capped to the tighter of the two — persisted keyed
# by a fresh context_id, together with the session's OWN budget ledger (one
# caller exhausting their budget cannot starve another's).
#
# Why not a2a_handshake.lex: that state machine is a PULL model (agent A
# fetches and verifies agent B's card from B's own advertised endpoint,
# after an out-of-band QR bootstrap establishes B's pubkey) — built for two
# robots discovering each other. A public HTTP door serving arbitrary
# inbound callers is a PUSH model (the caller hands over its card directly,
# in the request); there is no OOB step, so the pubkey allowlist is the
# entire trust anchor. This module reuses a2a_card.lex (verify_card,
# parse_card) and a2a_consent.lex (decide, escalate) directly rather than
# a2a_handshake.lex's fetch-then-verify state machine.
#
# What this does NOT cover — read before relying on it:
#   - Transport security: this adds no TLS. policy.require_https refuses a
#     caller whose OWN advertised endpoint is http://, but does not stop the
#     session/open request itself arriving over plaintext HTTP if the
#     server is bound that way — put a real TLS terminator in front for a
#     genuinely public deployment (deploy/Caddyfile.example; README.md's
#     "TLS: terminate it in front, not inside" has the full reasoning —
#     std.net's plain-HTTP serve path has no TLS option in this toolchain).
#   - Replay window: a captured (card_json, sig_b64) pair is valid for as
#     long as the session it opens exists (until the operator restarts the
#     db or the row is otherwise cleared) — there is no per-request nonce
#     or expiry the way a2a_bootstrap.lex's BootstrapBlob has. Stealing a
#     signature lets an attacker open A session under that identity, not
#     hijack an already-open one (context_id is independent of the
#     signature once minted).
#   - mcp_server.lex's five shared skills (move_to/grasp/connect_charger/
#     read_joints/read_camera), when reached via a2a_robot_server.lex's
#     fallback path, get the session's narrowed SKILL list (gated at
#     a2a_robot_server.lex's single top-level check) but still share
#     mcp_server.lex's original single global BUDGET ledger, not a
#     per-session one — see a2a_robot_server.lex's dispatch_skill comment.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.float" as flt

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.sql" as sql

import "./types" as t

import "./budget" as bud

import "./a2a_card" as card

import "./a2a_consent" as consent

# ── Schema ────────────────────────────────────────────────────────────────
# Grant fields are stored as TEXT (via flt.to_str / str.to_float) rather than
# REAL columns — matching this codebase's existing convention of treating
# floats as strings at every other serialization boundary (see
# a2a_robot_server.lex's own detail-JSON building), and sidesteps depending
# on a SQL float-parameter constructor this package doesn't otherwise use.
#
# CREATE TABLE IF NOT EXISTS is idempotent, so this is safe to call on every
# open_session — not just once at a2a_robot_server.lex's run() startup —
# which matters for any caller that talks to dispatch_request directly
# (every test in this package does; a real deployment always goes through
# run(), but nothing here should silently depend on that).
fn init_sessions_table(db :: Db) -> [sql] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS a2a_sessions (context_id TEXT PRIMARY KEY, pubkey_b64 TEXT NOT NULL, skills TEXT NOT NULL, ws_min_x TEXT NOT NULL, ws_min_y TEXT NOT NULL, ws_min_z TEXT NOT NULL, ws_max_x TEXT NOT NULL, ws_max_y TEXT NOT NULL, ws_max_z TEXT NOT NULL, max_velocity TEXT NOT NULL, max_force TEXT NOT NULL, max_grip_force TEXT NOT NULL, actions_used INTEGER NOT NULL, started_ms INTEGER NOT NULL, action_cap INTEGER NOT NULL, wall_cap_ms INTEGER NOT NULL, created_at INTEGER NOT NULL)", []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn skills_to_col(skills :: List[Str]) -> Str
  examples {
    skills_to_col([]) => "",
    skills_to_col(["move_arm"]) => "move_arm",
    skills_to_col(["move_arm", "speak"]) => "move_arm,speak"
  }
{
  str.join(skills, ",")
}

fn skills_from_col(s :: Str) -> List[Str]
  examples {
    skills_from_col("") => [],
    skills_from_col("move_arm") => ["move_arm"],
    skills_from_col("move_arm,speak") => ["move_arm", "speak"]
  }
{
  if str.is_empty(s) {
    []
  } else {
    str.split(s, ",")
  }
}

fn parse_float_col(s :: Str, dflt :: Float) -> Float
  examples {
    parse_float_col("0.25", 0.0) => 0.25,
    parse_float_col("not a float", 9.9) => 9.9,
    parse_float_col("", 1.0) => 1.0
  }
{
  match str.to_float(s) {
    Some(v) => v,
    None => dflt,
  }
}

# ── Session identity: deterministic, no [random] needed ────────────────────
# Derived from what's already unique per open_session call (the caller's
# pubkey + their exact signed card + the server's own clock) via sha256 —
# same "deterministic beats [random]" preference identity.lex documents for
# keypairs. A collision would require the same pubkey presenting byte-
# identical cards in the same millisecond; harmless even then, since it can
# only re-derive that SAME caller's own session, never another's.
fn mint_context_id(pubkey_b64 :: Str, card_json :: Str, now_ms :: Int) -> [crypto] Str {
  crypto.base64url_encode(crypto.sha256(bytes.from_str(str.join([pubkey_b64, "|", card_json, "|", int.to_str(now_ms)], ""))))
}

# ── Open a session ──────────────────────────────────────────────────────────
type OpenResult = OpenOk({ context_id :: Str, grant :: t.Grant }) | OpenRefused(Str)

fn open_session(db :: Db, ceiling :: t.Grant, policy :: consent.ConsentPolicy, card_json :: Str, sig_b64 :: Str, now_ms :: Int) -> [sql, crypto] OpenResult {
  match init_sessions_table(db) {
    Err(e) => OpenRefused(str.concat("could not initialize session storage: ", e)),
    Ok(_) => match card.parse_card(card_json) {
      Err(e) => OpenRefused(str.concat("invalid card: ", e)),
      Ok(peer) => if not card.verify_card(card_json, peer.pubkey_b64, sig_b64) {
        OpenRefused("card signature verification failed")
      } else {
        match consent.decide(policy, peer) {
          Refuse(why) => OpenRefused(why),
          _ => {
            let session_grant := consent.escalate(ceiling, peer, policy)
            if list.is_empty(session_grant.skills) {
              OpenRefused("no shared skills between the requested card and the operator's grant")
            } else {
              let cid := mint_context_id(peer.pubkey_b64, card_json, now_ms)
              match persist_session(db, cid, peer.pubkey_b64, session_grant, now_ms) {
                Err(e) => OpenRefused(str.concat("could not persist session: ", e)),
                Ok(_) => OpenOk({ context_id: cid, grant: session_grant }),
              }
            }
          },
        }
      },
    },
  }
}

fn persist_session(db :: Db, cid :: Str, pubkey :: Str, g :: t.Grant, now_ms :: Int) -> [sql] Result[Unit, Str] {
  let q := "INSERT OR REPLACE INTO a2a_sessions (context_id, pubkey_b64, skills, ws_min_x, ws_min_y, ws_min_z, ws_max_x, ws_max_y, ws_max_z, max_velocity, max_force, max_grip_force, actions_used, started_ms, action_cap, wall_cap_ms, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  match sql.exec(db, q, [PStr(cid), PStr(pubkey), PStr(skills_to_col(g.skills)), PStr(flt.to_str(g.ws_min.x)), PStr(flt.to_str(g.ws_min.y)), PStr(flt.to_str(g.ws_min.z)), PStr(flt.to_str(g.ws_max.x)), PStr(flt.to_str(g.ws_max.y)), PStr(flt.to_str(g.ws_max.z)), PStr(flt.to_str(g.max_velocity)), PStr(flt.to_str(g.max_force)), PStr(flt.to_str(g.max_grip_force)), PInt(0), PInt(now_ms), PInt(g.budget_actions), PInt(g.budget_wall_ms), PInt(now_ms)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── Load a session (every tasks/send looks itself up here first) ───────────
type Session = { pubkey_b64 :: Str, grant :: t.Grant }

type SessionRow = { pubkey_b64 :: Str, skills :: Str, ws_min_x :: Str, ws_min_y :: Str, ws_min_z :: Str, ws_max_x :: Str, ws_max_y :: Str, ws_max_z :: Str, max_velocity :: Str, max_force :: Str, max_grip_force :: Str, action_cap :: Int, wall_cap_ms :: Int }

fn row_to_grant(row :: SessionRow) -> t.Grant
  examples {
    row_to_grant({ pubkey_b64: "k", skills: "move_arm,speak", ws_min_x: "0.0", ws_min_y: "0.0", ws_min_z: "0.0", ws_max_x: "0.5", ws_max_y: "0.5", ws_max_z: "0.5", max_velocity: "0.25", max_force: "10.0", max_grip_force: "15.0", action_cap: 20, wall_cap_ms: 60000 }) => { skills: ["move_arm", "speak"], ws_min: { x: 0.0, y: 0.0, z: 0.0 }, ws_max: { x: 0.5, y: 0.5, z: 0.5 }, max_velocity: 0.25, max_force: 10.0, max_grip_force: 15.0, budget_actions: 20, budget_wall_ms: 60000 }
  }
{
  { skills: skills_from_col(row.skills), ws_min: { x: parse_float_col(row.ws_min_x, 0.0), y: parse_float_col(row.ws_min_y, 0.0), z: parse_float_col(row.ws_min_z, 0.0) }, ws_max: { x: parse_float_col(row.ws_max_x, 0.0), y: parse_float_col(row.ws_max_y, 0.0), z: parse_float_col(row.ws_max_z, 0.0) }, max_velocity: parse_float_col(row.max_velocity, 0.0), max_force: parse_float_col(row.max_force, 0.0), max_grip_force: parse_float_col(row.max_grip_force, 0.0), budget_actions: row.action_cap, budget_wall_ms: row.wall_cap_ms }
}

fn load_session(db :: Db, cid :: Str) -> [sql] Option[Session] {
  let result :: Result[List[SessionRow], SqlError] := sql.query(db, "SELECT pubkey_b64, skills, ws_min_x, ws_min_y, ws_min_z, ws_max_x, ws_max_y, ws_max_z, max_velocity, max_force, max_grip_force, action_cap, wall_cap_ms FROM a2a_sessions WHERE context_id = ?", [PStr(cid)])
  match result {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ pubkey_b64: row.pubkey_b64, grant: row_to_grant(row) }),
    },
  }
}

# ── Per-session budget ledger (mirrors mcp_server.lex's ledger_read/write/
# charge_if_committed, but keyed by context_id instead of a single global
# row — see the module doc comment for the fallback-skill caveat) ──────────
fn session_ledger_read(db :: Db, cid :: Str, g :: t.Grant, now_ms :: Int) -> [sql] bud.Ledger {
  let result :: Result[List[{ actions_used :: Int, started_ms :: Int, action_cap :: Int, wall_cap_ms :: Int }], SqlError] := sql.query(db, "SELECT actions_used, started_ms, action_cap, wall_cap_ms FROM a2a_sessions WHERE context_id = ?", [PStr(cid)])
  match result {
    Err(_) => bud.start(g, now_ms),
    Ok(rows) => match list.head(rows) {
      None => bud.start(g, now_ms),
      Some(row) => { actions_used: row.actions_used, started_ms: row.started_ms, action_cap: row.action_cap, wall_cap_ms: row.wall_cap_ms },
    },
  }
}

fn session_ledger_write(db :: Db, cid :: Str, led :: bud.Ledger) -> [sql] Unit {
  let __lex_discard_4 := sql.exec(db, "UPDATE a2a_sessions SET actions_used = ? WHERE context_id = ?", [PInt(led.actions_used), PStr(cid)])
  ()
}

fn session_charge_if_committed(db :: Db, cid :: Str, led :: bud.Ledger, o :: t.Outcome) -> [sql] Unit {
  match o {
    Denied(_) => (),
    _ => session_ledger_write(db, cid, bud.spend(led)),
  }
}

