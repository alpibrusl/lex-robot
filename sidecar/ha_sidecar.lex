# sidecar/ha_sidecar.lex — Lex-native drop-in for ha_sidecar.py.
#
# Same env vars, same HTTP API. No Python.
#
# One sidecar makes every Home Assistant device a grant-gated skill: HA
# already normalizes TVs, washers, plugs and chargers into entities behind one
# LOCAL REST API with a token, so this is a single adapter instead of one
# sidecar per appliance brand. An appliance command is an actuation with real
# costs -- water, heat, energy cents -- so "may this program start the washer,
# at this tariff?" is a typed, auditable, refusable question.
#
# Why this one is in Lex (docs/LEX_VS_PYTHON.md): the authority is the point.
# `appliance_start` is an actuating capability, and the effect row says so --
# a program that only reads the house cannot reach it.
#
# Skills (POST /skill/<name>, same protocol as every lex-robot sidecar):
#
#     read_state      {"entity": "..."}  -> {"entity","state","detail"}
#     read_tariff     {"at": "HH:MM"?}   -> {"price_cents_kwh","period","at"}
#     appliance_start {"entity": "..."}  -> outcome
#     appliance_stop  {"entity": "..."}  -> outcome
#
# Money convention: INTEGER cents per kWh (lex-os: never floats in a budget).
#
# Env vars (identical to the Python):
#   LEX_HA_URL, LEX_HA_TOKEN         both set -> real house; otherwise stub
#   LEX_HA_START_SERVICE             default switch.turn_on
#   LEX_HA_STOP_SERVICE              default switch.turn_off
#   LEX_HA_TARIFF_ENTITY             a PVPC/Nordpool-style price sensor
#   LEX_HA_STUB_NOW                  default "13:00" (peak -- keeps the wash
#                                    demo's refusal reproducible in CI)
#   LEX_ROBOT_SIDECAR_PORT           default 8900
#
# Run:
#   lex run --allow-effects env,io,net,sql,fs_read,fs_write \
#     sidecar/ha_sidecar.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.float" as flt

import "std.json" as json

import "std.list" as list

import "std.map" as map

import "std.bytes" as bytes

import "std.http" as http

import "std.net" as net

import "std.sql" as sql

# ── The tariff, as pure arithmetic ────────────────────────────────────────────
# A caricature of the Spanish PVPC three-period day, in integer cents/kWh.
# Pure, so the schedule is pinned by examples that run at `lex check` time
# rather than by a test file that can drift from it.
fn stub_tariff(hour :: Int) -> (Int, Str)
  examples {
    stub_tariff(3) => (11, "valley"),
    stub_tariff(0) => (11, "valley"),
    stub_tariff(8) => (19, "flat"),
    stub_tariff(13) => (32, "peak"),
    stub_tariff(20) => (32, "peak"),
    stub_tariff(23) => (19, "flat")
  }
{
  if hour < 8 {
    (11, "valley")
  } else {
    if hour >= 10 and hour < 14 {
      (32, "peak")
    } else {
      if hour >= 18 and hour < 22 {
        (32, "peak")
      } else {
        (19, "flat")
      }
    }
  }
}

# "13:00" -> 13. Anything that isn't an hour is an error, never a guess: a
# tariff read against a fabricated hour would price the wrong period.
fn parse_hour(at :: Str) -> Result[Int, Str]
  examples {
    parse_hour("13:00") => Ok(13),
    parse_hour("07:30") => Ok(7),
    parse_hour("25:00") => Ok(1),
    parse_hour("") => Err("bad time '' (use HH:MM)"),
    parse_hour("noon") => Err("bad time 'noon' (use HH:MM)")
  }
{
  let head := match list.head(str.split(at, ":")) {
    Some(h) => h,
    None => "",
  }
  match str.to_int(head) {
    None => Err(str.join(["bad time '", at, "' (use HH:MM)"], "")),
    Some(h) => Ok(hour_of_day(h)),
  }
}

# Wrap an hour into 0..23 the way Python's `% 24` does. std.int has no rem, and
# spelling it out keeps the wrap visible rather than hidden in an operator.
fn hour_of_day(h :: Int) -> Int
  examples {
    hour_of_day(13) => 13,
    hour_of_day(25) => 1,
    hour_of_day(48) => 0,
    hour_of_day(0) => 0,
    hour_of_day(0 - 5) => 19
  }
{
  let r := h - h / 24 * 24
  if r < 0 {
    r + 24
  } else {
    r
  }
}

fn two_digits(n :: Int) -> Str
  examples {
    two_digits(7) => "07",
    two_digits(13) => "13",
    two_digits(0) => "00"
  }
{
  if n < 10 {
    str.concat("0", int.to_str(n))
  } else {
    int.to_str(n)
  }
}

# What an appliance rests at when it is not running. A washer idles; anything
# else is simply off -- the same split the Python stub makes.
fn resting_state(entity :: Str) -> Str
  examples {
    resting_state("washer.main") => "idle",
    resting_state("tv.livingroom") => "off",
    resting_state("") => "off"
  }
{
  match str.strip_prefix(entity, "washer") {
    Some(_) => "idle",
    None => "off",
  }
}

# "switch.turn_on" -> ("switch", "turn_on"). Service names vary by integration
# (a SmartThings washer differs from a smart plug), which is why this is
# configuration rather than code.
fn split_service(service :: Str) -> (Str, Str)
  examples {
    split_service("switch.turn_on") => ("switch", "turn_on"),
    split_service("vacuum.start") => ("vacuum", "start"),
    split_service("noservice") => ("noservice", "")
  }
{
  let parts := str.split(service, ".")
  let dom := match list.head(parts) {
    Some(d) => d,
    None => "",
  }
  let rest := match list.head(list.tail(parts)) {
    Some(n) => n,
    None => "",
  }
  (dom, rest)
}

# EUR/kWh -> integer cents, rounded rather than truncated. Prices are positive,
# so +0.5 before truncation is the same as rounding; a negative tariff (which
# real day-ahead markets do produce) would need a signed round, and this
# returns 0 rather than pretending otherwise.
fn eur_to_cents(eur :: Float) -> Int
  examples {
    eur_to_cents(0.32) => 32,
    eur_to_cents(0.1149) => 11,
    eur_to_cents(0.115) => 12,
    eur_to_cents(0.0 - 0.05) => 0
  }
{
  if eur < 0.0 {
    0
  } else {
    flt.to_int(eur * 100.0 + 0.5)
  }
}

# ── Config ────────────────────────────────────────────────────────────────────
fn env_or(key :: Str, fallback :: Str) -> [env] Str {
  match env.get(key) {
    None => fallback,
    Some(v) => if str.is_empty(v) {
      fallback
    } else {
      v
    },
  }
}

fn cfg_url() -> [env] Str {
  let raw := env_or("LEX_HA_URL", "")
  match str.strip_suffix(raw, "/") {
    Some(trimmed) => trimmed,
    None => raw,
  }
}

fn cfg_token() -> [env] Str {
  env_or("LEX_HA_TOKEN", "")
}

fn cfg_start_service() -> [env] Str {
  env_or("LEX_HA_START_SERVICE", "switch.turn_on")
}

fn cfg_stop_service() -> [env] Str {
  env_or("LEX_HA_STOP_SERVICE", "switch.turn_off")
}

fn cfg_tariff_entity() -> [env] Str {
  env_or("LEX_HA_TARIFF_ENTITY", "")
}

fn cfg_stub_now() -> [env] Str {
  env_or("LEX_HA_STUB_NOW", "13:00")
}

fn cfg_port() -> [env] Int {
  match str.to_int(env_or("LEX_ROBOT_SIDECAR_PORT", "8900")) {
    Some(p) => p,
    None => 8900,
  }
}

# Real mode needs BOTH. One without the other is a misconfiguration, and
# falling back to the stub house silently would answer questions about a
# real house with made-up state.
fn use_ha(url :: Str, token :: Str) -> Bool
  examples {
    use_ha("http://ha.local:8123", "tok") => true,
    use_ha("http://ha.local:8123", "") => false,
    use_ha("", "tok") => false,
    use_ha("", "") => false
  }
{
  not str.is_empty(url) and not str.is_empty(token)
}

# ── JSON out ──────────────────────────────────────────────────────────────────
fn jesc(s :: Str) -> Str
  examples {
    jesc("plain") => "plain",
    jesc("say \"hi\"") => "say \\\"hi\\\"",
    jesc("a\\b") => "a\\\\b"
  }
{
  str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

fn jstr(key :: Str, value :: Str) -> Str {
  str.join(["\"", jesc(key), "\":\"", jesc(value), "\""], "")
}

fn state_json(entity :: Str, state :: Str, detail :: Str) -> Str {
  str.join(["{", jstr("entity", entity), ",", jstr("state", state), ",", jstr("detail", detail), "}"], "")
}

fn outcome_json(outcome :: Str, detail :: Str) -> Str {
  str.join(["{", jstr("outcome", outcome), ",", jstr("detail", detail), "}"], "")
}

fn error_json(detail :: Str) -> Str {
  str.join(["{", jstr("error", detail), "}"], "")
}

fn tariff_json(cents :: Int, period :: Str, at :: Str) -> Str {
  str.join(["{\"price_cents_kwh\":", int.to_str(cents), ",", jstr("period", period), ",", jstr("at", at), "}"], "")
}

# ── The stub house ────────────────────────────────────────────────────────────
# Lex has no mutable globals and net.serve_fn's handler is a function of the
# request alone, so the stub house's entity states live in SQLite -- the same
# way sim_sidecar.lex holds its state. The table is recreated at startup, which
# keeps the Python's fresh-on-restart semantics rather than quietly gaining
# persistence the drop-in it replaces never had.
fn stub_db_path(port :: Int) -> Str {
  str.join(["/tmp/lex-ha-", int.to_str(port), ".db"], "")
}

fn init_stub(db :: Db) -> [sql] Unit {
  let __lex_discard_1 := sql.exec(db, "CREATE TABLE IF NOT EXISTS entities (id TEXT PRIMARY KEY, state TEXT NOT NULL)", [])
  let __lex_discard_2 := sql.exec(db, "DELETE FROM entities", [])
  let __lex_discard_3 := sql.exec(db, "INSERT INTO entities (id, state) VALUES ('washer.main','idle')", [])
  let __lex_discard_4 := sql.exec(db, "INSERT INTO entities (id, state) VALUES ('tv.livingroom','off')", [])
  ()
}

type EntityRow = { id :: Str, state :: Str }

fn stub_entities(db :: Db) -> [sql] List[EntityRow] {
  let r :: Result[List[EntityRow], SqlError] := sql.query(db, "SELECT id, state FROM entities ORDER BY id", [])
  match r {
    Err(_) => [],
    Ok(rows) => rows,
  }
}

fn stub_lookup(db :: Db, entity :: Str) -> [sql] Option[Str] {
  list.fold(stub_entities(db), None, fn (acc :: Option[Str], row :: EntityRow) -> Option[Str] {
    match acc {
      Some(s) => Some(s),
      None => if row.id == entity {
        Some(row.state)
      } else {
        None
      },
    }
  })
}

fn known_entities(db :: Db) -> [sql] Str {
  str.join(list.map(stub_entities(db), fn (row :: EntityRow) -> Str {
    row.id
  }), ", ")
}

fn stub_read_state(db :: Db, entity :: Str) -> [sql] Str {
  match stub_lookup(db, entity) {
    Some(s) => state_json(entity, s, "(stub house)"),
    None => state_json(entity, "", str.join(["(stub) unknown entity '", entity, "' (stub house has: ", known_entities(db), ")"], "")),
  }
}

fn stub_set(db :: Db, entity :: Str, running :: Bool, verb :: Str) -> [sql] Str {
  match stub_lookup(db, entity) {
    None => outcome_json("stalled", str.join(["(stub) unknown entity '", entity, "'"], "")),
    Some(_) => {
      let next := if running {
        "running"
      } else {
        resting_state(entity)
      }
      let q := str.join(["UPDATE entities SET state = '", next, "' WHERE id = '", entity, "'"], "")
      let __lex_discard_5 := sql.exec(db, q, [])
      outcome_json("reached", str.join(["(stub) ", entity, " ", verb], ""))
    },
  }
}

fn stub_read_tariff(at_raw :: Str, stub_now :: Str) -> Str {
  let at := if str.is_empty(at_raw) {
    stub_now
  } else {
    at_raw
  }
  match parse_hour(at) {
    Err(e) => error_json(e),
    Ok(hour) => match stub_tariff(hour) {
      (price, period) => tariff_json(price, period, str.concat(two_digits(hour), ":00")),
    },
  }
}

# ── The real house ────────────────────────────────────────────────────────────
# Errors are passed through honestly -- an unreachable HA is a stalled outcome
# carrying the reason, never a fabricated success.
type Cfg = { url :: Str, token :: Str, start_service :: Str, stop_service :: Str, tariff_entity :: Str, stub_now :: Str, real :: Bool }

fn http_err_str(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("net: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn ha_req(cfg :: Cfg, method :: Str, path :: Str, body :: Option[Bytes]) -> HttpRequest {
  let req0 := { method: method, url: str.concat(cfg.url, path), headers: map.new(), body: body, timeout_ms: None }
  http.with_header(http.with_header(http.with_timeout_ms(req0, 15000), "Content-Type", "application/json"), "Authorization", str.concat("Bearer ", cfg.token))
}

# A non-2xx from HA is an error here, not a body to parse.
#
# This is the one place the port could not be a literal transcription:
# urllib's `urlopen` RAISES on 4xx/5xx, so the Python's try/except turns a 401
# into "HA unreachable: HTTP Error 401". `http.send` returns Ok with the status
# instead, so an unchecked port would read a 401 body as state and report the
# appliance as off. Same observable behaviour, explicitly.
fn ha_text(cfg :: Cfg, method :: Str, path :: Str, body :: Option[Bytes]) -> [net] Result[Str, Str] {
  match http.send(ha_req(cfg, method, path, body)) {
    Err(e) => Err(http_err_str(e)),
    Ok(resp) => if resp.status < 200 or resp.status >= 300 {
      Err(str.join(["HTTP ", int.to_str(resp.status), " from ", path], ""))
    } else {
      match http.text_body(resp) {
        Err(e) => Err(http_err_str(e)),
        Ok(text) => Ok(text),
      }
    },
  }
}

type StateReply = { state :: Option[Str] }

# HA answers /api/states/<entity> with a JSON object whose `state` is a string.
# json.parse infers the shape from this annotation, so a missing field arrives
# as None instead of throwing -- no hand-rolled scanning, and no KeyError.
fn ha_state_field(text :: Str) -> Result[Option[Str], Str] {
  let parsed :: Result[StateReply, Str] := json.parse(text)
  match parsed {
    Err(e) => Err(e),
    Ok(reply) => Ok(reply.state),
  }
}

fn real_read_state(cfg :: Cfg, entity :: Str) -> [net] Str {
  match ha_text(cfg, "GET", str.concat("/api/states/", entity), None) {
    Err(e) => state_json(entity, "", str.concat("HA unreachable: ", e)),
    Ok(text) => match ha_state_field(text) {
      Err(e) => state_json(entity, "", str.concat("HA sent unreadable JSON: ", e)),
      Ok(field) => match field {
        None => state_json(entity, "", str.concat("HA @ ", cfg.url)),
        Some(st) => state_json(entity, st, str.concat("HA @ ", cfg.url)),
      },
    },
  }
}

fn real_read_tariff(cfg :: Cfg, at :: Str) -> [net] Str {
  if str.is_empty(cfg.tariff_entity) {
    error_json("no LEX_HA_TARIFF_ENTITY configured — real-mode tariff needs a price sensor (e.g. PVPC/Nordpool)")
  } else {
    if not str.is_empty(at) {
      error_json("future-tariff lookup not implemented in real mode — needs the sensor's forecast attributes; only 'now' is read")
    } else {
      match ha_text(cfg, "GET", str.concat("/api/states/", cfg.tariff_entity), None) {
        Err(e) => error_json(str.concat("tariff sensor unreadable: ", e)),
        Ok(text) => match ha_state_field(text) {
          Err(e) => error_json(str.concat("tariff sensor unreadable: ", e)),
          Ok(field) => match field {
            None => error_json("tariff sensor unreadable: no state field"),
            Some(raw) => match str.to_float(raw) {
              None => error_json(str.join(["tariff sensor unreadable: state '", raw, "' is not a number"], "")),
              Some(eur) => tariff_json(eur_to_cents(eur), "live", "now"),
            },
          },
        },
      }
    }
  }
}

fn real_call_service(cfg :: Cfg, service :: Str, entity :: Str, verb :: Str) -> [net] Str {
  match split_service(service) {
    (domain, name) => {
      let path := str.join(["/api/services/", domain, "/", name], "")
      let body := bytes.from_str(str.join(["{", jstr("entity_id", entity), "}"], ""))
      match ha_text(cfg, "POST", path, Some(body)) {
        Err(e) => outcome_json("stalled", str.join(["HA service ", service, " failed: ", e], "")),
        Ok(_) => outcome_json("reached", str.join([entity, " ", verb, " via ", service], "")),
      }
    },
  }
}

# ── Skill dispatch ────────────────────────────────────────────────────────────
type SkillArgs = { entity :: Option[Str], at :: Option[Str] }

# None means the caller sent something that isn't JSON -- a 400, not empty
# arguments. Swallowing it would answer a malformed request with a confident
# reading of an entity nobody named.
#
# An EMPTY body is not malformed: sidecar_lib reads `b"{}"` when Content-Length
# is 0, so a bodyless POST is an empty argument object in both.
fn parse_args(body :: Str) -> Option[SkillArgs] {
  let text := if str.is_empty(str.trim(body)) {
    "{}"
  } else {
    body
  }
  let parsed :: Result[SkillArgs, Str] := json.parse(text)
  match parsed {
    Ok(a) => Some(a),
    Err(_) => None,
  }
}

fn arg_or_empty(o :: Option[Str]) -> Str {
  match o {
    Some(s) => s,
    None => "",
  }
}

fn handle_skill(db :: Db, cfg :: Cfg, name :: Str, args :: SkillArgs) -> [net, sql] Str {
  let entity := arg_or_empty(args.entity)
  let at := arg_or_empty(args.at)
  if name == "read_state" {
    if cfg.real {
      real_read_state(cfg, entity)
    } else {
      stub_read_state(db, entity)
    }
  } else {
    if name == "read_tariff" {
      if cfg.real {
        real_read_tariff(cfg, at)
      } else {
        stub_read_tariff(at, cfg.stub_now)
      }
    } else {
      if name == "appliance_start" {
        if str.is_empty(entity) {
          outcome_json("stalled", "appliance_start needs an entity")
        } else {
          if cfg.real {
            real_call_service(cfg, cfg.start_service, entity, "started")
          } else {
            stub_set(db, entity, true, "started")
          }
        }
      } else {
        if name == "appliance_stop" {
          if str.is_empty(entity) {
            outcome_json("stalled", "appliance_stop needs an entity")
          } else {
            if cfg.real {
              real_call_service(cfg, cfg.stop_service, entity, "stopped")
            } else {
              stub_set(db, entity, false, "stopped")
            }
          }
        } else {
          error_json(str.concat("unknown skill: ", name))
        }
      }
    }
  }
}

# ── HTTP ──────────────────────────────────────────────────────────────────────
# Same routes sidecar_lib.serve exposes: GET /health, POST /skill/<name>, and
# an honest 404 for everything else.
fn json_headers() -> Map[Str, Str] {
  map.from_list([("content-type", "application/json")])
}

fn reply(status :: Int, body :: Str) -> Response {
  { status: status, body: BodyStr(body), headers: json_headers() }
}

fn health_json(cfg :: Cfg) -> Str {
  let mode := if cfg.real {
    "home-assistant"
  } else {
    "stub house"
  }
  str.join(["{\"ok\":true,\"ha\":", if cfg.real {
    "true"
  } else {
    "false"
  }, ",", jstr("mode", mode), "}"], "")
}

fn skill_name(path :: Str) -> Option[Str] {
  str.strip_prefix(path, "/skill/")
}

fn strip_query(path :: Str) -> Str
  examples {
    strip_query("/health") => "/health",
    strip_query("/health?x=1") => "/health",
    strip_query("") => ""
  }
{
  match list.head(str.split(path, "?")) {
    Some(p) => p,
    None => path,
  }
}

# Lex's Request carries path and query separately, so `req.path` is already
# query-free on both verbs.
#
# Writing this port is what surfaced that sidecar_lib's do_POST kept the query
# while do_GET stripped it: POST /skill/read_tariff?x=1 resolved to a skill
# literally named "read_tariff?x=1". depot_sidecar's /v1/chargers/<id>/start
# route had the same latent break. Fixed there rather than reproduced here --
# writing deliberately-wrong Lex to stay bug-compatible is not what "drop-in"
# should mean, and scripts/ha_parity.py now pins the two together.
fn handle(db :: Db, cfg :: Cfg, req :: Request) -> [net, sql] Response {
  if req.method == "GET" and strip_query(req.path) == "/health" {
    reply(200, health_json(cfg))
  } else {
    if req.method == "POST" {
      match skill_name(req.path) {
        Some(name) => match parse_args(req.body) {
          None => reply(400, error_json("invalid json")),
          Some(args) => reply(200, handle_skill(db, cfg, name, args)),
        },
        None => reply(404, error_json("not found")),
      }
    } else {
      reply(404, error_json("not found"))
    }
  }
}

fn load_cfg() -> [env] Cfg {
  let url := cfg_url()
  let token := cfg_token()
  { url: url, token: token, start_service: cfg_start_service(), stop_service: cfg_stop_service(), tariff_entity: cfg_tariff_entity(), stub_now: cfg_stub_now(), real: use_ha(url, token) }
}

# fs_write is here and nowhere else: sql.open creates the stub house's DB file.
# The request handler below does not carry it -- a skill call cannot write to
# the filesystem, only to the two rows this file seeded.
fn run() -> [env, io, net, sql, fs_write] Unit {
  let cfg := load_cfg()
  let port := cfg_port()
  let mode := if cfg.real {
    str.concat("HOME ASSISTANT @ ", cfg.url)
  } else {
    "stub house (no HA)"
  }
  let __lex_discard_6 := io.print(str.join(["lex-robot HA sidecar [", mode, "] on http://127.0.0.1:", int.to_str(port), "  (Ctrl-C to stop)"], ""))
  match sql.open(stub_db_path(port)) {
    Err(e) => io.print(str.concat("[ha] db error: ", e.message)),
    Ok(db) => {
      let __lex_discard_7 := init_stub(db)
      net.serve_fn(port, fn (req :: Request) -> [net, sql] Response {
        handle(db, cfg, req)
      })
    },
  }
}

