# lex-robot/src/fleet_client.lex — thin client for fleet_arbiter_server.lex's
# fleet/claim, fleet/release, fleet/check JSON-RPC door (epic #115, issue
# #118). Mirrors lex-agent/src/client.lex's own request/response plumbing
# (build_envelope-style encode, parse_response_body-style decode) rather
# than reinventing JSON-RPC a third time in this package.

import "std.str" as str

import "std.bytes" as bytes

import "std.http" as http

import "lex-schema/json_value" as jv

import "./types" as t

import "./fleet_traffic" as ft

fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("net: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn vec3_json(v :: t.Vec3) -> jv.Json {
  JObj([("x", JFloat(v.x)), ("y", JFloat(v.y)), ("z", JFloat(v.z))])
}

# One POST per call — the arbiter has no session/keep-alive concept (see
# fleet_arbiter_server.lex's module comment: a claim is data, not a
# capability, so there's nothing to authenticate up front). `error` field
# present → Err with its message; `result` field → Ok.
fn call(arbiter_url :: Str, method :: Str, params :: jv.Json) -> [net] Result[jv.Json, Str] {
  let env := JObj([("jsonrpc", JStr("2.0")), ("id", JInt(1)), ("method", JStr(method)), ("params", params)])
  let body := jv.stringify(env)
  match http.post(arbiter_url, bytes.from_str(body), "application/json") {
    Err(e) => Err(http_err_str(e)),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(m) => Err(m),
      Ok(s) => match jv.parse(s) {
        Err(p) => Err(p.message),
        Ok(j) => match jv.get_field(j, "error") {
          Some(ej) => Err(match jv.get_field(ej, "message") {
            Some(mv) => match jv.as_str(mv) {
              Some(m) => m,
              None => "arbiter error",
            },
            None => "arbiter error",
          }),
          None => match jv.get_field(j, "result") {
            Some(r) => Ok(r),
            None => Err("response has neither result nor error"),
          },
        },
      },
    },
  }
}

# Claim a cell for [from_ms, until_ms) (absolute epoch ms — see
# fleet_arbiter_server.lex's module comment). Returns the claim id on
# success, or the arbiter's conflict reason on refusal.
fn claim(arbiter_url :: Str, robot_id :: Str, cell :: ft.Cell, from_ms :: Int, until_ms :: Int) -> [net] Result[Str, Str] {
  let params := JObj([("robotId", JStr(robot_id)), ("wsMin", vec3_json(cell.ws_min)), ("wsMax", vec3_json(cell.ws_max)), ("fromMs", JInt(from_ms)), ("untilMs", JInt(until_ms))])
  match call(arbiter_url, "fleet/claim", params) {
    Err(e) => Err(e),
    Ok(r) => match jv.get_field(r, "claimId") {
      Some(v) => match jv.as_str(v) {
        Some(s) => Ok(s),
        None => Err("claimId not a string"),
      },
      None => Err("missing claimId in response"),
    },
  }
}

fn release(arbiter_url :: Str, claim_id :: Str, robot_id :: Str) -> [net] Result[Unit, Str] {
  let params := JObj([("claimId", JStr(claim_id)), ("robotId", JStr(robot_id))])
  match call(arbiter_url, "fleet/release", params) {
    Err(e) => Err(e),
    Ok(_) => Ok(()),
  }
}

# Does `robot_id` currently hold live space covering `point`?
fn check(arbiter_url :: Str, robot_id :: Str, point :: t.Vec3) -> [net] Result[Bool, Str] {
  let params := JObj([("robotId", JStr(robot_id)), ("point", vec3_json(point))])
  match call(arbiter_url, "fleet/check", params) {
    Err(e) => Err(e),
    Ok(r) => match jv.get_field(r, "held") {
      Some(v) => match jv.as_bool(v) {
        Some(b) => Ok(b),
        None => Err("held not a bool"),
      },
      None => Err("missing held in response"),
    },
  }
}

