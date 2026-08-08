# lex-robot/src/fleet_arbiter_server.lex — the fleet_traffic.lex safety
# layer, exposed over the network (epic #115, issue #117).
#
# `fleet/claim`, `fleet/release`, `fleet/state` — a small JSON-RPC-over-
# net.serve_fn door, the same shape a2a_robot_server.lex already uses for
# session/open and tasks/send.
#
# Deliberately NOT gated by a2a_consent.ConsentPolicy or a2a_robot_auth's
# session model: any caller's claim is honored on a first-claim/no-conflict
# basis, full stop. This is not an oversight — see fleet_traffic.lex's
# module comment. A home fleet and a bazaar full of strangers have
# completely different rules for "is this robot allowed to do X" (closed
# allowlist vs. signed-card handshake), but they must have the SAME rule
# for "did anyone else already claim this floor space", because refusing a
# stranger's collision-avoidance claim to protect your own fleet makes
# collisions more likely, not less. `robotId` here is a bare, unverified
# string — a claim is data about occupancy, not a capability grant, and
# granting/verifying capabilities is what a2a_robot_auth.lex and
# a2a_handshake.lex are for.
#
# `fleet/claim` reuses -32099 (spec-denied) for a conflicting claim — not
# because it's a consent decision, but because it's the existing code for
# "this precondition failed, nothing else about the request was wrong"
# (lex-agent's own convention: -32099 for precondition failures, -32602
# invalid params for malformed requests). `fleet/release` and `fleet/state`
# check the caller's claimed `robotId` against the stored owner only for
# data-integrity (catching an obvious typo'd claimId), never as a security
# boundary — this whole module has none by design.
#
# `fromMs` / `untilMs` are ABSOLUTE epoch milliseconds (`time.now_ms()`,
# same convention a2a_session.lex's `expires_at_ms` uses) — NOT a duration
# relative to the request. `load_live_claims` prunes anything with
# `until_ms <= now`, so passing small relative numbers (e.g. 0/60000) makes
# a claim look already-expired against the real wall clock and it's
# silently excluded from conflict checks — this bit the first hand-rolled
# curl test against this file before the fix was "use real epoch ms," not
# a code change.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.float" as flt

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.time" as time

import "std.sql" as sql

import "std.net" as net

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-agent/src/protocol" as rpc

import "./types" as t

import "./fleet_traffic" as ft

# ── Schema ────────────────────────────────────────────────────────────────
# One row per claim (the arbiter only ever constructs single-cell
# ZoneClaims from wire requests — fleet_traffic.lex's ZoneClaim supports a
# List[Cell] for future multi-cell path reservations, but nothing here
# needs that yet, so the wire contract stays a single box per claim).
fn init_fleet_tables(db :: Db) -> [sql] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS fleet_claims (claim_id TEXT PRIMARY KEY, robot_id TEXT NOT NULL, ws_min_x TEXT NOT NULL, ws_min_y TEXT NOT NULL, ws_min_z TEXT NOT NULL, ws_max_x TEXT NOT NULL, ws_max_y TEXT NOT NULL, ws_max_z TEXT NOT NULL, from_ms INTEGER NOT NULL, until_ms INTEGER NOT NULL, released INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)", []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn parse_float_col(s :: Str, dflt :: Float) -> Float
  examples {
    parse_float_col("0.25", 0.0) => 0.25,
    parse_float_col("not a float", 9.9) => 9.9
  }
{
  match str.to_float(s) {
    Some(v) => v,
    None => dflt,
  }
}

# ── Claim identity: deterministic, mirrors a2a_robot_auth.lex's
# mint_context_id (no [random] needed — same "deterministic beats
# [random]" preference identity.lex documents). ────────────────────────────
fn mint_claim_id(robot_id :: Str, from_ms :: Int, until_ms :: Int, now_ms :: Int) -> [crypto] Str {
  crypto.base64url_encode(crypto.sha256(bytes.from_str(str.join([robot_id, "|", int.to_str(from_ms), "|", int.to_str(until_ms), "|", int.to_str(now_ms)], ""))))
}

# ── Persistence ─────────────────────────────────────────────────────────────
type ClaimRow = { robot_id :: Str, ws_min_x :: Str, ws_min_y :: Str, ws_min_z :: Str, ws_max_x :: Str, ws_max_y :: Str, ws_max_z :: Str, from_ms :: Int, until_ms :: Int }

fn row_to_claim(row :: ClaimRow) -> ft.ZoneClaim {
  { robot_id: row.robot_id, cells: [{ ws_min: { x: parse_float_col(row.ws_min_x, 0.0), y: parse_float_col(row.ws_min_y, 0.0), z: parse_float_col(row.ws_min_z, 0.0) }, ws_max: { x: parse_float_col(row.ws_max_x, 0.0), y: parse_float_col(row.ws_max_y, 0.0), z: parse_float_col(row.ws_max_z, 0.0) } }], from_ms: row.from_ms, until_ms: row.until_ms }
}

fn load_live_claims(db :: Db, now_ms :: Int) -> [sql] List[ft.ZoneClaim] {
  let result :: Result[List[ClaimRow], SqlError] := sql.query(db, "SELECT robot_id, ws_min_x, ws_min_y, ws_min_z, ws_max_x, ws_max_y, ws_max_z, from_ms, until_ms FROM fleet_claims WHERE released = 0 AND until_ms > ?", [PInt(now_ms)])
  match result {
    Err(_) => [],
    Ok(rows) => list.map(rows, row_to_claim),
  }
}

fn persist_claim(db :: Db, claim_id :: Str, robot_id :: Str, cell :: ft.Cell, from_ms :: Int, until_ms :: Int, now_ms :: Int) -> [sql] Result[Unit, Str] {
  let q := "INSERT INTO fleet_claims (claim_id, robot_id, ws_min_x, ws_min_y, ws_min_z, ws_max_x, ws_max_y, ws_max_z, from_ms, until_ms, released, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)"
  match sql.exec(db, q, [PStr(claim_id), PStr(robot_id), PStr(flt.to_str(cell.ws_min.x)), PStr(flt.to_str(cell.ws_min.y)), PStr(flt.to_str(cell.ws_min.z)), PStr(flt.to_str(cell.ws_max.x)), PStr(flt.to_str(cell.ws_max.y)), PStr(flt.to_str(cell.ws_max.z)), PInt(from_ms), PInt(until_ms), PInt(now_ms)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

type OwnerRow = { robot_id :: Str }

fn claim_owner(db :: Db, claim_id :: Str) -> [sql] Option[Str] {
  let result :: Result[List[OwnerRow], SqlError] := sql.query(db, "SELECT robot_id FROM fleet_claims WHERE claim_id = ? AND released = 0", [PStr(claim_id)])
  match result {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some(row.robot_id),
    },
  }
}

fn release_claim_row(db :: Db, claim_id :: Str) -> [sql] Result[Unit, Str] {
  match sql.exec(db, "UPDATE fleet_claims SET released = 1 WHERE claim_id = ?", [PStr(claim_id)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn init_fleet_state_table(db :: Db) -> [sql] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS fleet_state (robot_id TEXT PRIMARY KEY, pose_x TEXT NOT NULL, pose_y TEXT NOT NULL, pose_z TEXT NOT NULL, battery_pct INTEGER NOT NULL, current_claim_id TEXT NOT NULL, updated_at INTEGER NOT NULL)", []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn upsert_state(db :: Db, robot_id :: Str, pose :: t.Vec3, battery_pct :: Int, current_claim_id :: Str, now_ms :: Int) -> [sql] Result[Unit, Str] {
  let q := "INSERT OR REPLACE INTO fleet_state (robot_id, pose_x, pose_y, pose_z, battery_pct, current_claim_id, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
  match sql.exec(db, q, [PStr(robot_id), PStr(flt.to_str(pose.x)), PStr(flt.to_str(pose.y)), PStr(flt.to_str(pose.z)), PInt(battery_pct), PStr(current_claim_id), PInt(now_ms)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── Wire helpers (mirrors a2a_robot_server.lex's required_str/required_obj) ─
fn required_str(j :: jv.Json, field :: Str) -> Result[Str, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_str(v) {
      Some(s) => Ok(s),
      None => Err(str.concat("param must be string: ", field)),
    },
  }
}

fn required_obj(j :: jv.Json, field :: Str) -> Result[jv.Json, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_obj(v) {
      Some(_) => Ok(v),
      None => Err(str.concat("param must be object: ", field)),
    },
  }
}

fn required_int(j :: jv.Json, field :: Str) -> Result[Int, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_int(v) {
      Some(n) => Ok(n),
      None => Err(str.concat("param must be integer: ", field)),
    },
  }
}

fn required_float(j :: jv.Json, field :: Str) -> Result[Float, Str] {
  match jv.get_field(j, field) {
    None => Err(str.concat("missing param: ", field)),
    Some(v) => match jv.as_float(v) {
      Some(f) => Ok(f),
      None => match jv.as_int(v) {
        Some(n) => Ok(int.to_float(n)),
        None => Err(str.concat("param must be number: ", field)),
      },
    },
  }
}

fn required_vec3(j :: jv.Json, field :: Str) -> Result[t.Vec3, Str] {
  match required_obj(j, field) {
    Err(e) => Err(e),
    Ok(sub) => match required_float(sub, "x") {
      Err(e) => Err(e),
      Ok(x) => match required_float(sub, "y") {
        Err(e) => Err(e),
        Ok(y) => match required_float(sub, "z") {
          Err(e) => Err(e),
          Ok(z) => Ok({ x: x, y: y, z: z }),
        },
      },
    },
  }
}

fn required_cell(params :: jv.Json) -> Result[ft.Cell, Str] {
  match required_vec3(params, "wsMin") {
    Err(e) => Err(e),
    Ok(lo) => match required_vec3(params, "wsMax") {
      Err(e) => Err(e),
      Ok(hi) => Ok({ ws_min: lo, ws_max: hi }),
    },
  }
}

# ── Handlers ─────────────────────────────────────────────────────────────────
fn handle_claim(db :: Db, req :: rpc.Request) -> [sql, crypto, time] rpc.Response {
  match required_str(req.params, "robotId") {
    Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
    Ok(robot_id) => match required_cell(req.params) {
      Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
      Ok(cell) => match required_int(req.params, "fromMs") {
        Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
        Ok(from_ms) => match required_int(req.params, "untilMs") {
          Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
          Ok(until_ms) => match init_fleet_tables(db) {
            Err(e) => rpc.fail(req.id, rpc.err_internal(), e),
            Ok(_) => {
              let now := time.now_ms()
              let candidate := { robot_id: robot_id, cells: [cell], from_ms: from_ms, until_ms: until_ms }
              let existing := load_live_claims(db, now)
              match ft.resolve(existing, candidate) {
                Err(reason) => rpc.fail(req.id, rpc.err_spec_denied(), reason),
                Ok(_) => {
                  let claim_id := mint_claim_id(robot_id, from_ms, until_ms, now)
                  match persist_claim(db, claim_id, robot_id, cell, from_ms, until_ms, now) {
                    Err(e) => rpc.fail(req.id, rpc.err_internal(), e),
                    Ok(_) => rpc.ok(req.id, JObj([("claimId", JStr(claim_id))])),
                  }
                },
              }
            },
          },
        },
      },
    },
  }
}

fn handle_release(db :: Db, req :: rpc.Request) -> [sql] rpc.Response {
  match required_str(req.params, "claimId") {
    Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
    Ok(claim_id) => match required_str(req.params, "robotId") {
      Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
      Ok(robot_id) => match init_fleet_tables(db) {
        Err(e) => rpc.fail(req.id, rpc.err_internal(), e),
        Ok(_) => match claim_owner(db, claim_id) {
          None => rpc.fail(req.id, rpc.err_invalid_params(), "no such live claim"),
          Some(owner) => if owner != robot_id {
            rpc.fail(req.id, rpc.err_invalid_params(), "claimId not held by this robotId")
          } else {
            match release_claim_row(db, claim_id) {
              Err(e) => rpc.fail(req.id, rpc.err_internal(), e),
              Ok(_) => rpc.ok(req.id, JObj([("released", JBool(true))])),
            }
          },
        },
      },
    },
  }
}

# `fleet/check` — the query skills.lex's move_base_claimed uses before
# actuating: does `robotId` currently hold a LIVE claim covering `point`?
# Always answers Ok (a query, not a mutation) — "not held" is a legitimate
# result, not an error, so the caller can turn it into its own Denied
# reason rather than this module inventing a domain-specific one.
fn handle_check(db :: Db, req :: rpc.Request) -> [sql, time] rpc.Response {
  match required_str(req.params, "robotId") {
    Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
    Ok(robot_id) => match required_vec3(req.params, "point") {
      Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
      Ok(point) => match init_fleet_tables(db) {
        Err(e) => rpc.fail(req.id, rpc.err_internal(), e),
        Ok(_) => {
          let now := time.now_ms()
          let claims := load_live_claims(db, now)
          rpc.ok(req.id, JObj([("held", JBool(ft.any_claim_covers(claims, robot_id, point)))]))
        },
      },
    },
  }
}

fn handle_state(db :: Db, req :: rpc.Request) -> [sql, time] rpc.Response {
  match required_str(req.params, "robotId") {
    Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
    Ok(robot_id) => match required_vec3(req.params, "pose") {
      Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
      Ok(pose) => match required_int(req.params, "batteryPct") {
        Err(e) => rpc.fail(req.id, rpc.err_invalid_params(), e),
        Ok(battery_pct) => {
          let current_claim_id := match jv.get_field(req.params, "currentClaimId") {
            Some(v) => match jv.as_str(v) {
              Some(s) => s,
              None => "",
            },
            None => "",
          }
          match init_fleet_state_table(db) {
            Err(e) => rpc.fail(req.id, rpc.err_internal(), e),
            Ok(_) => {
              let now := time.now_ms()
              match upsert_state(db, robot_id, pose, battery_pct, current_claim_id, now) {
                Err(e) => rpc.fail(req.id, rpc.err_internal(), e),
                Ok(_) => rpc.ok(req.id, JObj([("robotId", JStr(robot_id))])),
              }
            },
          }
        },
      },
    },
  }
}

fn handle_method(db :: Db, req :: rpc.Request) -> [sql, crypto, time] rpc.Response {
  if req.method == "fleet/claim" {
    handle_claim(db, req)
  } else {
    if req.method == "fleet/release" {
      handle_release(db, req)
    } else {
      if req.method == "fleet/state" {
        handle_state(db, req)
      } else {
        if req.method == "fleet/check" {
          handle_check(db, req)
        } else {
          rpc.fail(req.id, rpc.err_method_not_found(), str.concat("method not supported: ", req.method))
        }
      }
    }
  }
}

fn dispatch_request(db :: Db, body :: Str) -> [sql, crypto, time] Str {
  match rpc.parse_request(body) {
    Err(rpcerr) => rpc.response_to_str(ResErr(IdNull, rpcerr)),
    Ok(req) => rpc.response_to_str(handle_method(db, req)),
  }
}

# ── Entry point ───────────────────────────────────────────────────────────────
fn empty_headers() -> Map[Str, Str] {
  map.from_list([("content-type", "application/json")])
}

fn run(port :: Int, db_path :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Nil {
  match sql.open(db_path) {
    Err(_) => (),
    Ok(db) => {
      let __lex_discard_0 := init_fleet_tables(db)
      let __lex_discard_1 := init_fleet_state_table(db)
      net.serve_fn(port, fn (req :: Request) -> [time, crypto, sql, net] Response {
        if req.method == "POST" {
          { status: 200, body: BodyStr(dispatch_request(db, req.body)), headers: empty_headers() }
        } else {
          { status: 405, body: BodyStr("{\"error\":\"method not allowed\"}"), headers: empty_headers() }
        }
      })
    },
  }
}

