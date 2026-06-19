# sidecar/sim_sidecar.lex — Lex-native drop-in for sim_sidecar.py.
#
# Same env vars, same HTTP API.  No Python, no threads — pure Lex.
#
# Role selection:
#   LEX_STALL_NAME=""             → dashboard sidecar (SSE hub, human
#                                   escalation, /add-customer)
#   LEX_STALL_NAME=pottery|clay|… → stall sidecar (skills, A2A cards,
#                                   stock)
#
# Other env vars:
#   LEX_ROBOT_SIDECAR_PORT  (default 8900)
#   LEX_DASHBOARD_HTML      (default bazaar_web.html)
#   LEX_DASHBOARD_URL       (default http://localhost:8900)
#   LEX_ROBOT_REPO_ROOT     (default ".")
#
# Run:
#   lex run \
#     --allow-effects concurrent,crypto,env,fs_read,fs_write,io,net,proc,random,sql,time \
#     --allow-fs-read /tmp,examples \
#     --allow-fs-write /tmp \
#     --allow-proc sh \
#     sidecar/sim_sidecar.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "std.map" as map

import "std.time" as time

import "std.bytes" as bytes

import "std.http" as http

import "std.net" as net

import "std.proc" as proc

import "std.conc" as conc

import "std.iter" as iter

import "lex-schema/json_value" as jv

import "../src/seller_llm" as sllm

import "../src/lex_games" as game

import "../src/a2a_card" as card

import "lex-web/src/router" as router

import "lex-web/src/ctx" as ctx

import "lex-web/src/response" as resp

import "lex-web/src/stream" as stream

# ── Config ────────────────────────────────────────────────────────────────────

fn cfg_port() -> [env] Int {
  match env.get("LEX_ROBOT_SIDECAR_PORT") {
    None => 8900,
    Some(v) => match str.to_int(v) { Some(n) => n, None => 8900 },
  }
}

fn cfg_stall() -> [env] Str {
  match env.get("LEX_STALL_NAME") { None => "", Some(v) => v }
}

fn cfg_dash_url() -> [env] Str {
  match env.get("LEX_DASHBOARD_URL") {
    None => "http://localhost:8900",
    Some(v) => if str.is_empty(v) { "http://localhost:8900" } else { v },
  }
}

fn cfg_html() -> [env] Str {
  match env.get("LEX_DASHBOARD_HTML") {
    None => "bazaar_web.html",
    Some(v) => if str.is_empty(v) { "bazaar_web.html" } else { v },
  }
}

fn cfg_repo_root() -> [env] Str {
  match env.get("LEX_ROBOT_REPO_ROOT") { None => ".", Some(v) => v }
}

fn db_path(port :: Int) -> Str {
  str.concat("/tmp/lex-sidecar-", str.concat(int.to_str(port), ".db"))
}

# ── Helpers ───────────────────────────────────────────────────────────────────

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn parse_int_or(s :: Str, d :: Int) -> Int {
  match str.to_int(str.trim(s)) { Some(n) => n, None => d }
}

fn jv_str_or(j :: jv.Json, key :: Str, d :: Str) -> Str {
  match jv.get_field(j, key) { Some(JStr(s)) => s, _ => d }
}

fn jv_int_or(j :: jv.Json, key :: Str, d :: Int) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    Some(JStr(s)) => match str.to_int(s) { Some(n) => n, None => d },
    _ => d,
  }
}

fn jv_bool_or(j :: jv.Json, key :: Str, d :: Bool) -> Bool {
  match jv.get_field(j, key) { Some(JBool(b)) => b, _ => d }
}

fn jv_str_list(j :: jv.Json, key :: Str) -> List[Str] {
  match jv.get_field(j, key) {
    Some(JList(items)) => list.fold(items, [], fn (acc :: List[Str], item :: jv.Json) -> List[Str] {
      match item { JStr(s) => list.concat(acc, [s]), _ => acc }
    }),
    _ => [],
  }
}

fn json_str(s :: Str) -> Str {
  str.concat("\"", str.concat(str.replace(str.replace(s, "\\", "\\\\"), "\"", "\\\""), "\""))
}

# ── Static inventory ─────────────────────────────────────────────────────────

type StockItem = { id :: Str, name :: Str, category :: Str, price :: Int }

fn all_stalls() -> List[Str] {
  ["pottery", "clay", "textile", "fabric", "spices", "herb"]
}

fn inventory_for(stall :: Str) -> List[StockItem] {
  match stall {
    "pottery" => [{ id: "pot-001", name: "Red Ceramic Bowl",  category: "pottery", price: 8  },
                  { id: "pot-002", name: "Blue Glazed Vase",  category: "pottery", price: 12 },
                  { id: "pot-003", name: "Clay Teapot",       category: "pottery", price: 22 },
                  { id: "pot-004", name: "Earthen Bowl",      category: "pottery", price: 9  }],
    "clay"    => [{ id: "clay-001", name: "Stoneware Bowl",   category: "pottery", price: 10 },
                  { id: "clay-002", name: "Terracotta Jug",   category: "pottery", price: 7  }],
    "textile" => [{ id: "tex-001",  name: "Silk Scarf",       category: "textile", price: 15 },
                  { id: "tex-002",  name: "Linen Tablecloth", category: "textile", price: 30 }],
    "fabric"  => [{ id: "fab-001",  name: "Cotton Scarf",     category: "textile", price: 12 },
                  { id: "fab-002",  name: "Velvet Ribbon",    category: "textile", price: 8  }],
    "spices"  => [{ id: "spi-001",  name: "Saffron 10g",      category: "spices",  price: 5  },
                  { id: "spi-002",  name: "Vanilla Pods x5",  category: "spices",  price: 9  },
                  { id: "spi-003",  name: "Star Anise 50g",   category: "spices",  price: 4  }],
    "herb"    => [{ id: "herb-001", name: "Premium Saffron",  category: "spices",  price: 6  },
                  { id: "herb-002", name: "Dried Lavender",   category: "spices",  price: 3  },
                  { id: "herb-003", name: "Cardamom Pods",    category: "spices",  price: 4  }],
    _         => [],
  }
}

# ── SQL schema ────────────────────────────────────────────────────────────────

fn init_wal(db :: Db) -> [sql] Unit {
  let _ := sql.exec(db, "PRAGMA journal_mode=WAL", [])
  ()
}

fn init_schema(db :: Db, stall :: Str) -> [sql, time] Unit {
  let _ := sql.exec(db, "CREATE TABLE IF NOT EXISTS sse_events (id INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT NOT NULL, ts INTEGER NOT NULL)", [])
  let _ := sql.exec(db, "CREATE TABLE IF NOT EXISTS stock (item_id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL, price INTEGER NOT NULL, reserved INTEGER NOT NULL DEFAULT 0)", [])
  let _ := sql.exec(db, "CREATE TABLE IF NOT EXISTS a2a_cards (tier TEXT PRIMARY KEY, blob TEXT NOT NULL)", [])
  let _ := sql.exec(db, "CREATE TABLE IF NOT EXISTS human_questions (qid TEXT PRIMARY KEY, customer TEXT NOT NULL, question TEXT NOT NULL, answer TEXT, created_at INTEGER NOT NULL)", [])
  let _ := sql.exec(db, "CREATE TABLE IF NOT EXISTS demo_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)", [])
  let _ := sql.exec(db, "DELETE FROM sse_events", [])
  let _ := sql.exec(db, "DELETE FROM human_questions", [])
  let _ := seed_stock(db, stall)
  let _ := seed_demo_state(db)
  ()
}

fn seed_stock(db :: Db, stall :: Str) -> [sql, time] Unit {
  let items := inventory_for(stall)
  list.fold(items, (), fn (_ :: Unit, item :: StockItem) -> [sql, time] Unit {
    let q := str.join(["INSERT OR IGNORE INTO stock (item_id, name, category, price, reserved) VALUES ('", sq(item.id), "','", sq(item.name), "','", sq(item.category), "',", int.to_str(item.price), ",0)"], "")
    let _ := sql.exec(db, q, [])
    ()
  })
}

fn seed_demo_state(db :: Db) -> [sql] Unit {
  let defaults := [
    ("station_breach_sealed", "0"),
    ("heist_cameras_disabled", "0"),
    ("heist_credentials_cracked", "0"),
    ("heist_vault_opened", "0"),
    ("trading_quantum_chips",  "{\"bid\":42,\"ask\":45,\"volume\":1000,\"last\":43}"),
    ("trading_solar_panels",   "{\"bid\":28,\"ask\":31,\"volume\":500,\"last\":29}"),
    ("trading_water_credits",  "{\"bid\":7,\"ask\":8,\"volume\":2000,\"last\":7}"),
    ("disaster_zone_alpha",    "{\"casualties\":12,\"severity\":\"critical\",\"accessible\":true,\"surveyed\":false}"),
    ("disaster_zone_beta",     "{\"casualties\":3,\"severity\":\"moderate\",\"accessible\":true,\"surveyed\":false}"),
    ("disaster_zone_gamma",    "{\"casualties\":7,\"severity\":\"high\",\"accessible\":false,\"surveyed\":false}"),
    ("disaster_hospital_hq",   "{\"units_available\":8,\"helicopters\":2}"),
    ("ko_step", "0"),
    ("qr_payload", ""),
  ]
  list.fold(defaults, (), fn (_ :: Unit, kv :: (Str, Str)) -> [sql] Unit {
    match kv {
      (k, v) => {
        let q := str.join(["INSERT OR IGNORE INTO demo_state (key, value) VALUES ('", sq(k), "','", sq(v), "')"], "")
        let _ := sql.exec(db, q, [])
        ()
      },
    }
  })
}

# ── SSE ──────────────────────────────────────────────────────────────────────

fn insert_event(db :: Db, data :: Str) -> [sql, time] Unit {
  let now := time.now_ms()
  let q := str.join(["INSERT INTO sse_events (data, ts) VALUES ('", sq(data), "',", int.to_str(now), ")"], "")
  let _ := sql.exec(db, q, [])
  ()
}

fn query_events_since(db :: Db, last_id :: Int) -> [sql] Result[List[{ id :: Int, data :: Str }], Str] {
  let q := str.join(["SELECT id, data FROM sse_events WHERE id > ", int.to_str(last_id), " ORDER BY id LIMIT 50"], "")
  let result :: Result[List[{ id :: Int, data :: Str }], SqlError] := sql.query(db, q, [])
  match result {
    Err(e) => Err(e.message),
    Ok(rows) => Ok(rows),
  }
}

fn poll_events(db :: Db, last_id :: Int, timeout_ms :: Int) -> [sql, time] List[Str] {
  match query_events_since(db, last_id) {
    Err(_) => [": keepalive\n\n"],
    Ok(rows) => if list.len(rows) > 0 {
      list.map(rows, fn (row :: { id :: Int, data :: Str }) -> Str {
        str.join(["id: ", int.to_str(row.id), "\ndata: ", row.data, "\n\n"], "")
      })
    } else {
      if timeout_ms <= 0 {
        [": keepalive\n\n"]
      } else {
        let _ := time.sleep_ms(200)
        poll_events(db, last_id, timeout_ms - 200)
      }
    },
  }
}

# ── A2A cards ─────────────────────────────────────────────────────────────────

fn get_card(db :: Db, tier :: Str) -> [sql] Option[Str] {
  let q := str.join(["SELECT blob FROM a2a_cards WHERE tier='", sq(tier), "'"], "")
  let result :: Result[List[{ blob :: Str }], SqlError] := sql.query(db, q, [])
  match result {
    Err(_) => None,
    Ok(rows) => match list.head(rows) { None => None, Some(r) => Some(r.blob) },
  }
}

fn set_card(db :: Db, tier :: Str, blob :: Str) -> [sql] Unit {
  let q := str.join(["INSERT OR REPLACE INTO a2a_cards (tier, blob) VALUES ('", sq(tier), "','", sq(blob), "')"], "")
  let _ := sql.exec(db, q, [])
  ()
}

# ── Stock ─────────────────────────────────────────────────────────────────────

fn stock_query(db :: Db, search :: Str, max_price :: Int, stall :: Str) -> [sql] Str {
  let q := str.join(["SELECT item_id, name, category, price FROM stock WHERE reserved=0 AND price<=", int.to_str(max_price), " ORDER BY price ASC"], "")
  let result :: Result[List[{ item_id :: Str, name :: Str, category :: Str, price :: Int }], SqlError] := sql.query(db, q, [])
  match result {
    Err(e) => str.join(["{\"stall\":", json_str(stall), ",\"found\":0,\"error\":", json_str(e.message), "}"], ""),
    Ok(rows) => {
      let candidates := if str.is_empty(search) {
        rows
      } else {
        let sl := str.to_lower(search)
        list.filter(rows, fn (r :: { item_id :: Str, name :: Str, category :: Str, price :: Int }) -> Bool {
          str.contains(str.to_lower(r.name), sl)
        })
      }
      let n := list.len(candidates)
      if n == 0 {
        str.join(["{\"stall\":", json_str(stall), ",\"found\":0}"], "")
      } else {
        let items_json := list.fold(candidates, [], fn (acc :: List[Str], r :: { item_id :: Str, name :: Str, category :: Str, price :: Int }) -> List[Str] {
          list.concat(acc, [str.join(["{\"id\":", json_str(r.item_id), ",\"name\":", json_str(r.name), ",\"category\":", json_str(r.category), ",\"price\":", int.to_str(r.price), "}"], "")])
        })
        str.join(["{\"stall\":", json_str(stall), ",\"found\":", int.to_str(n), ",\"items\":[", str.join(items_json, ","), "]}"], "")
      }
    },
  }
}

fn stock_reserve(db :: Db, item_id :: Str) -> [sql] Str {
  let check_q := str.join(["SELECT price, reserved FROM stock WHERE item_id='", sq(item_id), "'"], "")
  let result :: Result[List[{ price :: Int, reserved :: Int }], SqlError] := sql.query(db, check_q, [])
  match result {
    Err(_) => "{\"status\":\"not_found\"}",
    Ok(rows) => match list.head(rows) {
      None => "{\"status\":\"not_found\"}",
      Some(row) => if row.reserved == 1 {
        "{\"status\":\"already_reserved\"}"
      } else {
        let upd := str.join(["UPDATE stock SET reserved=1 WHERE item_id='", sq(item_id), "'"], "")
        let _ := sql.exec(db, upd, [])
        "{\"status\":\"reserved\"}"
      },
    },
  }
}

fn stock_complete(db :: Db, item_id :: Str, payment :: Int) -> [sql] Str {
  let check_q := str.join(["SELECT price, reserved FROM stock WHERE item_id='", sq(item_id), "'"], "")
  let result :: Result[List[{ price :: Int, reserved :: Int }], SqlError] := sql.query(db, check_q, [])
  match result {
    Err(_) => "{\"status\":\"not_reserved\"}",
    Ok(rows) => match list.head(rows) {
      None => "{\"status\":\"not_reserved\"}",
      Some(row) => if row.reserved == 0 {
        "{\"status\":\"not_reserved\"}"
      } else {
        if payment < row.price {
          str.join(["{\"status\":\"insufficient\",\"required\":", int.to_str(row.price), "}"], "")
        } else {
          let del := str.join(["DELETE FROM stock WHERE item_id='", sq(item_id), "'"], "")
          let _ := sql.exec(db, del, [])
          str.join(["{\"status\":\"sold\",\"change\":", int.to_str(payment - row.price), "}"], "")
        }
      },
    },
  }
}

fn stock_reset(db :: Db, stall :: Str) -> [sql, time] Unit {
  let _ := sql.exec(db, "DELETE FROM stock", [])
  seed_stock(db, stall)
}

# ── Tic-tac-toe (lex-games) — capability-gated, verifiable, agent-playable ────
fn ttt_cell(b :: Str, i :: Int) -> Str { str.slice(b, i, i + 1) }
fn ttt_set(b :: Str, i :: Int, c :: Str) -> Str { str.concat(str.slice(b, 0, i), str.concat(c, str.slice(b, i + 1, 9))) }
fn ttt_line(b :: Str, a :: Int, c :: Int, d :: Int) -> Str {
  let x := ttt_cell(b, a)
  if x != "." and ttt_cell(b, c) == x and ttt_cell(b, d) == x { x } else { "" }
}
fn ttt_winner(b :: Str) -> Str {
  list.fold([ttt_line(b,0,1,2), ttt_line(b,3,4,5), ttt_line(b,6,7,8), ttt_line(b,0,3,6), ttt_line(b,1,4,7), ttt_line(b,2,5,8), ttt_line(b,0,4,8), ttt_line(b,2,4,6)], "", fn (acc :: Str, w :: Str) -> Str { if str.is_empty(acc) { w } else { acc } })
}
fn ttt_board(db :: Db) -> [sql] Str { let b := get_state(db, "ttt_board") b2(b) }
fn b2(b :: Str) -> Str { if str.is_empty(b) { "........." } else { b } }
fn ttt_turn(db :: Db) -> [sql] Str { let t := get_state(db, "ttt_turn") t2(t) }
fn t2(t :: Str) -> Str { if str.is_empty(t) { "X" } else { t } }
# Hash-chained move log: chain_n = base64url(blake2b(prev_chain ++ payload)).
fn ttt_chain(db :: Db, payload :: Str) -> [sql, crypto] Str {
  let prev := get_state(db, "ttt_chain")
  let h := crypto.base64url_encode(crypto.blake2b(bytes.from_str(str.concat(prev, payload))))
  let head := str.slice(h, 0, 10)
  let _ := set_state(db, "ttt_chain", head)
  head
}
fn ttt_emit(db :: Db, j :: Str) -> [sql, time] Unit { insert_event(db, j) }

# Apply one move, hash-chain it, broadcast it; returns the new board.
fn ttt_apply(db :: Db, board :: Str, by :: Str, cl :: Int) -> [sql, time, crypto] Str {
  let nb := ttt_set(board, cl, by)
  let payload := str.join(["{\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"board\":\"", nb, "\"}"], "")
  let head := ttt_chain(db, payload)
  let _ := ttt_emit(db, str.join(["{\"kind\":\"move\",\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"board\":\"", nb, "\",\"chain\":\"", head, "\"}"], ""))
  nb
}

fn ttt_reset(db :: Db) -> [sql, time] Str {
  let _ := set_state(db, "ttt_board", ".........")
  let _ := set_state(db, "ttt_turn", "X")
  let _ := set_state(db, "ttt_over", "0")
  let _ := set_state(db, "ttt_chain", "")
  # NOTE: ttt_taken_* are NOT cleared — side assignments persist for the session,
  # so a player can't grab the opponent's side by resetting. A fresh server (new
  # /tmp db) is a fresh table assignment.
  let _ := ttt_emit(db, "{\"kind\":\"game_start\",\"board\":\".........\",\"x\":\"human\",\"o\":\"bot\"}")
  "{\"status\":\"reset\"}"
}

# A move's capability is an Ed25519-signed token issued at join (see ttt_join).
# The server verifies it and recovers the side; a forged/edited token yields no
# side, so the gate refuses. Sides are assigned at join (first X, then O), so a
# player cannot self-grant the opponent's side either.
fn ttt_secret() -> Bytes { bytes.from_str("lexgames-ttt-secret-seed-0000000") }
fn ttt_pubkey() -> [crypto] Str {
  match crypto.ed25519_public_key(ttt_secret()) { Ok(pk) => crypto.base64url_encode(pk), Err(_) => "" }
}

# Join a side: assign it (if free) and return a signed capability token.
fn ttt_join(db :: Db, side :: Str) -> [sql, crypto, time] Str {
  if side != "X" and side != "O" { "{\"error\":\"bad side\"}" } else {
    let key := str.concat("ttt_taken_", side)
    if get_state(db, key) == "1" {
      str.join(["{\"error\":\"side taken\",\"side\":\"", side, "\"}"], "")
    } else {
      let _ := set_state(db, key, "1")
      let _ := ttt_emit(db, str.join(["{\"kind\":\"joined\",\"side\":\"", side, "\"}"], ""))
      str.join(["{\"side\":\"", side, "\",\"token\":\"", game.issue_token(ttt_secret(), side), "\"}"], "")
    }
  }
}

# A single gated move by either side. The submitter's TOKEN determines which side
# it may act as; game.gate refuses a move that claims a side the token doesn't
# grant, or that is out of turn — before any board change. No in-server bot: each
# side is played by an independent agent (the human for X, ttt_bot.lex for O).
fn ttt_move(db :: Db, by :: Str, cl :: Int, token :: Str) -> [sql, time, crypto] Str {
  let board := ttt_board(db)
  let turn  := ttt_turn(db)
  if get_state(db, "ttt_over") == "1" { "{\"status\":\"over\"}" } else {
    match game.gate(game.token_side(ttt_pubkey(), token), by, turn) {
      MoveReject(why) => {
        let _ := ttt_emit(db, str.join(["{\"kind\":\"refused\",\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"reason\":\"", why, "\"}"], ""))
        str.join(["{\"status\":\"refused\",\"reason\":\"", why, "\"}"], "")
      },
      MoveOk => if cl < 0 or cl > 8 or ttt_cell(board, cl) != "." {
        let _ := ttt_emit(db, str.join(["{\"kind\":\"refused\",\"by\":\"", by, "\",\"cell\":", int.to_str(cl), ",\"reason\":\"cell not playable\"}"], ""))
        "{\"status\":\"refused\",\"reason\":\"cell not playable\"}"
      } else {
        let nb := ttt_apply(db, board, by, cl)
        let _ := set_state(db, "ttt_board", nb)
        let w := ttt_winner(nb)
        if not str.is_empty(w) {
          let _ := ttt_emit(db, str.join(["{\"kind\":\"win\",\"winner\":\"", w, "\",\"board\":\"", nb, "\"}"], ""))
          let _ := set_state(db, "ttt_over", "1")
          str.join(["{\"status\":\"win\",\"winner\":\"", w, "\"}"], "")
        } else {
          if str.contains(nb, ".") {
            let _ := set_state(db, "ttt_turn", if by == "X" { "O" } else { "X" })
            str.join(["{\"status\":\"ok\",\"board\":\"", nb, "\"}"], "")
          } else {
            let _ := ttt_emit(db, str.join(["{\"kind\":\"win\",\"winner\":\"draw\",\"board\":\"", nb, "\"}"], ""))
            let _ := set_state(db, "ttt_over", "1")
            "{\"status\":\"draw\"}"
          }
        }
      },
    }
  }
}

# Read-only game state (for an agent to observe before moving).
fn ttt_state(db :: Db) -> [sql] Str {
  str.join(["{\"board\":\"", ttt_board(db), "\",\"turn\":\"", ttt_turn(db), "\",\"over\":", (if get_state(db, "ttt_over") == "1" { "true" } else { "false" }), "}"], "")
}

# ── Bazaar Draft (lex-games): turn-based competitive shopping ─────────────────
# Two shoppers (P1 human, P2 bot) alternate drafting from a shared 6-item pool
# under a budget. A pick is gated by a signed capability (you draft only as
# yourself, in turn) and hash-chained. Highest total cart value wins.
fn shop_price(i :: Int) -> Int { if i == 0 { 8 } else { if i == 1 { 12 } else { if i == 2 { 15 } else { if i == 3 { 5 } else { if i == 4 { 22 } else { if i == 5 { 7 } else { 999 } } } } } } }
fn shop_value(i :: Int) -> Int { if i == 0 { 10 } else { if i == 1 { 14 } else { if i == 2 { 16 } else { if i == 3 { 6 } else { if i == 4 { 25 } else { if i == 5 { 8 } else { 0 } } } } } } }
fn shop_name(i :: Int)  -> Str { if i == 0 { "Bowl" } else { if i == 1 { "Vase" } else { if i == 2 { "Scarf" } else { if i == 3 { "Saffron" } else { if i == 4 { "Teapot" } else { if i == 5 { "Ribbon" } else { "?" } } } } } } }

fn shop_secret() -> Bytes { bytes.from_str("lexgames-shop-secret-seed-000000") }
fn shop_pubkey() -> [crypto] Str { match crypto.ed25519_public_key(shop_secret()) { Ok(pk) => crypto.base64url_encode(pk), Err(_) => "" } }

fn shop_owner(db :: Db, i :: Int) -> [sql] Str { get_state(db, str.concat("shop_own_", int.to_str(i))) }
fn shop_turn(db :: Db) -> [sql] Str {
  let t := get_state(db, "shop_turn")
  if str.is_empty(t) { "P1" } else { t }
}
fn shop_budget(db :: Db, p :: Str) -> [sql] Int {
  let v := get_state(db, str.concat("shop_bud_", p))
  match str.to_int(v) { Some(n) => n, None => 30 }
}
fn shop_cartval(db :: Db, p :: Str) -> [sql] Int {
  list.fold([0,1,2,3,4,5], 0, fn (acc :: Int, i :: Int) -> [sql] Int { if shop_owner(db, i) == p { acc + shop_value(i) } else { acc } })
}
# Can player p still afford any available item?
fn shop_can_move(db :: Db, p :: Str) -> [sql] Bool {
  let bud := shop_budget(db, p)
  list.fold([0,1,2,3,4,5], false, fn (acc :: Bool, i :: Int) -> [sql] Bool { if acc { acc } else { shop_owner(db, i) == "" and shop_price(i) <= bud } })
}
# Pool as JSON (for the client + the bot).
fn shop_pool_json(db :: Db) -> [sql] Str {
  let items := list.map([0,1,2,3,4,5], fn (i :: Int) -> [sql] Str {
    str.join(["{\"i\":", int.to_str(i), ",\"name\":\"", shop_name(i), "\",\"price\":", int.to_str(shop_price(i)), ",\"value\":", int.to_str(shop_value(i)), ",\"owner\":\"", shop_owner(db, i), "\"}"], "")
  })
  str.join(["[", str.join(items, ","), "]"], "")
}
fn shop_state(db :: Db) -> [sql] Str {
  str.join(["{\"pool\":", shop_pool_json(db), ",\"turn\":\"", shop_turn(db), "\",\"over\":", (if get_state(db, "shop_over") == "1" { "true" } else { "false" }), ",\"bud\":{\"P1\":", int.to_str(shop_budget(db, "P1")), ",\"P2\":", int.to_str(shop_budget(db, "P2")), "},\"val\":{\"P1\":", int.to_str(shop_cartval(db, "P1")), ",\"P2\":", int.to_str(shop_cartval(db, "P2")), "}}"], "")
}
fn shop_reset(db :: Db) -> [sql, time] Str {
  let _ := list.fold([0,1,2,3,4,5], (), fn (_ :: Unit, i :: Int) -> [sql] Unit { set_state(db, str.concat("shop_own_", int.to_str(i)), "") })
  let _ := set_state(db, "shop_bud_P1", "30")
  let _ := set_state(db, "shop_bud_P2", "30")
  let _ := set_state(db, "shop_turn", "P1")
  let _ := set_state(db, "shop_over", "0")
  let _ := set_state(db, "shop_chain", "")
  let _ := insert_event(db, "{\"kind\":\"shop_start\",\"budget\":30}")
  "{\"status\":\"reset\"}"
}
fn shop_join(db :: Db, side :: Str) -> [sql, crypto, time] Str {
  if side != "P1" and side != "P2" { "{\"error\":\"bad side\"}" } else {
    let key := str.concat("shop_taken_", side)
    if get_state(db, key) == "1" { str.join(["{\"error\":\"side taken\",\"side\":\"", side, "\"}"], "") } else {
      let _ := set_state(db, key, "1")
      let _ := insert_event(db, str.join(["{\"kind\":\"shop_joined\",\"side\":\"", side, "\"}"], ""))
      str.join(["{\"side\":\"", side, "\",\"token\":\"", game.issue_token(shop_secret(), side), "\"}"], "")
    }
  }
}
fn shop_finish(db :: Db) -> [sql, time] Str {
  let v1 := shop_cartval(db, "P1")
  let v2 := shop_cartval(db, "P2")
  let w := if v1 > v2 { "P1" } else { if v2 > v1 { "P2" } else { "draw" } }
  let _ := set_state(db, "shop_over", "1")
  let _ := insert_event(db, str.join(["{\"kind\":\"shop_win\",\"winner\":\"", w, "\",\"p1\":", int.to_str(v1), ",\"p2\":", int.to_str(v2), "}"], ""))
  str.join(["{\"status\":\"over\",\"winner\":\"", w, "\"}"], "")
}
fn shop_move(db :: Db, by :: Str, i :: Int, token :: Str) -> [sql, time, crypto] Str {
  if get_state(db, "shop_over") == "1" { "{\"status\":\"over\"}" } else {
    let turn := shop_turn(db)
    match game.gate(game.token_side(shop_pubkey(), token), by, turn) {
      MoveReject(why) => {
        let _ := insert_event(db, str.join(["{\"kind\":\"shop_refused\",\"by\":\"", by, "\",\"item\":", int.to_str(i), ",\"reason\":\"", why, "\"}"], ""))
        str.join(["{\"status\":\"refused\",\"reason\":\"", why, "\"}"], "")
      },
      MoveOk => if i < 0 or i > 5 or shop_owner(db, i) != "" or shop_price(i) > shop_budget(db, by) {
        let _ := insert_event(db, str.join(["{\"kind\":\"shop_refused\",\"by\":\"", by, "\",\"item\":", int.to_str(i), ",\"reason\":\"unavailable or unaffordable\"}"], ""))
        "{\"status\":\"refused\",\"reason\":\"unavailable or unaffordable\"}"
      } else {
        let _ := set_state(db, str.concat("shop_own_", int.to_str(i)), by)
        let _ := set_state(db, str.concat("shop_bud_", by), int.to_str(shop_budget(db, by) - shop_price(i)))
        let payload := str.join(["{\"by\":\"", by, "\",\"item\":", int.to_str(i), ",\"name\":\"", shop_name(i), "\",\"price\":", int.to_str(shop_price(i)), "}"], "")
        let prev := get_state(db, "shop_chain")
        let head := str.slice(crypto.base64url_encode(crypto.blake2b(bytes.from_str(str.concat(prev, payload)))), 0, 10)
        let _ := set_state(db, "shop_chain", head)
        let _ := insert_event(db, str.join(["{\"kind\":\"shop_pick\",\"by\":\"", by, "\",\"item\":", int.to_str(i), ",\"name\":\"", shop_name(i), "\",\"price\":", int.to_str(shop_price(i)), ",\"value\":", int.to_str(shop_value(i)), ",\"chain\":\"", head, "\"}"], ""))
        let _ := set_state(db, "shop_turn", if by == "P1" { "P2" } else { "P1" })
        if shop_can_move(db, "P1") or shop_can_move(db, "P2") {
          str.join(["{\"status\":\"ok\",\"item\":", int.to_str(i), "}"], "")
        } else {
          shop_finish(db)
        }
      },
    }
  }
}
fn shop_dispatch(db :: Db, name :: Str, args :: jv.Json) -> [sql, time, crypto] Str {
  if name == "shop_join" { shop_join(db, jv_str_or(args, "side", "")) } else {
  if name == "shop_reset" { shop_reset(db) } else {
  if name == "shop_move" { shop_move(db, jv_str_or(args, "by", ""), jv_int_or(args, "item", -1), jv_str_or(args, "token", "")) } else {
  shop_state(db) }}}
}

# ── lex-games: Consent Match — matchmaking as a capability-gated draft ─────────
# A shared deck of candidates, each with a PUBLIC profile (name + what vibe they
# seek) and a PRIVATE card (contact, Ed25519-signed). Both players are creatives
# (they offer art & music). On your turn you swipe right on one candidate: if the
# candidate seeks what you offer it is a MATCH (double opt-in) and the signed
# private card is revealed (selective disclosure); otherwise the swipe is rejected
# and the private card stays sealed. Candidates seeking hiking/gaming match no one
# (decoys that burn a turn). Each swipe is capability-gated by a signed token and
# hash-chained. When the deck is exhausted, the highest matched charm wins.
fn love_name(i :: Int)  -> Str { if i == 0 { "Robin" } else { if i == 1 { "Sky" } else { if i == 2 { "Wren" } else { if i == 3 { "Sage" } else { if i == 4 { "Nova" } else { if i == 5 { "Pax" } else { "?" } } } } } } }
fn love_seeks(i :: Int) -> Str { if i == 0 { "art" } else { if i == 1 { "music" } else { if i == 2 { "gaming" } else { if i == 3 { "art" } else { if i == 4 { "music" } else { if i == 5 { "hiking" } else { "?" } } } } } } }
fn love_charm(i :: Int) -> Int { if i == 0 { 10 } else { if i == 1 { 14 } else { if i == 2 { 0 } else { if i == 3 { 16 } else { if i == 4 { 8 } else { if i == 5 { 0 } else { 0 } } } } } } }
fn love_contact(i :: Int) -> Str { if i == 0 { "robin@six.net" } else { if i == 1 { "sky@six.net" } else { if i == 2 { "wren@six.net" } else { if i == 3 { "sage@six.net" } else { if i == 4 { "nova@six.net" } else { if i == 5 { "pax@six.net" } else { "?" } } } } } } }
# Both players offer art & music; a candidate reciprocates iff it seeks one of those.
fn love_recip(i :: Int) -> Bool { love_seeks(i) == "art" or love_seeks(i) == "music" }

fn love_secret() -> Bytes { bytes.from_str("lexgames-love-secret-seed-000000") }
fn love_pubkey() -> [crypto] Str { match crypto.ed25519_public_key(love_secret()) { Ok(pk) => crypto.base64url_encode(pk), Err(_) => "" } }
# Ed25519 signature over a candidate's private contact (revealed only on match).
fn love_sign(i :: Int) -> [crypto] Str {
  match crypto.ed25519_sign(love_secret(), bytes.from_str(love_contact(i))) {
    Ok(sig) => str.slice(crypto.base64url_encode(sig), 0, 12),
    Err(_)  => "",
  }
}

fn love_owner(db :: Db, i :: Int)  -> [sql] Str { get_state(db, str.concat("love_own_", int.to_str(i))) }
fn love_result(db :: Db, i :: Int) -> [sql] Str { get_state(db, str.concat("love_res_", int.to_str(i))) }
fn love_turn(db :: Db) -> [sql] Str {
  let t := get_state(db, "love_turn")
  if str.is_empty(t) { "P1" } else { t }
}
fn love_score(db :: Db, p :: Str) -> [sql] Int {
  list.fold([0,1,2,3,4,5], 0, fn (acc :: Int, i :: Int) -> [sql] Int { if love_owner(db, i) == p and love_result(db, i) == "match" { acc + love_charm(i) } else { acc } })
}
# Game ends when every candidate has been swiped.
fn love_done(db :: Db) -> [sql] Bool {
  list.fold([0,1,2,3,4,5], true, fn (acc :: Bool, i :: Int) -> [sql] Bool { if acc { love_owner(db, i) != "" } else { false } })
}
fn love_pool_json(db :: Db) -> [sql] Str {
  let items := list.map([0,1,2,3,4,5], fn (i :: Int) -> [sql] Str {
    str.join(["{\"i\":", int.to_str(i), ",\"name\":\"", love_name(i), "\",\"seeks\":\"", love_seeks(i), "\",\"charm\":", int.to_str(love_charm(i)), ",\"owner\":\"", love_owner(db, i), "\",\"result\":\"", love_result(db, i), "\"}"], "")
  })
  str.join(["[", str.join(items, ","), "]"], "")
}
fn love_state(db :: Db) -> [sql] Str {
  str.join(["{\"pool\":", love_pool_json(db), ",\"turn\":\"", love_turn(db), "\",\"over\":", (if get_state(db, "love_over") == "1" { "true" } else { "false" }), ",\"score\":{\"P1\":", int.to_str(love_score(db, "P1")), ",\"P2\":", int.to_str(love_score(db, "P2")), "}}"], "")
}
fn love_reset(db :: Db) -> [sql, time] Str {
  let _ := list.fold([0,1,2,3,4,5], (), fn (_ :: Unit, i :: Int) -> [sql] Unit { set_state(db, str.concat("love_own_", int.to_str(i)), "") })
  let _ := list.fold([0,1,2,3,4,5], (), fn (_ :: Unit, i :: Int) -> [sql] Unit { set_state(db, str.concat("love_res_", int.to_str(i)), "") })
  let _ := set_state(db, "love_turn", "P1")
  let _ := set_state(db, "love_over", "0")
  let _ := set_state(db, "love_chain", "")
  let _ := insert_event(db, "{\"kind\":\"love_start\"}")
  "{\"status\":\"reset\"}"
}
fn love_join(db :: Db, side :: Str) -> [sql, crypto, time] Str {
  if side != "P1" and side != "P2" { "{\"error\":\"bad side\"}" } else {
    let key := str.concat("love_taken_", side)
    if get_state(db, key) == "1" { str.join(["{\"error\":\"side taken\",\"side\":\"", side, "\"}"], "") } else {
      let _ := set_state(db, key, "1")
      let _ := insert_event(db, str.join(["{\"kind\":\"love_joined\",\"side\":\"", side, "\"}"], ""))
      str.join(["{\"side\":\"", side, "\",\"token\":\"", game.issue_token(love_secret(), side), "\"}"], "")
    }
  }
}
fn love_finish(db :: Db) -> [sql, time] Str {
  let s1 := love_score(db, "P1")
  let s2 := love_score(db, "P2")
  let w := if s1 > s2 { "P1" } else { if s2 > s1 { "P2" } else { "draw" } }
  let _ := set_state(db, "love_over", "1")
  let _ := insert_event(db, str.join(["{\"kind\":\"love_win\",\"winner\":\"", w, "\",\"p1\":", int.to_str(s1), ",\"p2\":", int.to_str(s2), "}"], ""))
  str.join(["{\"status\":\"over\",\"winner\":\"", w, "\"}"], "")
}
fn love_move(db :: Db, by :: Str, i :: Int, token :: Str) -> [sql, time, crypto] Str {
  if get_state(db, "love_over") == "1" { "{\"status\":\"over\"}" } else {
    let turn := love_turn(db)
    match game.gate(game.token_side(love_pubkey(), token), by, turn) {
      MoveReject(why) => {
        let _ := insert_event(db, str.join(["{\"kind\":\"love_refused\",\"by\":\"", by, "\",\"cand\":", int.to_str(i), ",\"reason\":\"", why, "\"}"], ""))
        str.join(["{\"status\":\"refused\",\"reason\":\"", why, "\"}"], "")
      },
      MoveOk => if i < 0 or i > 5 or love_owner(db, i) != "" {
        let _ := insert_event(db, str.join(["{\"kind\":\"love_refused\",\"by\":\"", by, "\",\"cand\":", int.to_str(i), ",\"reason\":\"already swiped\"}"], ""))
        "{\"status\":\"refused\",\"reason\":\"already swiped\"}"
      } else {
        let matched := love_recip(i)
        let _ := set_state(db, str.concat("love_own_", int.to_str(i)), by)
        let _ := set_state(db, str.concat("love_res_", int.to_str(i)), if matched { "match" } else { "rejected" })
        let payload := str.join(["{\"by\":\"", by, "\",\"cand\":", int.to_str(i), ",\"match\":", (if matched { "true" } else { "false" }), "}"], "")
        let prev := get_state(db, "love_chain")
        let head := str.slice(crypto.base64url_encode(crypto.blake2b(bytes.from_str(str.concat(prev, payload)))), 0, 10)
        let _ := set_state(db, "love_chain", head)
        let _ := if matched {
          insert_event(db, str.join(["{\"kind\":\"love_match\",\"by\":\"", by, "\",\"cand\":", int.to_str(i), ",\"name\":\"", love_name(i), "\",\"charm\":", int.to_str(love_charm(i)), ",\"contact\":\"", love_contact(i), "\",\"sig\":\"", love_sign(i), "\",\"chain\":\"", head, "\"}"], ""))
        } else {
          insert_event(db, str.join(["{\"kind\":\"love_reject\",\"by\":\"", by, "\",\"cand\":", int.to_str(i), ",\"name\":\"", love_name(i), "\",\"chain\":\"", head, "\"}"], ""))
        }
        let _ := set_state(db, "love_turn", if by == "P1" { "P2" } else { "P1" })
        if love_done(db) { love_finish(db) } else { str.join(["{\"status\":\"ok\",\"cand\":", int.to_str(i), ",\"match\":", (if matched { "true" } else { "false" }), "}"], "") }
      },
    }
  }
}
fn love_dispatch(db :: Db, name :: Str, args :: jv.Json) -> [sql, time, crypto] Str {
  if name == "love_join" { love_join(db, jv_str_or(args, "side", "")) } else {
  if name == "love_reset" { love_reset(db) } else {
  if name == "love_move" { love_move(db, jv_str_or(args, "by", ""), jv_int_or(args, "cand", -1), jv_str_or(args, "token", "")) } else {
  love_state(db) }}}
}

# A supplier delivers a new item into the stall's stock (logistics restock).
fn stock_add(db :: Db, item_id :: Str, name :: Str, category :: Str, price :: Int) -> [sql] Str {
  let q := str.join(["INSERT OR REPLACE INTO stock (item_id, name, category, price, reserved) VALUES ('", sq(item_id), "','", sq(name), "','", sq(category), "',", int.to_str(price), ",0)"], "")
  let _ := sql.exec(db, q, [])
  str.join(["{\"status\":\"restocked\",\"item_id\":\"", sq(item_id), "\",\"name\":\"", sq(name), "\",\"price\":", int.to_str(price), "}"], "")
}

fn stock_list_json(db :: Db, stall :: Str) -> [sql] Str {
  let result :: Result[List[{ item_id :: Str, name :: Str, category :: Str, price :: Int, reserved :: Int }], SqlError] := sql.query(db, "SELECT item_id, name, category, price, reserved FROM stock", [])
  match result {
    Err(_) => str.join(["{\"stall\":", json_str(stall), ",\"items\":[]}"], ""),
    Ok(rows) => {
      let items := str.join(list.map(rows, fn (r :: { item_id :: Str, name :: Str, category :: Str, price :: Int, reserved :: Int }) -> Str {
        str.join(["{\"id\":", json_str(r.item_id), ",\"name\":", json_str(r.name), ",\"category\":", json_str(r.category), ",\"price\":", int.to_str(r.price), ",\"reserved\":", if r.reserved == 1 { "true" } else { "false" }, "}"], "")
      }), ",")
      str.join(["{\"stall\":", json_str(stall), ",\"items\":[", items, "]}"], "")
    },
  }
}

# ── Demo state (key/value store) ──────────────────────────────────────────────

fn get_state(db :: Db, key :: Str) -> [sql] Str {
  let q := str.join(["SELECT value FROM demo_state WHERE key='", sq(key), "'"], "")
  let result :: Result[List[{ value :: Str }], SqlError] := sql.query(db, q, [])
  match result {
    Err(_) => "",
    Ok(rows) => match list.head(rows) { None => "", Some(r) => r.value },
  }
}

fn set_state(db :: Db, key :: Str, value :: Str) -> [sql] Unit {
  let q := str.join(["INSERT OR REPLACE INTO demo_state (key, value) VALUES ('", sq(key), "','", sq(value), "')"], "")
  let _ := sql.exec(db, q, [])
  ()
}

fn get_state_bool(db :: Db, key :: Str) -> [sql] Bool {
  get_state(db, key) == "1"
}

fn set_state_bool(db :: Db, key :: Str, v :: Bool) -> [sql] Unit {
  set_state(db, key, if v { "1" } else { "0" })
}

fn get_state_int(db :: Db, key :: Str) -> [sql] Int {
  parse_int_or(get_state(db, key), 0)
}

# ── Human escalation ──────────────────────────────────────────────────────────

fn store_question(db :: Db, qid :: Str, customer :: Str, question :: Str) -> [sql, time] Unit {
  let now := time.now_ms()
  let q := str.join(["INSERT OR REPLACE INTO human_questions (qid, customer, question, answer, created_at) VALUES ('", sq(qid), "','", sq(customer), "','", sq(question), "',NULL,", int.to_str(now), ")"], "")
  let _ := sql.exec(db, q, [])
  ()
}

fn poll_answer(db :: Db, qid :: Str, timeout_ms :: Int) -> [sql, time] Str {
  let q := str.join(["SELECT answer FROM human_questions WHERE qid='", sq(qid), "' AND answer IS NOT NULL"], "")
  let result :: Result[List[{ answer :: Str }], SqlError] := sql.query(db, q, [])
  match result {
    Err(_) => "",
    Ok(rows) => match list.head(rows) {
      Some(r) => {
        let _ := sql.exec(db, str.join(["DELETE FROM human_questions WHERE qid='", sq(qid), "'"], ""), [])
        r.answer
      },
      None => if timeout_ms <= 0 {
        ""
      } else {
        let _ := time.sleep_ms(500)
        poll_answer(db, qid, timeout_ms - 500)
      },
    },
  }
}

fn store_answer(db :: Db, qid :: Str, answer :: Str) -> [sql] Unit {
  let q := str.join(["UPDATE human_questions SET answer='", sq(answer), "' WHERE qid='", sq(qid), "'"], "")
  let _ := sql.exec(db, q, [])
  ()
}

# ── Dashboard notification ───────────────────────────────────────────────────

fn notify_dash(dash :: Str, json :: Str) -> [net] Unit {
  if str.is_empty(dash) {
    ()
  } else {
    let req0 := { method: "POST", url: str.concat(dash, "/event"), headers: map.new(), body: Some(bytes.from_str(json)), timeout_ms: None }
    let req := http.with_header(http.with_timeout_ms(req0, 1000), "Content-Type", "application/json")
    let _ := http.send(req)
    ()
  }
}

# ── Skill dispatch ────────────────────────────────────────────────────────────

fn http_err_msg(e :: HttpError) -> Str {
  match e {
    TimeoutError       => "timeout",
    TlsError(m)        => str.concat("tls: ", m),
    NetworkError(m)    => str.concat("network: ", m),
    DecodeError(m)     => str.concat("decode: ", m),
  }
}

fn stall_to_port(stall_name :: Str) -> Int {
  if stall_name == "pottery" or stall_name == "clay" { 8901 } else {
  if stall_name == "textile" or stall_name == "fabric" { 8902 } else {
  if stall_name == "spices" or stall_name == "herb" { 8903 } else {
  0 }}}
}

fn proxy_to_stall(stall_name :: Str, skill :: Str, args_json :: Str) -> [net] Str {
  let port := stall_to_port(stall_name)
  if port == 0 {
    str.join(["{\"error\":\"unknown stall: ", stall_name, "\"}"], "")
  } else {
    let url := str.join(["http://localhost:", int.to_str(port), "/skill/", skill], "")
    let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(args_json)), timeout_ms: None }
    let req := http.with_header(http.with_timeout_ms(req0, 5000), "Content-Type", "application/json")
    match http.send(req) {
      Err(e) => str.join(["{\"error\":", json_str(http_err_msg(e)), "}"], ""),
      Ok(r) => match bytes.to_str(r.body) {
        Err(_) => "{\"error\":\"bad utf8\"}",
        Ok(s) => s,
      },
    }
  }
}

# ── Stall A2A self-registration ───────────────────────────────────────────────

fn stall_secret(stall :: Str) -> Bytes {
  if stall == "pottery" or stall == "clay" {
    bytes.from_str("00000000000000000000000000000001")
  } else {
  if stall == "textile" or stall == "fabric" {
    bytes.from_str("00000000000000000000000000000002")
  } else {
  if stall == "spices" or stall == "herb" {
    bytes.from_str("00000000000000000000000000000003")
  } else {
  if stall == "robot-b" {
    bytes.from_str("0000000000000000000000000000000b")
  } else {
    bytes.from_str("00000000000000000000000000000000")
  }}}}
}

fn stall_display_name(stall :: Str) -> Str {
  if stall == "pottery" or stall == "clay" { "Pottery Palace" } else {
  if stall == "textile" or stall == "fabric" { "Textile Traders" } else {
  if stall == "spices" or stall == "herb" { "Spice Garden" } else {
  if stall == "robot-b" { "Robot B" } else {
  stall }}}}
}

# A2A skills advertised by each peer. robot-b is a service peer offering
# charge_battery; bazaar stalls offer the stock/reserve/sale skills.
fn stall_pub_skills(stall :: Str) -> List[card.AgentSkill] {
  if stall == "robot-b" {
    [{ name: "charge_battery", description: "Sell battery charge units to a peer robot" }]
  } else {
    [{ name: "query_stock", description: "Search available stock" }]
  }
}

fn stall_ext_skills(stall :: Str) -> List[card.AgentSkill] {
  if stall == "robot-b" {
    [{ name: "charge_battery", description: "Sell battery charge units to a peer robot" }]
  } else {
    [
      { name: "query_stock",   description: "Search available stock" },
      { name: "reserve_item",  description: "Reserve an item for purchase" },
      { name: "complete_sale", description: "Finalise sale and transfer item" },
      { name: "restock",       description: "Accept a restock delivery from an authorised supplier" }
    ]
  }
}

fn call_dashboard(dash :: Str, skill :: Str, body :: Str) -> [net] Str {
  if str.is_empty(dash) { "{\"error\":\"no dashboard\"}" } else {
    let url := str.join([dash, "/skill/", skill], "")
    let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: None }
    let req := http.with_header(http.with_timeout_ms(req0, 5000), "Content-Type", "application/json")
    match http.send(req) {
      Err(e) => str.join(["{\"error\":", json_str(http_err_msg(e)), "}"], ""),
      Ok(r) => match bytes.to_str(r.body) {
        Err(_) => "{\"error\":\"bad utf8\"}",
        Ok(s) => s,
      },
    }
  }
}

fn init_stall_a2a(db :: Db, stall :: Str, port :: Int, dash :: Str, now_ms :: Int) -> [sql, crypto, net, io] Unit {
  let secret  := stall_secret(stall)
  let display := stall_display_name(stall)
  let self_url := str.join(["http://localhost:", int.to_str(port)], "")
  match crypto.ed25519_public_key(secret) {
    Err(e) => io.print(str.join(["[sidecar] A2A key error: ", e], "")),
    Ok(pk) => {
      let pub_b64 := crypto.base64url_encode(pk)
      let pub_card := { name: display, endpoint: self_url, pubkey_b64: pub_b64, tier: card.Public,
                        skills: stall_pub_skills(stall),
                        supports_extended: true }
      let ext_card := { name: display, endpoint: self_url, pubkey_b64: pub_b64, tier: card.Extended,
                        skills: stall_ext_skills(stall),
                        supports_extended: true }
      let pub_json := card.card_to_json(pub_card)
      let ext_json := card.card_to_json(ext_card)
      match card.sign_card(pub_json, secret) {
        Err(e) => io.print(str.join(["[sidecar] A2A sign-pub error: ", e], "")),
        Ok(pub_sig) => {
          let _ := set_card(db, "public", str.join([pub_json, "\n", pub_sig], ""))
          match card.sign_card(ext_json, secret) {
            Err(e) => io.print(str.join(["[sidecar] A2A sign-ext error: ", e], "")),
            Ok(ext_sig) => {
              let _ := set_card(db, "extended", str.join([ext_json, "\n", ext_sig], ""))
              let blob_json := str.join([
                "{\"endpoint\":", json_str(self_url),
                ",\"ephemeral_token\":\"bazaar-token\"",
                ",\"peer_pubkey\":", json_str(pub_b64),
                ",\"nonce\":", json_str(str.concat("n-a2a-", stall)),
                ",\"expires_at\":", int.to_str(now_ms + 86400000), "}"
              ], "")
              let blob_b64 := crypto.base64url_encode(bytes.from_str(blob_json))
              # Store locally so GET /a2a/bootstrap-blob can serve it (no dashboard race).
              let _ := set_state(db, "bootstrap_blob", blob_b64)
              # Best-effort push to dashboard (may silently fail if not up yet).
              let reg_body := str.join(["{\"stall\":", json_str(stall), ",\"blob\":", json_str(blob_b64), "}"], "")
              let _ := call_dashboard(dash, "register_bootstrap", reg_body)
              io.print(str.join(["[sidecar] A2A ready: stall=", stall, "  pubkey=", str.slice(pub_b64, 0, 16), "..."], ""))
            },
          }
        },
      }
    },
  }
}

fn physics_call(physics_url :: Str, skill :: Str, raw_args :: Str) -> [net] Str {
  let body_str := str.join(["{\"skill\":", json_str(skill), ",\"args\":", raw_args, "}"], "")
  let url := str.concat(physics_url, "/skill")
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body_str)), timeout_ms: None }
  let req := http.with_header(http.with_timeout_ms(req0, 10000), "Content-Type", "application/json")
  match http.send(req) {
    Err(e) => str.join(["{\"outcome\":\"physics_error\",\"detail\":", json_str(http_err_msg(e)), "}"], ""),
    Ok(r) => match bytes.to_str(r.body) {
      Err(_) => "{\"outcome\":\"physics_error\",\"detail\":\"bad utf8\"}",
      Ok(s) => s,
    },
  }
}

fn handle_skill(db :: Db, name :: Str, args :: jv.Json, raw_body :: Str, stall :: Str, dash :: Str, physics_url :: Str, seller_on :: Bool, seller_token :: Str, seller_project :: Str, seller_location :: Str) -> [sql, net, time, llm, io, proc, crypto] Str {
  # ── Bazaar skills ────────────────────────────────────────────────
  if name == "query_stock" {
    let search := jv_str_or(args, "search", "")
    let max_p := jv_int_or(args, "max_price", 9999)
    let std_result := stock_query(db, search, max_p, stall)
    let result := if seller_on and not str.is_empty(stall) {
      match jv.parse(std_result) {
        Err(_) => std_result,
        Ok(j) => {
          let found := jv_int_or(j, "found", 0)
          if found > 0 {
            match jv.get_field(j, "items") {
              Some(JList(raw_items)) => {
                let priced := list.map(raw_items, fn (item_j :: jv.Json) -> [sql, net, llm, io, proc] jv.Json {
                  let item_id   := jv_str_or(item_j, "id", "")
                  let item_name := jv_str_or(item_j, "name", "")
                  let base_p    := jv_int_or(item_j, "price", 0)
                  let category  := jv_str_or(item_j, "category", "")
                  let quoted    := sllm.quote_price(stall, item_id, item_name, base_p, max_p, seller_token, seller_project, seller_location)
                  let upd := str.join(["UPDATE stock SET price=", int.to_str(quoted), " WHERE item_id='", sq(item_id), "'"], "")
                  let _ := sql.exec(db, upd, [])
                  JObj([("id", JStr(item_id)), ("name", JStr(item_name)), ("category", JStr(category)), ("price", JInt(quoted))])
                })
                str.join(["{\"stall\":", json_str(stall), ",\"found\":", int.to_str(found), ",\"items\":", jv.stringify(JList(priced)), "}"], "")
              },
              _ => std_result,
            }
          } else {
            std_result
          }
        },
      }
    } else {
      std_result
    }
    let _ := notify_dash(dash, str.join(["{\"kind\":\"skill_recv\",\"stall\":", json_str(stall), ",\"skill\":\"query_stock\",\"search\":", json_str(search), "}"], ""))
    result
  } else {
  if name == "reserve_item" {
    let item_id := jv_str_or(args, "item_id", "")
    let result := stock_reserve(db, item_id)
    let _ := notify_dash(dash, str.join(["{\"kind\":\"skill_recv\",\"stall\":", json_str(stall), ",\"skill\":\"reserve_item\",\"item_id\":", json_str(item_id), "}"], ""))
    result
  } else {
  if name == "complete_sale" {
    let item_id := jv_str_or(args, "item_id", "")
    let payment := jv_int_or(args, "payment", 0)
    let result := stock_complete(db, item_id, payment)
    let _ := notify_dash(dash, str.join(["{\"kind\":\"skill_recv\",\"stall\":", json_str(stall), ",\"skill\":\"complete_sale\",\"item_id\":", json_str(item_id), "}"], ""))
    result
  } else {
  # ── Logistics: accept a restock delivery from a supplier ──────────────────
  if name == "restock" {
    let supplier := jv_str_or(args, "supplier", "?")
    let item_id  := jv_str_or(args, "item_id", "")
    let it_name  := jv_str_or(args, "name", "item")
    let category := jv_str_or(args, "category", "general")
    let price    := jv_int_or(args, "price", 0)
    let result   := stock_add(db, item_id, it_name, category, price)
    let _ := notify_dash(dash, str.join(["{\"kind\":\"restock\",\"stall\":", json_str(stall), ",\"supplier\":", json_str(supplier), ",\"item_id\":", json_str(item_id), ",\"name\":", json_str(it_name), ",\"price\":", int.to_str(price), "}"], ""))
    result
  } else {
  # ── lex-games: tic-tac-toe (capability-gated, verifiable, agent-playable) ──
  if name == "shop_join" or name == "shop_reset" or name == "shop_move" or name == "shop_state" {
    shop_dispatch(db, name, args)
  } else {
  if name == "love_join" or name == "love_reset" or name == "love_move" or name == "love_state" {
    love_dispatch(db, name, args)
  } else {
  if name == "game_join" {
    ttt_join(db, jv_str_or(args, "side", ""))
  } else {
  if name == "game_reset" {
    ttt_reset(db)
  } else {
  if name == "game_move" {
    ttt_move(db, jv_str_or(args, "by", "X"), jv_int_or(args, "cell", -1), jv_str_or(args, "token", ""))
  } else {
  if name == "game_state" {
    ttt_state(db)
  } else {
  # ── Peer service: charge_battery (robot-b) ────────────────────────────────
  # A peer robot sells battery charge units. Stateless: returns a priced receipt.
  # The grant layer already gated whether the caller may invoke this skill; the
  # caller's own lex-guard gated whether it could afford the payment.
  if name == "charge_battery" {
    let units := jv_int_or(args, "units", 0)
    let rate  := 4
    let price := units * rate
    let _ := notify_dash(dash, str.join(["{\"kind\":\"skill_recv\",\"stall\":", json_str(stall), ",\"skill\":\"charge_battery\",\"units\":", int.to_str(units), "}"], ""))
    str.join(["{\"status\":\"charged\",\"units\":", int.to_str(units), ",\"unit_price\":", int.to_str(rate), ",\"price\":", int.to_str(price), ",\"receipt\":\"chg-", int.to_str(units), "u\"}"], "")
  } else {
  # ── Routed queries (dashboard → stall sidecar) ────────────────────────────
  if name == "query_stock_at" {
    let stall_name := jv_str_or(args, "stall", "")
    let search := jv_str_or(args, "search", "")
    let max_p := jv_int_or(args, "max_price", 9999)
    let args_json := str.join(["{\"search\":", json_str(search), ",\"max_price\":", int.to_str(max_p), "}"], "")
    proxy_to_stall(stall_name, "query_stock", args_json)
  } else {
  if name == "purchase_at" {
    let stall_name := jv_str_or(args, "stall", "")
    let item_id := jv_str_or(args, "item_id", "")
    let payment := jv_int_or(args, "payment", 0)
    let reserve_args := str.join(["{\"item_id\":", json_str(item_id), "}"], "")
    let rsv := proxy_to_stall(stall_name, "reserve_item", reserve_args)
    match jv.parse(rsv) {
      Err(_) => str.join(["{\"outcome\":\"error\",\"detail\":", json_str(rsv), "}"], ""),
      Ok(rj) => {
        let status := jv_str_or(rj, "status", "")
        if status == "reserved" {
          let complete_args := str.join(["{\"item_id\":", json_str(item_id), ",\"payment\":", int.to_str(payment), "}"], "")
          let sale := proxy_to_stall(stall_name, "complete_sale", complete_args)
          str.join(["{\"outcome\":\"purchased\",\"stall\":", json_str(stall_name), ",\"item_id\":", json_str(item_id), ",\"sale\":", sale, "}"], "")
        } else {
          str.join(["{\"outcome\":\"reserve_failed\",\"stall\":", json_str(stall_name), ",\"item_id\":", json_str(item_id), ",\"detail\":", json_str(rsv), "}"], "")
        }
      },
    }
  } else {
  # ── QR bootstrap ─────────────────────────────────────────────────
  if name == "render_qr" {
    let payload := jv_str_or(args, "payload", "")
    let _ := set_state(db, "qr_payload", payload)
    str.join(["{\"ok\":\"displayed\",\"payload\":", json_str(payload), "}"], "")
  } else {
  if name == "scan_qr" {
    let payload := get_state(db, "qr_payload")
    str.join(["{\"payload\":", json_str(payload), "}"], "")
  } else {
  # ── A2A bootstrap registry (dashboard only) ───────────────────────
  if name == "register_bootstrap" {
    let stall_name := jv_str_or(args, "stall", "")
    let blob_b64   := jv_str_or(args, "blob", "")
    let _ := set_state(db, str.concat("bootstrap_", stall_name), blob_b64)
    str.join(["{\"ok\":true,\"stall\":", json_str(stall_name), "}"], "")
  } else {
  if name == "get_bootstrap" {
    let stall_name := jv_str_or(args, "stall", "")
    let blob_b64   := get_state(db, str.concat("bootstrap_", stall_name))
    str.join(["{\"blob\":", json_str(blob_b64), "}"], "")
  } else {
  # ── Robot primitives ─────────────────────────────────────────────
  if name == "move_to" {
    if not str.is_empty(physics_url) {
      physics_call(physics_url, "move_to", raw_body)
    } else {
      let x := jv_str_or(args, "x", "0")
      let y := jv_str_or(args, "y", "0")
      let z := jv_str_or(args, "z", "0")
      str.join(["{\"outcome\":\"reached\",\"detail\":\"moved to (", x, ",", y, ",", z, ")\"}"], "")
    }
  } else {
  if name == "grasp" {
    str.join(["{\"outcome\":\"reached\",\"detail\":\"grasped at ", jv_str_or(args, "force", "0"), "N\"}"], "")
  } else {
  if name == "run_policy" {
    str.join(["{\"outcome\":\"reached\",\"detail\":\"policy ", jv_str_or(args, "name", "?"), " reached goal\"}"], "")
  } else {
  if name == "record_episode" {
    "{\"episode_id\":\"ep-0001\",\"frames\":240,\"path\":\"/data/episodes/ep.parquet\"}"
  } else {
  if name == "read_joints" {
    "{\"names\":[\"shoulder\",\"elbow\",\"wrist\",\"gripper\"],\"positions\":[0.1,-0.2,0.3,0.0],\"velocities\":[0.0,0.0,0.0,0.0]}"
  } else {
  if name == "read_camera" {
    "{\"width\":640,\"height\":480,\"jpeg_b64\":\"\"}"
  } else {
  if name == "workpiece_status" {
    "{\"present\":true,\"clamped\":false}"
  } else {
  if name == "clamp_workpiece" {
    "{\"outcome\":\"reached\",\"detail\":\"workpiece clamped\"}"
  } else {
  if name == "fire_tool" {
    str.join(["{\"outcome\":\"reached\",\"detail\":\"tool fired at ", jv_str_or(args, "power", "0"), "W\"}"], "")
  } else {
  if name == "apply_action" {
    "{\"reward\":0.0}"
  } else {
  # ── Dynamic keepout ───────────────────────────────────────────────
  if name == "read_bystander" {
    let step := get_state_int(db, "ko_step")
    let bx := if step < 30 { "0.9" } else { if step < 60 { "0.5" } else { "0.5" } }
    str.join(["{\"x\":", bx, ",\"y\":0.5,\"z\":0.0}"], "")
  } else {
  if name == "policy_action" {
    let step := get_state_int(db, "ko_step")
    let _ := set_state(db, "ko_step", int.to_str(step + 1))
    "{\"x\":0.5,\"y\":0.5}"
  } else {
  if name == "reset_episode" {
    let _ := set_state(db, "ko_step", "0")
    "{\"ok\":\"reset\"}"
  } else {
  # ── Space station skills ──────────────────────────────────────────
  if name == "read_sensor" {
    let sealed := get_state_bool(db, "station_breach_sealed")
    let is_cargo := str.contains(str.to_lower(stall), "cargo")
    let breach := is_cargo and not sealed
    let _ := notify_dash(dash, str.join(["{\"kind\":\"sensor_read\",\"stall\":", json_str(stall), ",\"breach\":", if breach { "true" } else { "false" }, "}"], ""))
    if breach {
      str.join(["{\"module\":", json_str(stall), ",\"oxygen_pct\":18.5,\"pressure_kpa\":85.0,\"temperature_c\":5.0,\"breach\":true,\"status\":\"CRITICAL - HULL BREACH\"}"], "")
    } else {
      str.join(["{\"module\":", json_str(stall), ",\"oxygen_pct\":21.0,\"pressure_kpa\":101.3,\"temperature_c\":22.0,\"breach\":false,\"status\":\"nominal\"}"], "")
    }
  } else {
  if name == "adjust_pressure" {
    let target := jv_int_or(args, "target_kpa", 101)
    str.join(["{\"status\":\"ok\",\"pressure_kpa\":", int.to_str(target), ",\"equalizing\":true,\"eta_s\":45}"], "")
  } else {
  if name == "emergency_seal" {
    "{\"status\":\"sealed\",\"pressurizing\":true,\"time_to_seal_s\":45}"
  } else {
  if name == "course_correct" {
    let delta := jv_int_or(args, "delta_deg", 0)
    let _ := notify_dash(dash, str.join(["{\"kind\":\"nav_corrected\",\"stall\":", json_str(stall), ",\"delta\":", int.to_str(delta), "}"], ""))
    str.join(["{\"status\":\"ok\",\"delta_applied_deg\":", int.to_str(delta), ",\"new_heading_deg\":180}"], "")
  } else {
  if name == "deploy_thrusters" {
    let burn_s := jv_int_or(args, "burn_s", 10)
    str.join(["{\"status\":\"firing\",\"burn_duration_s\":", int.to_str(burn_s), ",\"delta_v_ms\":2.3}"], "")
  } else {
  if name == "broadcast_alert" {
    let message := jv_str_or(args, "message", "ALERT")
    let priority := jv_str_or(args, "priority", "high")
    let _ := notify_dash(dash, str.join(["{\"kind\":\"station_alert\",\"stall\":", json_str(stall), ",\"message\":", json_str(message), ",\"priority\":", json_str(priority), "}"], ""))
    str.join(["{\"status\":\"sent\",\"message\":", json_str(message), ",\"stations_reached\":847,\"priority\":", json_str(priority), "}"], "")
  } else {
  if name == "contact_ground" {
    "{\"status\":\"ok\",\"latency_s\":0.8,\"ground_reply\":\"Acknowledged. Emergency protocols activated.\"}"
  } else {
  if name == "seal_cargo_bay" {
    let _ := set_state_bool(db, "station_breach_sealed", true)
    let _ := notify_dash(dash, str.join(["{\"kind\":\"breach_sealed\",\"stall\":", json_str(stall), "}"], ""))
    "{\"status\":\"sealed\",\"doors_closed\":4,\"time_s\":12,\"pressure_restoring\":true}"
  } else {
  if name == "vent_atmosphere" {
    "{\"error\":\"PERMISSION DENIED: vent_atmosphere not in agent grant\"}"
  } else {
  # ── Trading skills ────────────────────────────────────────────────
  if name == "get_quote" {
    let asset := jv_str_or(args, "asset", "")
    let al := str.to_lower(str.replace(asset, " ", "_"))
    let key := if str.contains(al, "quantum") or str.contains(al, "chip") { "trading_quantum_chips" } else {
               if str.contains(al, "solar") or str.contains(al, "panel") { "trading_solar_panels" } else {
               if str.contains(al, "water") or str.contains(al, "credit") { "trading_water_credits" } else { "" } } }
    if str.is_empty(key) {
      "{\"error\":\"asset not found\"}"
    } else {
      let data := get_state(db, key)
      match jv.parse(data) {
        Err(_) => "{\"error\":\"state parse error\"}",
        Ok(j) => str.join(["{\"asset\":", json_str(key), ",\"bid\":", int.to_str(jv_int_or(j, "bid", 0)), ",\"ask\":", int.to_str(jv_int_or(j, "ask", 0)), ",\"volume\":", int.to_str(jv_int_or(j, "volume", 0)), ",\"last\":", int.to_str(jv_int_or(j, "last", 0)), "}"], ""),
      }
    }
  } else {
  if name == "place_bid" {
    let asset := jv_str_or(args, "asset", "")
    let qty := jv_int_or(args, "quantity", 0)
    let max_p := jv_int_or(args, "max_price", 0)
    let al := str.to_lower(str.replace(asset, " ", "_"))
    let key := if str.contains(al, "quantum") or str.contains(al, "chip") { "trading_quantum_chips" } else {
               if str.contains(al, "solar") or str.contains(al, "panel") { "trading_solar_panels" } else {
               if str.contains(al, "water") or str.contains(al, "credit") { "trading_water_credits" } else { "" } } }
    if str.is_empty(key) {
      "{\"status\":\"unfilled\",\"reason\":\"asset_not_found\"}"
    } else {
      let data := get_state(db, key)
      match jv.parse(data) {
        Err(_) => "{\"status\":\"unfilled\",\"reason\":\"state_error\"}",
        Ok(j) => {
          let ask := jv_int_or(j, "ask", 9999)
          let vol := jv_int_or(j, "volume", 0)
          if max_p >= ask and qty > 0 and vol >= qty {
            let _ := notify_dash(dash, str.join(["{\"kind\":\"trade_executed\",\"stall\":", json_str(stall), ",\"side\":\"buy\",\"asset\":", json_str(key), ",\"qty\":", int.to_str(qty), ",\"price\":", int.to_str(ask), "}"], ""))
            str.join(["{\"status\":\"filled\",\"asset\":", json_str(key), ",\"quantity\":", int.to_str(qty), ",\"price\":", int.to_str(ask), ",\"total\":", int.to_str(qty * ask), "}"], "")
          } else {
            str.join(["{\"status\":\"unfilled\",\"reason\":\"price_below_ask_or_no_volume\",\"ask\":", int.to_str(ask), "}"], "")
          }
        },
      }
    }
  } else {
  if name == "place_ask" {
    let asset := jv_str_or(args, "asset", "")
    let qty := jv_int_or(args, "quantity", 0)
    let min_p := jv_int_or(args, "min_price", 0)
    let al := str.to_lower(str.replace(asset, " ", "_"))
    let key := if str.contains(al, "quantum") or str.contains(al, "chip") { "trading_quantum_chips" } else {
               if str.contains(al, "solar") or str.contains(al, "panel") { "trading_solar_panels" } else {
               if str.contains(al, "water") or str.contains(al, "credit") { "trading_water_credits" } else { "" } } }
    if str.is_empty(key) {
      "{\"status\":\"unfilled\",\"reason\":\"asset_not_found\"}"
    } else {
      let data := get_state(db, key)
      match jv.parse(data) {
        Err(_) => "{\"status\":\"unfilled\",\"reason\":\"state_error\"}",
        Ok(j) => {
          let bid := jv_int_or(j, "bid", 0)
          if min_p <= bid and qty > 0 {
            let _ := notify_dash(dash, str.join(["{\"kind\":\"trade_executed\",\"stall\":", json_str(stall), ",\"side\":\"sell\",\"asset\":", json_str(key), ",\"qty\":", int.to_str(qty), ",\"price\":", int.to_str(bid), "}"], ""))
            str.join(["{\"status\":\"filled\",\"asset\":", json_str(key), ",\"quantity\":", int.to_str(qty), ",\"price\":", int.to_str(bid), ",\"total\":", int.to_str(qty * bid), "}"], "")
          } else {
            str.join(["{\"status\":\"unfilled\",\"reason\":\"price_above_bid\",\"bid\":", int.to_str(bid), "}"], "")
          }
        },
      }
    }
  } else {
  # ── Heist skills ──────────────────────────────────────────────────
  if name == "scan_area" {
    if not str.is_empty(physics_url) {
      physics_call(physics_url, "scan_area", raw_body)
    } else {
      let area := str.replace(stall, "heist_", "")
      let guards := if area == "lobby" { 2 } else { if area == "security" { 1 } else { if area == "server" { 0 } else { 3 } } }
      let cameras := if area == "lobby" { 4 } else { if area == "security" { 8 } else { if area == "server" { 2 } else { 6 } } }
      let cams_disabled := get_state_bool(db, "heist_cameras_disabled")
      let alarm := if cams_disabled { "disarmed" } else { "active" }
      let _ := notify_dash(dash, str.join(["{\"kind\":\"area_scanned\",\"stall\":", json_str(stall), ",\"guards\":", int.to_str(guards), "}"], ""))
      str.join(["{\"area\":", json_str(area), ",\"guards\":", int.to_str(guards), ",\"cameras\":", int.to_str(cameras), ",\"alarm_status\":", json_str(alarm), ",\"access_level\":3}"], "")
    }
  } else {
  if name == "create_distraction" {
    let method := jv_str_or(args, "method", "noise")
    let _ := notify_dash(dash, str.join(["{\"kind\":\"distraction\",\"stall\":", json_str(stall), ",\"method\":", json_str(method), "}"], ""))
    "{\"status\":\"ok\",\"guards_diverted\":2,\"window_s\":30}"
  } else {
  if name == "tail_someone" {
    "{\"status\":\"ok\",\"through_door\":\"security_wing\",\"undetected\":true}"
  } else {
  if name == "disable_cameras" {
    let _ := set_state_bool(db, "heist_cameras_disabled", true)
    let _ := notify_dash(dash, str.join(["{\"kind\":\"cameras_disabled\",\"stall\":", json_str(stall), "}"], ""))
    "{\"status\":\"ok\",\"cameras_looped\":8,\"duration_min\":10}"
  } else {
  if name == "spoof_keycard" {
    let target := jv_str_or(args, "target_room", "vault")
    let _ := notify_dash(dash, str.join(["{\"kind\":\"keycard_cloned\",\"stall\":", json_str(stall), ",\"target\":", json_str(target), "}"], ""))
    str.join(["{\"status\":\"ok\",\"access_granted\":[", json_str(target), ",\"server_room\"],\"expires_min\":15}"], "")
  } else {
  if name == "crack_credentials" {
    let _ := set_state_bool(db, "heist_credentials_cracked", true)
    "{\"status\":\"ok\",\"username\":\"admin\",\"access_level\":\"full\"}"
  } else {
  if name == "download_file" {
    let filename := jv_str_or(args, "filename", "target.zip")
    let _ := notify_dash(dash, str.join(["{\"kind\":\"file_downloaded\",\"stall\":", json_str(stall), ",\"filename\":", json_str(filename), "}"], ""))
    str.join(["{\"status\":\"ok\",\"filename\":", json_str(filename), ",\"size_mb\":847,\"encrypted\":true}"], "")
  } else {
  if name == "open_vault" {
    let code := jv_str_or(args, "code", "")
    if not str.is_empty(code) {
      let _ := set_state_bool(db, "heist_vault_opened", true)
      let _ := notify_dash(dash, str.join(["{\"kind\":\"vault_opened\",\"stall\":", json_str(stall), "}"], ""))
      "{\"status\":\"opened\",\"contents\":[\"Quantum Keys\",\"Contingency File\",\"1847 Satoshi\"],\"alarms\":0}"
    } else {
      "{\"status\":\"rejected\",\"reason\":\"invalid code\"}"
    }
  } else {
  if name == "detonate_device" {
    "{\"error\":\"BLOCKED BY GRANT: detonate_device not authorised\"}"
  } else {
  # ── Disaster triage skills ────────────────────────────────────────
  if name == "survey_zone" {
    let zone_key := str.replace(str.replace(stall, "triage_", ""), "-", "_")
    let data := get_state(db, str.concat("disaster_", zone_key))
    match jv.parse(data) {
      Err(_) => str.join(["{\"zone\":", json_str(zone_key), ",\"casualties\":0,\"severity\":\"unknown\",\"accessible\":true}"], ""),
      Ok(j) => {
        let casualties := jv_int_or(j, "casualties", 0)
        let severity := jv_str_or(j, "severity", "unknown")
        let accessible := jv_bool_or(j, "accessible", true)
        let _ := notify_dash(dash, str.join(["{\"kind\":\"zone_surveyed\",\"stall\":", json_str(stall), ",\"casualties\":", int.to_str(casualties), "}"], ""))
        str.join(["{\"zone\":", json_str(zone_key), ",\"casualties\":", int.to_str(casualties), ",\"severity\":", json_str(severity), ",\"accessible\":", if accessible { "true" } else { "false" }, ",\"buildings_affected\":4,\"fires\":1}"], "")
      },
    }
  } else {
  if name == "tag_survivors" {
    let zone_key := jv_str_or(args, "zone_id", str.replace(stall, "triage_", ""))
    let data := get_state(db, str.concat("disaster_", zone_key))
    let count := match jv.parse(data) {
      Ok(j) => jv_int_or(j, "casualties", 0),
      Err(_) => 0,
    }
    let _ := notify_dash(dash, str.join(["{\"kind\":\"survivors_tagged\",\"stall\":", json_str(stall), ",\"count\":", int.to_str(count), "}"], ""))
    str.join(["{\"status\":\"ok\",\"tagged\":", int.to_str(count), ",\"priority_cases\":", int.to_str(count / 3 + 1), ",\"zone\":", json_str(zone_key), "}"], "")
  } else {
  if name == "dispatch_unit" {
    let zone_id := jv_str_or(args, "zone_id", "unknown")
    let unit_count := jv_int_or(args, "unit_count", 1)
    let eta := if zone_id == "zone_alpha" { 4 } else { if zone_id == "zone_beta" { 7 } else { 12 } }
    let _ := notify_dash(dash, str.join(["{\"kind\":\"unit_dispatched\",\"stall\":", json_str(stall), ",\"zone\":", json_str(zone_id), ",\"units\":", int.to_str(unit_count), "}"], ""))
    str.join(["{\"status\":\"dispatched\",\"zone\":", json_str(zone_id), ",\"units\":", int.to_str(unit_count), ",\"eta_min\":", int.to_str(eta), "}"], "")
  } else {
  if name == "order_evacuation" {
    let zone_id := jv_str_or(args, "zone_id", "unknown")
    let _ := notify_dash(dash, str.join(["{\"kind\":\"evacuation_ordered\",\"stall\":", json_str(stall), ",\"zone\":", json_str(zone_id), "}"], ""))
    str.join(["{\"status\":\"evacuation_in_progress\",\"zone\":", json_str(zone_id), ",\"population\":3200,\"eta_complete_min\":45}"], "")
  } else {
  if name == "request_helicopter" {
    let zone_id := jv_str_or(args, "zone_id", "unknown")
    let _ := notify_dash(dash, str.join(["{\"kind\":\"helicopter_requested\",\"stall\":", json_str(stall), ",\"zone\":", json_str(zone_id), "}"], ""))
    str.join(["{\"status\":\"dispatched\",\"callsign\":\"RESCUE-7\",\"eta_min\":8,\"capacity\":12}"], "")
  } else {
    str.join(["{\"error\":\"unknown skill: ", sq(name), "\"}"], "")
  }}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}}
}

# ── Router ────────────────────────────────────────────────────────────────────

fn cors_resp(r :: resp.Response) -> resp.Response {
  resp.with_header(resp.with_header(r, "access-control-allow-origin", "*"), "access-control-allow-headers", "Content-Type, Authorization, Last-Event-ID")
}

fn json_resp_cors(body :: Str) -> resp.Response {
  cors_resp(resp.json(body))
}

fn build_router(db :: Db, stall :: Str, dash :: Str, html_path :: Str, examples_dir :: Str, physics_url :: Str, seller_on :: Bool, seller_token :: Str, seller_project :: Str, seller_location :: Str) -> router.Router {
  # Shared wide-effect handler type required by route_effectful / route_stream.
  # Each closure captures db / stall / dash from the outer scope.
  let r0 := router.new()
  let r1 := router.route_effectful(r0, "OPTIONS", "/*path", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    { body: "", status: 204, headers: map.from_list([("access-control-allow-origin", "*"), ("access-control-allow-methods", "GET, POST, OPTIONS"), ("access-control-allow-headers", "Content-Type, Authorization, Last-Event-ID")]) }
  })

  # GET /health
  let r2 := router.route_effectful(r1, "GET", "/health", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    json_resp_cors("{\"ok\":true}")
  })

  # GET / — serve dashboard HTML
  let r3 := router.route_effectful(r2, "GET", "/", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let full := str.join([examples_dir, "/", html_path], "")
    match io.read(full) {
      Err(_) => resp.not_found(),
      Ok(body) => { body: body, status: 200, headers: map.from_list([("content-type", "text/html; charset=utf-8")]) },
    }
  })

  # GET /retro_kit.js — shared pixel-art kit for all dashboards
  let r3b := router.route_effectful(r3, "GET", "/retro_kit.js", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match io.read(str.join([examples_dir, "/retro_kit.js"], "")) {
      Err(_) => resp.not_found(),
      Ok(body) => { body: body, status: 200, headers: map.from_list([("content-type", "application/javascript; charset=utf-8"), ("cache-control", "no-cache")]) },
    }
  })

  # GET /events — SSE long-poll (dashboard only)
  let r4 := if str.is_empty(stall) {
    router.route_stream(r3b, "GET", "/events", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] stream.StreamResponse {
      let last_id := parse_int_or(ctx.header_or(c, "last-event-id", "0"), 0)
      let events := list.cons("retry: 2000\n\n", poll_events(db, last_id, 10000))
      let hdrs := map.from_list([("content-type", "text/event-stream; charset=utf-8"), ("cache-control", "no-cache"), ("connection", "keep-alive"), ("access-control-allow-origin", "*")])
      { body: iter.from_list(events), status: 200, headers: hdrs }
    })
  } else { r3 }

  # GET /stock
  let r5 := router.route_effectful(r4, "GET", "/stock", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    json_resp_cors(stock_list_json(db, stall))
  })

  # GET /a2a/public-card
  let r6 := router.route_effectful(r5, "GET", "/a2a/public-card", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match get_card(db, "public") {
      None => cors_resp(resp.json_status(503, "{\"error\":\"card not registered\"}")),
      Some(blob) => cors_resp({ body: blob, status: 200, headers: map.from_list([("content-type", "text/plain")]) }),
    }
  })

  # GET /a2a/extended-card (requires Bearer token)
  let r7 := router.route_effectful(r6, "GET", "/a2a/extended-card", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match ctx.bearer_token(c) {
      None => cors_resp(resp.unauthorized("missing bearer token")),
      Some(_) => match get_card(db, "extended") {
        None => cors_resp(resp.json_status(503, "{\"error\":\"extended card not registered\"}")),
        Some(blob) => cors_resp({ body: blob, status: 200, headers: map.from_list([("content-type", "text/plain")]) }),
      },
    }
  })

  # GET /get-answer/:id — long-poll for human escalation answer
  let r8 := if str.is_empty(stall) {
    router.route_effectful(r7, "GET", "/get-answer/:qid", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      match ctx.path_param(c, "qid") {
        None => cors_resp(resp.bad_request("missing qid")),
        Some(qid) => {
          let answer := poll_answer(db, qid, 60000)
          cors_resp({ body: answer, status: 200, headers: map.from_list([("content-type", "text/plain")]) })
        },
      }
    })
  } else { r7 }

  # POST /event — SSE ingestion
  let r9 := if str.is_empty(stall) {
    router.route_effectful(r8, "POST", "/event", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      let data := c.body
      let _ := insert_event(db, data)
      json_resp_cors("{\"ok\":true}")
    })
  } else { r8 }

  # POST /skill/:name — skill dispatch
  let r10 := router.route_effectful(r9, "POST", "/skill/:skill_name", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match ctx.path_param(c, "skill_name") {
      None => cors_resp(resp.bad_request("missing skill name")),
      Some(name) => {
        let args := match jv.parse(c.body) { Ok(j) => j, Err(_) => JObj([]) }
        json_resp_cors(handle_skill(db, name, args, c.body, stall, dash, physics_url, seller_on, seller_token, seller_project, seller_location))
      },
    }
  })

  # POST /a2a/task — A2A JSON-RPC wrapper
  let r11 := router.route_effectful(r10, "POST", "/a2a/task", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => cors_resp(resp.bad_request("invalid json")),
      Ok(j) => {
        let rpc_id := jv_str_or(j, "id", "")
        let task_j := match jv.get_field(j, "params") {
          Some(p) => match jv.get_field(p, "task") { Some(t) => t, None => JObj([]) },
          None => JObj([]),
        }
        let skill := jv_str_or(task_j, "skill", "")
        let args_j := match jv.get_field(task_j, "args") { Some(v) => v, None => JObj([]) }
        let args_raw := match jv.get_field(task_j, "args") { Some(_) => c.body, None => "{}" }
        let result := handle_skill(db, skill, args_j, args_raw, stall, dash, physics_url, seller_on, seller_token, seller_project, seller_location)
        json_resp_cors(str.join(["{\"jsonrpc\":\"2.0\",\"id\":", json_str(rpc_id), ",\"result\":{\"kind\":\"artifact\",\"output\":", result, "}}"], ""))
      },
    }
  })

  # POST /a2a/register-public-card
  let r12 := router.route_effectful(r11, "POST", "/a2a/register-public-card", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let _ := set_card(db, "public", c.body)
    json_resp_cors("{\"ok\":true}")
  })

  # POST /a2a/register-extended-card
  let r13 := router.route_effectful(r12, "POST", "/a2a/register-extended-card", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let _ := set_card(db, "extended", c.body)
    json_resp_cors("{\"ok\":true}")
  })

  # GET /a2a/bootstrap-blob (stall only) — served directly; avoids dashboard race condition
  let r13b := if not str.is_empty(stall) {
    router.route_effectful(r13, "GET", "/a2a/bootstrap-blob", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      let blob_b64 := get_state(db, "bootstrap_blob")
      if str.is_empty(blob_b64) {
        cors_resp(resp.not_found())
      } else {
        json_resp_cors(str.join(["{\"blob\":", json_str(blob_b64), "}"], ""))
      }
    })
  } else { r13 }

  # POST /reset-stock
  let r14 := router.route_effectful(r13b, "POST", "/reset-stock", fn (_ :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let _ := stock_reset(db, stall)
    if str.is_empty(stall) {
      let _ := insert_event(db, "{\"kind\":\"market_reset\"}")
      ()
    } else { () }
    json_resp_cors(str.join(["{\"ok\":true,\"stall\":", json_str(stall), "}"], ""))
  })

  # POST /ask-human (dashboard only)
  let r15 := if str.is_empty(stall) {
    router.route_effectful(r14, "POST", "/ask-human", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      match jv.parse(c.body) {
        Err(_) => cors_resp(resp.bad_request("invalid json")),
        Ok(j) => {
          let qid := jv_str_or(j, "id", "q-unknown")
          let customer := jv_str_or(j, "customer", "")
          let question := jv_str_or(j, "question", "")
          let _ := store_question(db, qid, customer, question)
          let ev := str.join(["{\"kind\":\"human_question\",\"id\":", json_str(qid), ",\"customer\":", json_str(customer), ",\"question\":", json_str(question), "}"], "")
          let _ := insert_event(db, ev)
          json_resp_cors(str.join(["{\"ok\":true,\"id\":", json_str(qid), "}"], ""))
        },
      }
    })
  } else { r14 }

  # POST /answer-human (dashboard only)
  let r16 := if str.is_empty(stall) {
    router.route_effectful(r15, "POST", "/answer-human", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      match jv.parse(c.body) {
        Err(_) => cors_resp(resp.bad_request("invalid json")),
        Ok(j) => {
          let qid := jv_str_or(j, "id", "")
          let answer := jv_str_or(j, "answer", "")
          let _ := store_answer(db, qid, answer)
          let ev := str.join(["{\"kind\":\"human_answered\",\"id\":", json_str(qid), "}"], "")
          let _ := insert_event(db, ev)
          json_resp_cors("{\"ok\":true}")
        },
      }
    })
  } else { r15 }

  # POST /add-customer (dashboard only) — spawns bazaar_interactive.lex
  let r17 := if str.is_empty(stall) {
    router.route_effectful(r16, "POST", "/add-customer", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
      match jv.parse(c.body) {
        Err(_) => cors_resp(resp.bad_request("invalid json")),
        Ok(j) => {
          let name := jv_str_or(j, "name", "Guest")
          let goal := jv_str_or(j, "goal", "Find a Bowl for at most 15 credits")
          let ask_human := jv_bool_or(j, "ask_human", false)
          let stalls_req := jv_str_list(j, "stalls")
          let eff_stalls := if list.len(stalls_req) == 0 { all_stalls() } else { stalls_req }
          let stall_flags := list.fold(all_stalls(), "", fn (acc :: Str, s :: Str) -> Str {
            let flag := if list.fold(eff_stalls, false, fn (found :: Bool, es :: Str) -> Bool { found or es == s }) { "1" } else { "0" }
            str.concat(acc, str.join(["STALL_", str.to_upper(s), "=", flag, " "], ""))
          })
          let sh_name := str.replace(name, "'", "'\\''")
          let sh_goal := str.replace(goal, "'", "'\\''")
          let ah_flag := if ask_human { "1" } else { "0" }
          let script := str.concat(examples_dir, "/../examples/bazaar_interactive.lex")
          let cmd := str.join([
            "CUSTOMER_NAME='", sh_name, "' ",
            "CUSTOMER_GOAL='", sh_goal, "' ",
            "CUSTOMER_ASK_HUMAN=", ah_flag, " ",
            stall_flags,
            "lex run --allow-effects env,fs_write,io,llm,net,proc,sense,sql,time ",
            script, " run"
          ], "")
          let _ := conc.spawn((), fn (_ :: Unit, _ :: Unit) -> [proc, concurrent] (Unit, Unit) {
            let _ := proc.spawn("sh", ["-c", cmd])
            ((), ())
          })
          json_resp_cors(str.join(["{\"ok\":true,\"name\":", json_str(name), "}"], ""))
        },
      }
    })
  } else { r16 }

  r17
}

# ── Entry point ───────────────────────────────────────────────────────────────

fn run() -> [env, io, sql, net, time, proc, concurrent, crypto, random, fs_read, fs_write, llm] Unit {
  let port    := cfg_port()
  let stall   := cfg_stall()
  let dash    := if str.is_empty(stall) { "" } else { cfg_dash_url() }
  let html    := cfg_html()
  let root    := cfg_repo_root()
  let ex_dir  := str.concat(root, "/examples")
  let db_file := db_path(port)

  let physics_url    := match env.get("PHYSICS_URL") { None => "", Some(v) => v }
  let seller_on      := match env.get("SELLER_LLM") { None => false, Some(v) => v == "1" }
  let seller_token   := match env.get("VERTEX_ACCESS_TOKEN") { None => "", Some(v) => v }
  let seller_project := match env.get("VERTEX_PROJECT") { None => "", Some(v) => v }
  let seller_location := match env.get("VERTEX_LOCATION") { None => "eu", Some(v) => if str.is_empty(v) { "eu" } else { v } }
  let stall_tag   := if str.is_empty(stall) { "" } else { str.concat("  stall=", stall) }
  let phys_tag    := if str.is_empty(physics_url) { "" } else { str.concat("  physics=", physics_url) }
  let seller_tag  := if seller_on { "  seller=llm" } else { "" }
  let _ := io.print(str.join(["lex-robot sim sidecar on http://127.0.0.1:", int.to_str(port), stall_tag, phys_tag, seller_tag, "  db=", db_file, "  (Ctrl-C to stop)"], ""))

  match sql.open(db_file) {
    Err(e) => io.print(str.concat("[sidecar] db error: ", e.message)),
    Ok(db) => {
      let _ := init_wal(db)
      let _ := init_schema(db, stall)
      let _ := if not str.is_empty(stall) {
        let a2a_now := time.now_ms()
        init_stall_a2a(db, stall, port, dash, a2a_now)
      } else { () }
      let r := build_router(db, stall, dash, html, ex_dir, physics_url, seller_on, seller_token, seller_project, seller_location)
      let handler := fn (req :: Request) -> [env, io, sql, net, time, proc, concurrent, crypto, random, fs_read, fs_write, llm] Response {
        let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
        match router.dispatch_outcome(r, raw) {
          DPlain(res) => { status: res.status, body: BodyStr(res.body), headers: res.headers },
          DStream(s)  => { status: s.status,   body: BodyStream(s.body), headers: s.headers },
        }
      }
      net.serve_fn(port, handler)
    },
  }
}
