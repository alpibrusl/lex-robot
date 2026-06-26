# examples/bazaar_room_buyer.lex — a remote buyer agent for the WS bazaar room.
#
# It dials examples/bazaar_room.lex, competes for scarce items, and governs +
# settles its OWN purchases against its OWN signed budget token — writing its own
# hash-chained trail. The room only arbitrates who reserves what; the buyer pays.
# A reserved item it cannot afford / is not allowed to buy is released back.
#
# The buyer drives itself reactively off the server's replies (dial_ws): on each
# reply it settles (if it won), then reserves its next wished item — so the whole
# session is server-reply-driven, no polling. The trail is flushed after each
# settlement, so it's complete even if the room is torn down abruptly.
#
# Env: BUYER_ID (alice|bob|carol, default alice), NB_PORT (default 8910),
#      BAZAAR_DIR (trail output dir, default ".")
# Run: BUYER_ID=alice lex run --allow-effects \
#        concurrent,crypto,env,fs_write,io,net,sql,time examples/bazaar_room_buyer.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.net" as net

import "std.conc" as conc

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-guard/src/models" as models

import "lex-guard/src/gate" as gate

import "lex-guard/src/x402_mock_exec" as x402m

import "lex-games/src/arena/trail_file" as tf

# ── this buyer's identity, budget + wishlist (presets keyed by BUYER_ID) ─────
type Profile = { agent :: Str, token :: Str, cap :: Int, allow :: List[Str], wishlist :: List[Int] }

fn profile(id :: Str) -> Profile {
  if id == "bob" {
    { agent: "bob", token: "tok_bob", cap: 4000, allow: ["textile.bazaar", "spice.bazaar", "books.bazaar"], wishlist: [1, 3, 4] }
  } else {
    if id == "carol" {
      { agent: "carol", token: "tok_carol", cap: 3000, allow: ["pottery.bazaar", "data.bazaar"], wishlist: [3, 0, 1] }
    } else {
      { agent: "alice", token: "tok_alice", cap: 4000, allow: ["pottery.bazaar", "textile.bazaar", "data.bazaar", "books.bazaar"], wishlist: [1, 0, 2] }
    }
  }
}

fn policy_of(p :: Profile) -> models.Policy {
  { token_id: p.token, agent_id: p.agent, currency: "USDC", cap_total: p.cap, cap_per_day: p.cap, cap_per_transaction: 3000, merchants_allow: p.allow, categories_allow: ["goods", "saas"], max_tx_per_hour: 99, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn budget_opened_json(p :: models.Policy) -> Str {
  let allow := str.join(list.map(p.merchants_allow, fn (m :: Str) -> Str {
    str.join(["\"", m, "\""], "")
  }), ",")
  str.join(["{\"agent\":\"", p.agent_id, "\",\"currency\":\"USDC\",\"cap_total\":", int.to_str(p.cap_total), ",\"cap_per_transaction\":", int.to_str(p.cap_per_transaction), ",\"merchants_allow\":[", allow, "]}"], "")
}

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "ShopperSoLAddr666666666666666666666666666666" }
}

fn usdc_mint() -> Str {
  "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}

# ── wishlist cursor (a tiny actor so progress persists across ws callbacks) ──
type Mind = { wishlist :: List[Int], idx :: Int }

type MMsg = Peek | Advance

fn nth_int(xs :: List[Int], i :: Int) -> Int {
  match list.head(xs) {
    None => 0 - 1,
    Some(h) => if i <= 0 {
      h
    } else {
      nth_int(list.tail(xs), i - 1)
    },
  }
}

fn mind_step(m :: Mind, msg :: MMsg) -> (Mind, Int) {
  match msg {
    Peek => (m, nth_int(m.wishlist, m.idx)),
    Advance => {
      let i := m.idx + 1
      ({ wishlist: m.wishlist, idx: i }, nth_int(m.wishlist, i))
    },
  }
}

# Parse the room's "OK <merchant> <pay_to> <price>" reply.
type Offer = { ok :: Bool, merchant :: Str, pay_to :: Str, price :: Int }

fn nth_str(xs :: List[Str], i :: Int) -> Str {
  match list.head(xs) {
    None => "",
    Some(h) => if i <= 0 {
      h
    } else {
      nth_str(list.tail(xs), i - 1)
    },
  }
}

fn parse_offer(s :: Str) -> Offer {
  if str.starts_with(s, "OK ") {
    let p := str.split(s, " ")
    { ok: true, merchant: nth_str(p, 1), pay_to: nth_str(p, 2), price: match str.to_int(nth_str(p, 3)) {
      Some(n) => n,
      None => 0,
    } }
  } else {
    { ok: false, merchant: "", pay_to: "", price: 0 }
  }
}

fn reserve_or_done(mind :: Actor[Mind]) -> [concurrent] WsAction {
  let next :: Int := conc.ask(mind, Advance)
  if next < 0 {
    WsNoOp
  } else {
    WsSend(str.join(["reserve ", int.to_str(next)], ""))
  }
}

fn run() -> [env, net, concurrent, crypto, sql, time, io, fs_write] Nil {
  let id := match env.get("BUYER_ID") {
    Some(v) => v,
    None => "alice",
  }
  let port := match env.get("NB_PORT") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 8910,
    },
    None => 8910,
  }
  let dir := match env.get("BAZAAR_DIR") {
    Some(v) => v,
    None => ".",
  }
  let prof := profile(id)
  let pol := policy_of(prof)
  let url := str.join(["ws://127.0.0.1:", int.to_str(port)], "")
  let trail_path := str.join([dir, "/bazaar_", prof.agent, ".jsonl"], "")
  match trail.open_memory() {
    Err(e) => io.print(str.concat("trail open failed: ", e)),
    Ok(log) => {
      let _b := trail.append(log, "budget.opened", None, budget_opened_json(pol))
      let mind := conc.spawn({ wishlist: prof.wishlist, idx: 0 }, fn (m :: Mind, msg :: MMsg) -> (Mind, Int) {
        mind_step(m, msg)
      })
      let __lex_discard_1 := io.print(str.join(["[", prof.agent, "] joining bazaar at ", url, " — wishlist ", int.to_str(list.len(prof.wishlist)), " items, cap ", int.to_str(prof.cap)], ""))
      let res := net.dial_ws(url, "", fn () -> [concurrent, crypto, sql, time, io, fs_write, net] WsAction {
        let first :: Int := conc.ask(mind, Peek)
        if first < 0 {
          WsNoOp
        } else {
          WsSend(str.join(["reserve ", int.to_str(first)], ""))
        }
      }, fn (m :: WsMessage) -> [concurrent, crypto, sql, time, io, fs_write, net] WsAction {
        match m {
          WsText(s) => {
            let item :: Int := conc.ask(mind, Peek)
            let offer := parse_offer(s)
            if not offer.ok {
              let __lex_discard_2 := io.print(str.join(["  [", prof.agent, "] item ", int.to_str(item), ": ", s], ""))
              reserve_or_done(mind)
            } else {
              let exec := x402m.make(signer(), offer.pay_to, usdc_mint())
              let intent := { merchant: offer.merchant, amount: offer.price, currency: "USDC", category: "goods", memo: str.join(["item-", int.to_str(item)], "") }
              match gate.spend(pol, log, exec, intent) {
                Err(_) => reserve_or_done(mind),
                Ok(o) => {
                  let _flush := flush(log, trail_path)
                  if o.approved {
                    let __lex_discard_3 := io.print(str.join(["  [", prof.agent, "] won + paid ", offer.merchant, " ", int.to_str(offer.price)], ""))
                    reserve_or_done(mind)
                  } else {
                    let __lex_discard_4 := io.print(str.join(["  [", prof.agent, "] ", offer.merchant, " ", int.to_str(offer.price), " DENIED — releasing"], ""))
                    WsSend(str.join(["release ", int.to_str(item)], ""))
                  }
                },
              }
            }
          },
          _ => WsNoOp,
        }
      })
      match res {
        Ok(_) => done(log, trail_path, prof.agent),
        Err(_) => done(log, trail_path, prof.agent),
      }
    },
  }
}

# Write the current trail to disk (flushed after each settlement, and at exit).
fn flush(log :: trail.Log, path :: Str) -> [io, sql] Int {
  match trail.range(log, 0, 9999999999999) {
    Err(_) => 0,
    Ok(evs) => {
      let __lex_discard_5 := io.write(path, tf.to_jsonl(list.map(evs, tf.from_event)))
      list.len(evs)
    },
  }
}

fn done(log :: trail.Log, path :: Str, agent :: Str) -> [io, sql, fs_write] Nil {
  let n := flush(log, path)
  io.print(str.join(["[", agent, "] left the bazaar — wrote ", int.to_str(n), " trail events → ", path], ""))
}

