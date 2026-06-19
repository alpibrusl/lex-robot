# examples/peer_provider.lex — Robot B, a standalone A2A peer.
#
# A genuinely separate agent (its own program, its own Ed25519 identity, its own
# card + bootstrap blob) — NOT the bazaar sidecar. A stranger (Robot A) meets it
# only by scanning its bootstrap QR, verifies its signed card, and buys one paid
# service: charge_battery. This is the "an agent you didn't write" half of the
# cross-vendor A2A story.
#
# Serves the four A2A endpoints a consumer's handshake needs:
#   GET  /a2a/public-card      signed public card   (text/plain: json\nsig)
#   GET  /a2a/extended-card    signed extended card (requires a bearer token)
#   GET  /a2a/bootstrap-blob   {"blob":"<base64url>"}
#   POST /a2a/task             JSON-RPC 2.0 → charge_battery
#
# Env: PEER_B_PORT (default 9100)
# Run via examples/peer_meet_run.sh

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

# ── helpers ──────────────────────────────────────────────────────────────────
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

# ── the service ──────────────────────────────────────────────────────────────
# charge_battery: sells N units at a fixed rate, returns a priced receipt.
fn charge_battery(args :: jv.Json) -> Str {
  let units := jv_int_or(args, "units", 0)
  let rate  := 4
  let price := units * rate
  str.join(["{\"status\":\"charged\",\"units\":", int.to_str(units), ",\"unit_price\":", int.to_str(rate), ",\"price\":", int.to_str(price), ",\"receipt\":\"chg-", int.to_str(units), "u\"}"], "")
}

fn dispatch(skill :: Str, args :: jv.Json) -> Str {
  if skill == "charge_battery" {
    charge_battery(args)
  } else {
    str.join(["{\"error\":\"unknown skill: ", skill, "\"}"], "")
  }
}

# ── entry point ──────────────────────────────────────────────────────────────
fn run() -> [env, io, sql, net, time, proc, concurrent, crypto, random, fs_read, fs_write, llm] Unit {
  let port := match env.get("PEER_B_PORT") {
    None    => 9100,
    Some(v) => match str.to_int(v) { Some(n) => n, None => 9100 },
  }
  let self_url := str.join(["http://localhost:", int.to_str(port)], "")
  let secret   := bytes.from_str("0000000000000000000000000000000b")   # Robot B's own seed
  let now      := time.now_ms()

  match crypto.ed25519_public_key(secret) {
    Err(e) => io.print(str.concat("[robot-b] key error: ", e)),
    Ok(pk) => {
      let pub_b64 := crypto.base64url_encode(pk)
      let skills  := [{ name: "charge_battery", description: "Sell battery charge units to a peer robot" }]
      let pub_card := { name: "Robot B", endpoint: self_url, pubkey_b64: pub_b64, tier: card.Public,   skills: skills, supports_extended: true }
      let ext_card := { name: "Robot B", endpoint: self_url, pubkey_b64: pub_b64, tier: card.Extended, skills: skills, supports_extended: true }
      let pub_json := card.card_to_json(pub_card)
      let ext_json := card.card_to_json(ext_card)
      match card.sign_card(pub_json, secret) {
        Err(e) => io.print(str.concat("[robot-b] sign pub error: ", e)),
        Ok(pub_sig) => match card.sign_card(ext_json, secret) {
          Err(e) => io.print(str.concat("[robot-b] sign ext error: ", e)),
          Ok(ext_sig) => {
            let pub_blob := str.join([pub_json, "\n", pub_sig], "")
            let ext_blob := str.join([ext_json, "\n", ext_sig], "")
            let blob     := { endpoint: self_url, ephemeral_token: "peer-token", peer_pubkey: pub_b64, nonce: "n-robot-b", expires_at: now + 86400000 }
            let blob_b64 := boot.encode(blob)
            let _ := io.print(str.join(["[robot-b] standalone peer on ", self_url, "  pubkey=", str.slice(pub_b64, 0, 16), "...  (Ctrl-C to stop)"], ""))

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
                  let result := dispatch(skill, args)
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
