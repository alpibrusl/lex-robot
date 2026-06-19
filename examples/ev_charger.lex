# examples/ev_charger.lex — a charging station as a standalone A2A peer.
#
# One instance per station (configured by env). Each station has its own Ed25519
# identity, card, and bootstrap blob, and offers a `charge` skill priced per kWh.
# An EV fleet vehicle that has never met this station discovers it via its
# bootstrap blob, verifies the signed card, and pays under a fleet budget token.
#
# Env:
#   CHARGER_PORT   (default 9201)
#   CHARGER_NAME   (default "Charger")
#   CHARGER_RATE   credits per kWh (default 4)
#   CHARGER_SEED   32-byte Ed25519 seed (default derived from a fixed base)
#
# Run via examples/ev_fleet_run.sh

import "std.env"   as env
import "std.io"    as io
import "std.str"   as str
import "std.int"   as int
import "std.bytes" as bytes
import "std.map"   as map
import "std.crypto" as crypto
import "std.net"   as net
import "std.time"  as time

import "lex-schema/json_value" as jv

import "lex-web/src/router"   as router
import "lex-web/src/ctx"      as ctx
import "lex-web/src/response" as resp

import "../src/a2a_card"      as card
import "../src/a2a_bootstrap" as boot

fn jv_int_or(j :: jv.Json, key :: Str, dflt :: Int) -> Int {
  match jv.get_field(j, key) {
    Some(v) => match jv.as_int(v) { Some(n) => n, None => dflt },
    None    => dflt,
  }
}
fn jv_str_or(j :: jv.Json, key :: Str, dflt :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(v) => match jv.as_str(v) { Some(s) => s, None => dflt },
    None    => dflt,
  }
}
fn json_str(s :: Str) -> Str {
  str.concat("\"", str.concat(str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\""))
}
fn cors(r :: resp.Response) -> resp.Response {
  resp.with_header(resp.with_header(r, "access-control-allow-origin", "*"), "access-control-allow-headers", "Content-Type, Authorization, Last-Event-ID")
}

# A 32-byte seed derived from the station name so each station is a distinct peer.
fn seed_for(name :: Str) -> Bytes {
  let base := str.concat("ev-charger-seed-padding-000000000", name)
  bytes.from_str(str.slice(base, 0, 32))
}

# charge skill: sell `kwh` units of energy at `rate` cr/kWh, return a receipt.
fn do_charge(args :: jv.Json, rate :: Int) -> Str {
  let kwh   := jv_int_or(args, "kwh", 0)
  let price := kwh * rate
  str.join(["{\"status\":\"charged\",\"kwh\":", int.to_str(kwh), ",\"rate\":", int.to_str(rate), ",\"price\":", int.to_str(price), ",\"receipt\":\"chg-", int.to_str(kwh), "kwh\"}"], "")
}

# quote skill: advertise the per-kWh rate (so a vehicle can compare stations).
fn do_quote(rate :: Int) -> Str {
  str.join(["{\"rate\":", int.to_str(rate), ",\"currency\":\"EUR\",\"unit\":\"kWh\"}"], "")
}

fn dispatch(skill :: Str, args :: jv.Json, rate :: Int) -> Str {
  if skill == "charge" {
    do_charge(args, rate)
  } else {
    if skill == "quote" {
      do_quote(rate)
    } else {
      str.join(["{\"error\":\"unknown skill: ", skill, "\"}"], "")
    }
  }
}

fn run() -> [env, io, sql, net, time, proc, concurrent, crypto, random, fs_read, fs_write, llm] Unit {
  let port := match env.get("CHARGER_PORT") { None => 9201, Some(v) => match str.to_int(v) { Some(n) => n, None => 9201 } }
  let name := match env.get("CHARGER_NAME") { None => "Charger", Some(v) => v }
  let rate := match env.get("CHARGER_RATE") { None => 4, Some(v) => match str.to_int(v) { Some(n) => n, None => 4 } }
  let self_url := str.join(["http://localhost:", int.to_str(port)], "")
  let secret   := match env.get("CHARGER_SEED") { None => seed_for(name), Some(v) => bytes.from_str(str.slice(str.concat(v, "00000000000000000000000000000000"), 0, 32)) }
  let now      := time.now_ms()

  match crypto.ed25519_public_key(secret) {
    Err(e) => io.print(str.concat("[charger] key error: ", e)),
    Ok(pk) => {
      let pub_b64 := crypto.base64url_encode(pk)
      let skills  := [
        { name: "quote",  description: "Quote the per-kWh charging rate" },
        { name: "charge", description: str.join(["Deliver N kWh of charge at ", int.to_str(rate), " cr/kWh"], "") }
      ]
      let pub_card := { name: name, endpoint: self_url, pubkey_b64: pub_b64, tier: card.Public,   skills: skills, supports_extended: true }
      let ext_card := { name: name, endpoint: self_url, pubkey_b64: pub_b64, tier: card.Extended, skills: skills, supports_extended: true }
      let pub_json := card.card_to_json(pub_card)
      let ext_json := card.card_to_json(ext_card)
      match card.sign_card(pub_json, secret) {
        Err(e) => io.print(str.concat("[charger] sign pub error: ", e)),
        Ok(pub_sig) => match card.sign_card(ext_json, secret) {
          Err(e) => io.print(str.concat("[charger] sign ext error: ", e)),
          Ok(ext_sig) => {
            let pub_blob := str.join([pub_json, "\n", pub_sig], "")
            let ext_blob := str.join([ext_json, "\n", ext_sig], "")
            let blob     := { endpoint: self_url, ephemeral_token: "ev-token", peer_pubkey: pub_b64, nonce: str.concat("n-", name), expires_at: now + 86400000 }
            let blob_b64 := boot.encode(blob)
            let _ := io.print(str.join(["[charger] ", name, " @ ", self_url, "  ", int.to_str(rate), "cr/kWh  pubkey=", str.slice(pub_b64, 0, 12), "...  (Ctrl-C to stop)"], ""))

            let r0 := router.new()
            let r1 := router.route_effectful(r0, "OPTIONS", "/*path", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
              { body: "", status: 204, headers: map.from_list([("access-control-allow-origin", "*"), ("access-control-allow-methods", "GET, POST, OPTIONS"), ("access-control-allow-headers", "Content-Type, Authorization, Last-Event-ID")]) }
            })
            let r2 := router.route_effectful(r1, "GET", "/health", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
              cors(resp.json("{\"ok\":true}"))
            })
            let r3 := router.route_effectful(r2, "GET", "/a2a/public-card", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
              cors({ body: pub_blob, status: 200, headers: map.from_list([("content-type", "text/plain")]) })
            })
            let r4 := router.route_effectful(r3, "GET", "/a2a/extended-card", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
              match ctx.bearer_token(c) {
                None    => cors(resp.unauthorized("missing bearer token")),
                Some(_) => cors({ body: ext_blob, status: 200, headers: map.from_list([("content-type", "text/plain")]) }),
              }
            })
            let r5 := router.route_effectful(r4, "GET", "/a2a/bootstrap-blob", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
              cors(resp.json(str.join(["{\"blob\":", json_str(blob_b64), "}"], "")))
            })
            let r6 := router.route_effectful(r5, "POST", "/a2a/task", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
              match jv.parse(c.body) {
                Err(_) => cors(resp.bad_request("invalid json")),
                Ok(j)  => {
                  let rpc_id := jv_str_or(j, "id", "")
                  let task_j := match jv.get_field(j, "params") {
                    Some(p) => match jv.get_field(p, "task") { Some(tk) => tk, None => JObj([]) },
                    None    => JObj([]),
                  }
                  let skill  := jv_str_or(task_j, "skill", "")
                  let args   := match jv.get_field(task_j, "args") { Some(v) => v, None => JObj([]) }
                  let result := dispatch(skill, args, rate)
                  cors(resp.json(str.join(["{\"jsonrpc\":\"2.0\",\"id\":", json_str(rpc_id), ",\"result\":{\"kind\":\"artifact\",\"output\":", result, "}}"], "")))
                },
              }
            })

            let handler := fn (req :: Request) -> [env, io, sql, net, time, proc, concurrent, crypto, random, fs_read, fs_write, llm] Response {
              let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
              match router.dispatch_outcome(r6, raw) {
                DPlain(res) => { status: res.status, body: BodyStr(res.body), headers: res.headers },
                DStream(s)  => { status: s.status,   body: BodyStream(s.body), headers: s.headers },
              }
            }
            net.serve_fn(port, handler)
          },
        },
      }
    },
  }
}
