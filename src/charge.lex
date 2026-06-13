# charge.lex — OCPP-shaped charging client.
#
# Mirrors the real lex-charge service (ev-fleet/lex-charge):
#   POST <charge_url>/v1/chargers/<cp_id>/start  { connector_id, id_tag }
#   POST <charge_url>/v1/chargers/<cp_id>/stop   { transaction_id }
#
# Point charge_url at the depot sidecar (Tier-1 stand-in) or the real
# lex-charge. A session only starts if the connector is physically seated — so
# a non-zero transaction_id is real evidence the robot completed the connection.

import "std.str" as str

import "std.http" as http

import "std.bytes" as bytes

import "std.int" as int

import "std.list" as list

# Returns Some(transaction_id) if the session started (OCPP Accepted), else None.
fn start(charge_url :: Str, cp_id :: Str, connector_id :: Int, id_tag :: Str) -> [net] Result[Option[Int], Str] {
  let url := str.join([charge_url, "/v1/chargers/", cp_id, "/start"], "")
  let body := str.join(["{\"connector_id\":", int.to_str(connector_id), ",\"id_tag\":\"", id_tag, "\"}"], "")
  match http.post(url, bytes.from_str(body), "application/json") {
    Err(_) => Err("charge service unreachable"),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => Err("charge response decode failed"),
      Ok(s) => if str.contains(s, "\"Accepted\"") {
        Ok(Some(tx_id(s)))
      } else {
        Ok(None)
      },
    },
  }
}

fn stop(charge_url :: Str, cp_id :: Str, transaction_id :: Int) -> [net] Result[Unit, Str] {
  let url := str.join([charge_url, "/v1/chargers/", cp_id, "/stop"], "")
  let body := str.join(["{\"transaction_id\":", int.to_str(transaction_id), "}"], "")
  match http.post(url, bytes.from_str(body), "application/json") {
    Err(_) => Err("charge service unreachable"),
    Ok(_) => Ok(()),
  }
}

fn nth1(xs :: List[Str]) -> Str {
  match list.head(list.tail(xs)) { Some(v) => v, None => "" }
}

fn head_or(xs :: List[Str], dflt :: Str) -> Str {
  match list.head(xs) { Some(v) => v, None => dflt }
}

# Extract "transaction_id": N from a flat JSON response.
fn tx_id(json :: Str) -> Int {
  let seg := nth1(str.split(json, "\"transaction_id\":"))
  let tok := head_or(str.split(head_or(str.split(seg, ","), seg), "}"), seg)
  match str.to_int(str.trim(tok)) {
    Some(n) => n,
    None => 0,
  }
}
