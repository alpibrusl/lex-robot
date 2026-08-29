# sidecar/miio_sidecar.lex — the vacuum, spoken to directly. No Python,
# no Home Assistant, no cloud.
#
# `ha_sidecar` reaches a Xiaomi vacuum the way everything else in this
# repo reaches an appliance: through Home Assistant, which owns the
# device protocol and hands us normalized entities. That is the right
# default and it stays the default. This is the other thing — the same
# skills, spoken straight at the robot over its own wire format.
#
# Why bother, given HA works: the Samsung TV is a websocket and the
# washer is SmartThings cloud-only, so HA is not leaving. What changes is
# that "lex-robot needs a Python broker to touch hardware" stops being
# true, which was lex-robot#184's whole complaint. This is the proof.
#
# It became writable at all because of two lex-lang additions
# (lex-lang#760): `crypto.aes_cbc_encrypt_raw` and `net.udp_*`. Before
# those, no amount of Lex could have opened the socket.
#
# ── the protocol ────────────────────────────────────────────────────
#
# miio is a 32-byte header, big-endian, wrapping an AES-128-CBC payload:
#
#     0..2    magic 0x2131
#     2..4    total packet length
#     4..8    unknown (zero)
#     8..12   device id
#     12..16  stamp — the device's uptime in seconds
#     16..32  MD5 over the packet with the TOKEN written in this field
#     32..    AES-128-CBC(json), key = MD5(token), iv = MD5(key ++ token)
#
# The handshake is that header with length 0x20 and id/stamp/checksum all
# 0xff, sent unencrypted. That asymmetry is why a device can be
# discovered on a network without its token and cannot be commanded
# without it — and why `scripts/` could find this vacuum long before
# anything could drive it.
#
# The stamp is not decoration: a device rejects a packet whose stamp has
# drifted from its own clock, so every exchange begins with a handshake
# to read the current one. Cheap (one datagram) and stateless, which
# suits a sidecar that may sit idle for hours between commands.
#
# ── the device ──────────────────────────────────────────────────────
#
# Xiaomi Robot Vacuum X10, retail model B102GL, `dreame.vacuum.r2209`.
# This generation is MIoT-spec, so commands are property reads and
# actions against published (siid, piid/aiid) pairs rather than the older
# `app_start` verbs. The five this sidecar needs:
#
#     status       siid 2 piid 1   1=sweeping 2=standby 3=paused
#                                  5=returning 6=charging 13=charged
#     battery      siid 3 piid 1   0..100
#     start-sweep  siid 2 aiid 1
#     stop-sweep   siid 2 aiid 2
#     dock         siid 3 aiid 1
#
# ── what this deliberately does not do ──────────────────────────────
#
# No maps, no rooms, no zone cleaning. Those live in the vacuum's cloud
# map data, not on the local protocol, and reimplementing the map decode
# is a different project. If you want rooms, use Home Assistant with the
# dreame-vacuum integration. This is start, stop, dock, and status —
# exactly the skill surface `ha_sidecar` exposes, and no more.
#
# Env:
#   LEX_MIIO_HOST            the vacuum's IP (required)
#   LEX_MIIO_TOKEN           32 hex chars (required)
#   LEX_MIIO_PORT            default 54321
#   LEX_MIIO_TIMEOUT_MS      default 3000
#   LEX_ROBOT_SIDECAR_PORT   default 8900
#
# Run:
#   lex run --allow-effects env,io,net,crypto \
#     sidecar/miio_sidecar.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.bytes" as bytes

import "std.map" as mp

import "std.crypto" as crypto

import "std.net" as net

# ── big-endian helpers ───────────────────────────────────────────────
# std.bytes ships little-endian packers only, and miio is big-endian, so
# these compose from single bytes rather than reaching for u32_le and
# reversing — which would read as a trick rather than as the format.

# No examples: a Bytes literal is not expressible in an examples block,
# and an example's top-level call has to be the function being defined.
# `be32_at`'s round-trips below cover this arithmetic instead.
fn be16(n :: Int) -> Bytes {
  bytes.concat(bytes.u8(n / 256 - n / 65536 * 256), bytes.u8(n - n / 256 * 256))
}

fn be32(n :: Int) -> Bytes {
  bytes.concat(be16(n / 65536), be16(n - n / 65536 * 65536))
}

fn u8_or_zero(b :: Bytes, i :: Int) -> Int {
  match bytes.u8_at(b, i) {
    Ok(v) => v,
    Err(_) => 0,
  }
}

# Read a big-endian u32 at `off`. Out-of-range reads are zero rather than
# an error: every caller here has already length-checked the packet, and
# a Result would push a match into each of them for a case that cannot
# happen.
fn be32_at(b :: Bytes, off :: Int) -> Int
  examples {
    be32_at(be32(0), 0) => 0,
    be32_at(be32(1), 0) => 1,
    be32_at(be32(196078093), 0) => 196078093,
    be32_at(be32(4294967295), 0) => 4294967295
  }
{
  u8_or_zero(b, off) * 16777216 + u8_or_zero(b, off + 1) * 65536 + u8_or_zero(b, off + 2) * 256 + u8_or_zero(b, off + 3)
}

# ── framing ──────────────────────────────────────────────────────────

# 0x2131, the magic every miio packet opens with. Spelled as its two
# bytes rather than as 8497, because that is how it appears on the wire
# and how the header comment above describes it — writing the decimal
# is how it got typed wrong the first time.
fn magic() -> Int
  examples {
    magic() => 8497
  }
{
  33 * 256 + 49
}


fn magic_ok(pkt :: Bytes) -> Bool
  examples {
    magic_ok(hello_packet()) => true,
    magic_ok(bytes.from_str("nope")) => false,
    magic_ok(bytes.from_str("")) => false
  }
{
  u8_or_zero(pkt, 0) == 33 and u8_or_zero(pkt, 1) == 49
}

# key = MD5(token); iv = MD5(key ++ token). Both from the token alone,
# which is why possession of those 16 bytes is the whole of a device's
# access control.
fn payload_key(token :: Bytes) -> Bytes {
  crypto.md5(token)
}

fn payload_iv(token :: Bytes) -> Bytes {
  crypto.md5(bytes.concat(crypto.md5(token), token))
}

# The 16-byte header. Length is the WHOLE packet including the 32-byte
# preamble, not the payload — a device silently ignores a packet that
# gets this wrong, so it is worth being explicit about.
fn header(total_len :: Int, device_id :: Int, stamp :: Int) -> Bytes {
  bytes.concat_all([be16(magic()), be16(total_len), be32(0), be32(device_id), be32(stamp)])
}

# The checksum is MD5 over the packet with the TOKEN standing in for the
# checksum field — so producing one proves possession of the token, and
# the field is both integrity check and authentication.
fn checksum(head :: Bytes, token :: Bytes, body :: Bytes) -> Bytes {
  crypto.md5(bytes.concat_all([head, token, body]))
}

fn build_packet(token :: Bytes, device_id :: Int, stamp :: Int, body :: Bytes) -> Bytes {
  let head := header(32 + bytes.len(body), device_id, stamp)
  bytes.concat_all([head, checksum(head, token, body), body])
}

# The handshake packet: same header shape, no payload, every field after
# the length set to 0xff. Unencrypted by design.
fn hello_packet() -> Bytes {
  bytes.concat(be16(magic()), bytes.concat(be16(32), ff_bytes(28)))
}

fn ff_bytes(n :: Int) -> Bytes {
  if n <= 0 {
    bytes.from_str("")
  } else {
    bytes.concat(bytes.u8(255), ff_bytes(n - 1))
  }
}

# ── config ───────────────────────────────────────────────────────────

type Cfg = { host :: Str, token :: Bytes, port :: Int, timeout_ms :: Int }

fn env_or(key :: Str, fallback :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => if str.is_empty(v) {
      fallback
    } else {
      v
    },
    None => fallback,
  }
}

fn env_int(key :: Str, fallback :: Int) -> [env] Int {
  match str.to_int(env_or(key, "")) {
    Some(v) => v,
    None => fallback,
  }
}

fn load_cfg() -> [env] Result[Cfg, Str] {
  let host := env_or("LEX_MIIO_HOST", "")
  let tok_hex := env_or("LEX_MIIO_TOKEN", "")
  if str.is_empty(host) {
    Err("LEX_MIIO_HOST is not set — this sidecar talks to one vacuum by address")
  } else {
    match crypto.hex_decode(tok_hex) {
      Err(_) => Err("LEX_MIIO_TOKEN is not valid hex — expected 32 hex characters"),
      Ok(tok) => if bytes.len(tok) == 16 {
        Ok({ host: host, token: tok, port: env_int("LEX_MIIO_PORT", 54321), timeout_ms: env_int("LEX_MIIO_TIMEOUT_MS", 3000) })
      } else {
        Err(str.join(["LEX_MIIO_TOKEN must decode to 16 bytes, got ", int.to_str(bytes.len(tok))], ""))
      },
    }
  }
}

# ── the exchange ─────────────────────────────────────────────────────

type Session = { device_id :: Int, stamp :: Int }

# One datagram out, one back. Every miio exchange is this shape, so the
# socket lifetime is scoped to a single request/response rather than held
# open — a vacuum answers in milliseconds or not at all, and a socket
# kept across an idle hour is a file descriptor with nothing to show.
fn exchange(cfg :: Cfg, packet :: Bytes) -> [net] Result[Bytes, Str] {
  match net.udp_open(0) {
    Err(e) => Err(str.concat("could not open a socket: ", e)),
    Ok(sock) => {
      let sent := net.udp_send(sock, cfg.host, cfg.port, packet)
      match sent {
        Err(e) => {
          let __c := net.udp_close(sock)
          Err(str.concat("send failed: ", e))
        },
        Ok(_) => {
          let got := net.udp_recv(sock, cfg.timeout_ms)
          let __c := net.udp_close(sock)
          match got {
            Err(e) => Err(e),
            Ok(dg) => Ok(dg.data),
          }
        },
      }
    },
  }
}

# Read the device's id and current clock. Required before any command:
# the device checks the stamp against its own uptime and drops packets
# that have drifted, so a cached stamp goes stale on its own.
fn handshake(cfg :: Cfg) -> [net] Result[Session, Str] {
  match exchange(cfg, hello_packet()) {
    Err(e) => Err(str.concat("handshake: ", e)),
    Ok(reply) => if bytes.len(reply) < 32 {
      Err(str.join(["handshake: reply was ", int.to_str(bytes.len(reply)), " bytes, expected at least 32"], ""))
    } else {
      if magic_ok(reply) {
        Ok({ device_id: be32_at(reply, 8), stamp: be32_at(reply, 12) })
      } else {
        Err("handshake: reply is not a miio packet (wrong magic) — is something else on this port?")
      }
    },
  }
}

# Send one JSON command and return the decrypted JSON reply.
fn call(cfg :: Cfg, sess :: Session, json_body :: Str) -> [net] Result[Str, Str] {
  match crypto.aes_cbc_encrypt_raw(payload_key(cfg.token), payload_iv(cfg.token), bytes.from_str(json_body)) {
    Err(e) => Err(str.concat("encrypt: ", e)),
    Ok(body) => match exchange(cfg, build_packet(cfg.token, sess.device_id, sess.stamp, body)) {
      Err(e) => Err(e),
      Ok(reply) => if bytes.len(reply) <= 32 {
        # A device that dislikes a packet answers with silence, so a
        # header-only reply means it answered but had nothing to say.
        Err("device replied with an empty payload — wrong token, or a command it refused")
      } else {
        match crypto.aes_cbc_decrypt_raw(payload_key(cfg.token), payload_iv(cfg.token), bytes.slice(reply, 32, bytes.len(reply))) {
          Err(_) => Err("could not decrypt the reply — the token is almost certainly wrong"),
          Ok(plain) => match bytes.to_str(plain) {
            Err(_) => Err("the decrypted reply is not valid UTF-8 — wrong token, most likely"),
            Ok(text) => Ok(text),
          },
        }
      },
    },
  }
}

# Handshake then command, which is what every caller actually wants.
fn request(cfg :: Cfg, json_body :: Str) -> [net] Result[Str, Str] {
  match handshake(cfg) {
    Err(e) => Err(e),
    Ok(sess) => match call(cfg, sess, json_body) {
      Ok(reply) => Ok(reply),
      Err(e) => Err(explain_silence(e)),
    },
  }
}

# A device that dislikes a packet answers with silence, so almost every
# real failure arrives as the same timeout. But the handshake is
# UNENCRYPTED and does not involve the token — so reaching this point
# means the vacuum is switched on, on the network, and talking to us, and
# then went quiet the moment we used the token. That is a wrong token far
# more often than anything else, and saying so is the difference between
# a one-minute fix and an afternoon spent checking cables.
fn explain_silence(e :: Str) -> Str
  examples {
    explain_silence("net.udp_recv: timed out after 3000ms") => "the vacuum answered the handshake but ignored the command (net.udp_recv: timed out after 3000ms) — the token is wrong, most likely: a device drops packets whose checksum it cannot reproduce, and it drops them silently",
    explain_silence("send failed: nope") => "send failed: nope"
  }
{
  if str.contains(e, "timed out") {
    str.join(["the vacuum answered the handshake but ignored the command (", e, ") — the token is wrong, most likely: a device drops packets whose checksum it cannot reproduce, and it drops them silently"], "")
  } else {
    e
  }
}

# ── MIoT ─────────────────────────────────────────────────────────────

fn get_property_json(siid :: Int, piid :: Int) -> Str
  examples {
    get_property_json(2, 1) => "{\"id\":1,\"method\":\"get_properties\",\"params\":[{\"did\":\"lex\",\"siid\":2,\"piid\":1}]}"
  }
{
  str.join(["{\"id\":1,\"method\":\"get_properties\",\"params\":[{\"did\":\"lex\",\"siid\":", int.to_str(siid), ",\"piid\":", int.to_str(piid), "}]}"], "")
}

fn action_json(siid :: Int, aiid :: Int) -> Str
  examples {
    action_json(2, 1) => "{\"id\":1,\"method\":\"action\",\"params\":{\"did\":\"lex\",\"siid\":2,\"aiid\":1,\"in\":[]}}"
  }
{
  str.join(["{\"id\":1,\"method\":\"action\",\"params\":{\"did\":\"lex\",\"siid\":", int.to_str(siid), ",\"aiid\":", int.to_str(aiid), ",\"in\":[]}}"], "")
}

# Pull an integer out of a flat JSON response by key. -1 when absent, so
# a malformed reply can never be mistaken for a real reading — the same
# convention `home.lex` uses for a missing tariff.
fn jint(json :: Str, key :: Str) -> Int
  examples {
    jint("{\"value\":6,\"code\":0}", "\"value\":") => 6,
    jint("{\"value\":100}", "\"value\":") => 100,
    jint("{\"code\":0}", "\"value\":") => 0 - 1,
    jint("{\"value\":x}", "\"value\":") => 0 - 1
  }
{
  match list.head(list.tail(str.split(json, key))) {
    None => 0 - 1,
    Some(seg) => {
      let head := match list.head(str.split(seg, ",")) {
        Some(s) => s,
        None => seg,
      }
      let tok := match list.head(str.split(head, "}")) {
        Some(s) => s,
        None => head,
      }
      match str.to_int(str.trim(tok)) {
        Some(v) => v,
        None => 0 - 1,
      }
    },
  }
}

# The device's status vocabulary, mapped to words a caller can read. An
# unknown code is reported as itself rather than smoothed into "unknown":
# a firmware that starts returning 14 should surface that, not hide it.
fn status_name(code :: Int) -> Str
  examples {
    status_name(1) => "sweeping",
    status_name(2) => "standby",
    status_name(5) => "returning",
    status_name(6) => "charging",
    status_name(13) => "charged",
    status_name(99) => "unknown(99)"
  }
{
  if code == 1 {
    "sweeping"
  } else {
    if code == 2 {
      "standby"
    } else {
      if code == 3 {
        "paused"
      } else {
        if code == 5 {
          "returning"
        } else {
          if code == 6 {
            "charging"
          } else {
            if code == 13 {
              "charged"
            } else {
              str.join(["unknown(", int.to_str(code), ")"], "")
            }
          }
        }
      }
    }
  }
}

# ── skills ───────────────────────────────────────────────────────────
# Same wire contract as ha_sidecar: POST /skill/<name>, JSON in, JSON
# out, so the Lex side (`home.lex`) and the governance ledger cannot
# tell which sidecar answered.

fn jstr(key :: Str, val :: Str) -> Str {
  str.join(["\"", key, "\":\"", val, "\""], "")
}

fn state_json(entity :: Str, state :: Str, detail :: Str) -> Str {
  str.join(["{", jstr("entity", entity), ",", jstr("state", state), ",", jstr("detail", detail), "}"], "")
}

fn outcome_json(outcome :: Str, detail :: Str, verified :: Bool) -> Str {
  let flag := if verified {
    "true"
  } else {
    "false"
  }
  str.join(["{", jstr("outcome", outcome), ",", jstr("detail", detail), ",\"verified\":", flag, "}"], "")
}

fn read_status(cfg :: Cfg) -> [net] Result[Int, Str] {
  match request(cfg, get_property_json(2, 1)) {
    Err(e) => Err(e),
    Ok(reply) => {
      let v := jint(reply, "\"value\":")
      if v < 0 {
        Err(str.concat("no status in the device's reply: ", reply))
      } else {
        Ok(v)
      }
    },
  }
}

fn skill_read_state(cfg :: Cfg) -> [net] Str {
  match read_status(cfg) {
    Err(e) => state_json("vacuum", "", e),
    Ok(code) => {
      let battery := match request(cfg, get_property_json(3, 1)) {
        Err(_) => 0 - 1,
        Ok(r) => jint(r, "\"value\":"),
      }
      state_json("vacuum", status_name(code), str.join(["miio @ ", cfg.host, ", battery ", int.to_str(battery), "%"], ""))
    },
  }
}

# Actuation, verified the way ha_sidecar verifies since #202: the device
# accepting a command is not evidence it acted on one, so read the status
# back and report `timeout` when it did not move. Same reasoning, same
# outcome vocabulary — a caller cannot tell the two sidecars apart.
fn actuate(cfg :: Cfg, siid :: Int, aiid :: Int, expected :: Int, verb :: Str) -> [net] Str {
  match request(cfg, action_json(siid, aiid)) {
    Err(e) => outcome_json("stalled", e, false),
    Ok(_) => match read_status(cfg) {
      Err(e) => outcome_json("reached", str.join([verb, ", but the status could not be read back: ", e], ""), false),
      Ok(now) => if now == expected {
        outcome_json("reached", str.join([verb, "; vacuum is ", status_name(now)], ""), true)
      } else {
        outcome_json("timeout", str.join(["the device accepted ", verb, ", but its status is still '", status_name(now), "' — expected '", status_name(expected), "'. The command did nothing observable."], ""), false)
      },
    },
  }
}

fn skill_start(cfg :: Cfg) -> [net] Str {
  actuate(cfg, 2, 1, 1, "started")
}

# Stop means dock, not halt. Stopping a vacuum where it stands leaves it
# mid-floor, and an appliance that is now an obstacle in the hallway is
# not what a caller asking to stop it meant — the same call ha_sidecar
# makes when it maps stop onto `vacuum.return_to_base`.
fn skill_stop(cfg :: Cfg) -> [net] Str {
  actuate(cfg, 3, 1, 5, "sent to dock")
}

fn handle_skill(cfg :: Cfg, name :: Str) -> [net] Str {
  if name == "read_state" {
    skill_read_state(cfg)
  } else {
    if name == "appliance_start" {
      skill_start(cfg)
    } else {
      if name == "appliance_stop" {
        skill_stop(cfg)
      } else {
        str.join(["{", jstr("error", str.concat("unknown skill: ", name)), "}"], "")
      }
    }
  }
}

# ── server ───────────────────────────────────────────────────────────

fn json_headers() -> Map[Str, Str] {
  mp.from_list([("content-type", "application/json")])
}

fn reply(status :: Int, body :: Str) -> Response {
  { status: status, body: BodyStr(body), headers: json_headers() }
}

fn skill_name(path :: Str) -> Str
  examples {
    skill_name("/skill/read_state") => "read_state",
    skill_name("/skill/appliance_start") => "appliance_start",
    skill_name("/health") => ""
  }
{
  match str.strip_prefix(path, "/skill/") {
    Some(rest) => match list.head(str.split(rest, "?")) {
      Some(n) => n,
      None => rest,
    },
    None => "",
  }
}

fn health_json(cfg :: Cfg) -> Str {
  str.join(["{\"ok\":true,", jstr("mode", "miio direct"), ",", jstr("host", cfg.host), "}"], "")
}

fn run() -> [env, io, net] Unit {
  match load_cfg() {
    Err(e) => io.print(str.concat("[miio] refusing to start: ", e)),
    Ok(cfg) => {
      let port := env_int("LEX_ROBOT_SIDECAR_PORT", 8900)
      let __b := io.print(str.join(["lex-robot miio sidecar [", cfg.host, ":", int.to_str(cfg.port), "] on http://127.0.0.1:", int.to_str(port), "  (Ctrl-C to stop)"], ""))
      net.serve_fn(port, fn (req :: Request) -> [net] Response {
        if req.path == "/health" {
          reply(200, health_json(cfg))
        } else {
          let name := skill_name(req.path)
          if str.is_empty(name) {
            reply(404, "{\"error\":\"not found\"}")
          } else {
            reply(200, handle_skill(cfg, name))
          }
        }
      })
    },
  }
}
