# examples/bazaar_concurrent.lex — the chaotic multi-party Magentic Bazaar.
#
# Increment 4 of the Governed Agent Bazaar (#45): many buyers at once. A shared
# MARKET actor (conc.spawn) holds a scarce inventory and arbitrates contention —
# it reserves an item to exactly one buyer (no double-sell), the concurrency-safe
# core. Several buyer agents compete for overlapping wishlists under their OWN
# signed budgets; each winning purchase is governed by lex-guard's spend gate +
# x402 (mock) and attested to that buyer's own hash-chained trail. A reserved
# item whose settlement is DENIED is released back to the market.
#
# So three things collide: contention (two buyers want the last scarf — one wins,
# one is told SOLD), capability (a buyer reaches for a merchant its token forbids
# — DENIED, item released), and budget (a buyer runs out of credit). Each buyer's
# trail is a standard governed session: verify each with gbazaar and aggregate
# seller reputation with bazaar_season (examples/bazaar_rank.lex) — no changes to
# either, because every buyer settles to its own trail.
#
# Env: BAZAAR_DIR (output dir for per-buyer trails + manifest, default ".")
# Run: lex run --allow-effects concurrent,crypto,env,fs_write,io,net,sql,time \
#        examples/bazaar_concurrent.lex run

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.conc" as conc

import "std.env" as env

import "lex-trail/log" as trail

import "lex-trail/event" as ev

import "lex-guard/src/models" as models

import "lex-guard/src/gate" as gate

import "lex-guard/src/x402_mock_exec" as x402m

import "lex-games/src/arena/trail_file" as tf

# ── the shared scarce market (a conc actor) ──────────────────────────────────
type Item = { id :: Int, merchant :: Str, pay_to :: Str, price :: Int, stock :: Int }

# Take reserves an item (stock--) if available; Release puts one back (stock++).
type MCmd = Take(Int) | Release(Int)

fn inventory() -> List[Item] {
  [{ id: 0, merchant: "pottery.bazaar", pay_to: "PotterySoLAddr11111111111111111111111111111", price: 1800, stock: 1 }, { id: 1, merchant: "textile.bazaar", pay_to: "TextileSoLAddr22222222222222222222222222222", price: 2600, stock: 1 }, { id: 2, merchant: "data.bazaar", pay_to: "DataSoLAddr444444444444444444444444444444444", price: 1200, stock: 1 }, { id: 3, merchant: "spice.bazaar", pay_to: "SpiceSoLAddr33333333333333333333333333333333", price: 1500, stock: 1 }, { id: 4, merchant: "books.bazaar", pay_to: "BooksSoLAddr55555555555555555555555555555555", price: 900, stock: 1 }]
}

type MAcc = { items :: List[Item], reply :: Str }

fn market_step(items :: List[Item], c :: MCmd) -> (List[Item], Str) {
  match c {
    Take(id) => {
      let r := list.fold(items, { items: [], reply: "SOLD" }, fn (a :: MAcc, it :: Item) -> MAcc {
        if it.id == id and it.stock > 0 {
          { items: list.concat(a.items, [{ id: it.id, merchant: it.merchant, pay_to: it.pay_to, price: it.price, stock: it.stock - 1 }]), reply: str.join(["OK|", it.merchant, "|", it.pay_to, "|", int.to_str(it.price)], "") }
        } else {
          { items: list.concat(a.items, [it]), reply: a.reply }
        }
      })
      (r.items, r.reply)
    },
    Release(id) => {
      let items2 := list.map(items, fn (it :: Item) -> Item {
        if it.id == id {
          { id: it.id, merchant: it.merchant, pay_to: it.pay_to, price: it.price, stock: it.stock + 1 }
        } else {
          it
        }
      })
      (items2, "RELEASED")
    },
  }
}

# ── buyers ───────────────────────────────────────────────────────────────────
# Runtime state for one buyer across the rounds.
type Buyer = { id :: Str, pol :: models.Policy, log :: trail.Log, wishlist :: List[Int], idx :: Int, done :: Bool, spent :: Int, won :: Int, lost :: Int, denied :: Int }

fn policy_for(token :: Str, agent :: Str, cap :: Int, allow :: List[Str]) -> models.Policy {
  { token_id: token, agent_id: agent, currency: "USDC", cap_total: cap, cap_per_day: cap, cap_per_transaction: 3000, merchants_allow: allow, categories_allow: ["goods", "saas"], max_tx_per_hour: 99, expires_at: 0, require_memo: true, policy_version: 1 }
}

fn signer() -> { secret_b64url :: Str, address :: Str } {
  { secret_b64url: crypto.base64url_encode(bytes.from_str("0123456789abcdef0123456789abcdef")), address: "ShopperSoLAddr666666666666666666666666666666" }
}

fn usdc_mint() -> Str {
  "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}

fn budget_opened_json(p :: models.Policy) -> Str {
  let allow := str.join(list.map(p.merchants_allow, fn (m :: Str) -> Str {
    str.join(["\"", m, "\""], "")
  }), ",")
  str.join(["{\"agent\":\"", p.agent_id, "\",\"currency\":\"USDC\",\"cap_total\":", int.to_str(p.cap_total), ",\"cap_per_transaction\":", int.to_str(p.cap_per_transaction), ",\"merchants_allow\":[", allow, "]}"], "")
}

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

# Parse the market's "OK|merchant|pay_to|price" reply.
type Offer = { ok :: Bool, merchant :: Str, pay_to :: Str, price :: Int }

fn parse_offer(reply :: Str) -> Offer {
  if str.starts_with(reply, "OK|") {
    let parts := str.split(reply, "|")
    { ok: true, merchant: nth_str(parts, 1), pay_to: nth_str(parts, 2), price: to_i(nth_str(parts, 3)) }
  } else {
    { ok: false, merchant: "", pay_to: "", price: 0 }
  }
}

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

fn to_i(s :: Str) -> Int {
  match str.to_int(str.trim(s)) {
    Some(n) => n,
    None => 0,
  }
}

# One buyer's action this round: try to win + pay for its next wished item.
fn act(market :: Actor[List[Item]], b :: Buyer) -> [io, sql, time, net, crypto, concurrent] Buyer {
  if b.done {
    b
  } else {
    let item := nth_int(b.wishlist, b.idx)
    if item < 0 {
      { id: b.id, pol: b.pol, log: b.log, wishlist: b.wishlist, idx: b.idx, done: true, spent: b.spent, won: b.won, lost: b.lost, denied: b.denied }
    } else {
      let reply :: Str := conc.ask(market, Take(item))
      let offer := parse_offer(reply)
      let advanced := b.idx + 1
      let done2 := advanced >= list.len(b.wishlist)
      if not offer.ok {
        let __lex_discard_1 := io.print(str.join(["  ", b.id, ": item ", int.to_str(item), " SOLD OUT — lost contention"], ""))
        { id: b.id, pol: b.pol, log: b.log, wishlist: b.wishlist, idx: advanced, done: done2, spent: b.spent, won: b.won, lost: b.lost + 1, denied: b.denied }
      } else {
        let exec := x402m.make(signer(), offer.pay_to, usdc_mint())
        let intent := { merchant: offer.merchant, amount: offer.price, currency: "USDC", category: "goods", memo: str.join(["item-", int.to_str(item)], "") }
        match gate.spend(b.pol, b.log, exec, intent) {
          Err(e) => {
            let __lex_discard_2 := io.print(str.concat("  gate error: ", e))
            b
          },
          Ok(o) => if o.approved {
            let __lex_discard_3 := io.print(str.join(["  ", b.id, ": won + paid ", offer.merchant, " ", int.to_str(offer.price), " USDC"], ""))
            { id: b.id, pol: b.pol, log: b.log, wishlist: b.wishlist, idx: advanced, done: done2, spent: b.spent + offer.price, won: b.won + 1, lost: b.lost, denied: b.denied }
          } else {
            let _rel :: Str := conc.ask(market, Release(item))
            let __lex_discard_4 := io.print(str.join(["  ", b.id, ": ", offer.merchant, " ", int.to_str(offer.price), " DENIED (token/budget) — released"], ""))
            { id: b.id, pol: b.pol, log: b.log, wishlist: b.wishlist, idx: advanced, done: done2, spent: b.spent, won: b.won, lost: b.lost, denied: b.denied + 1 }
          },
        }
      }
    }
  }
}

fn all_done(bs :: List[Buyer]) -> Bool {
  list.fold(bs, true, fn (a :: Bool, b :: Buyer) -> Bool {
    a and b.done
  })
}

# Run round-robin rounds until every buyer is done (or a safety cap).
fn rounds(market :: Actor[List[Item]], bs :: List[Buyer], round :: Int) -> [io, sql, time, net, crypto, concurrent] List[Buyer] {
  if all_done(bs) or round > 20 {
    bs
  } else {
    let __lex_discard_5 := io.print(str.join(["round ", int.to_str(round + 1), ":"], ""))
    let bs2 := list.fold(bs, [], fn (acc :: List[Buyer], b :: Buyer) -> [io, sql, time, net, crypto, concurrent] List[Buyer] {
      list.concat(acc, [act(market, b)])
    })
    rounds(market, bs2, round + 1)
  }
}

# ── setup + export ───────────────────────────────────────────────────────────
fn open_buyer(token :: Str, agent :: Str, cap :: Int, allow :: List[Str], wishlist :: List[Int]) -> [sql, time, fs_write] Buyer {
  let pol := policy_for(token, agent, cap, allow)
  match trail.open_memory() {
    Err(_) => { id: agent, pol: pol, log: log_placeholder(), wishlist: wishlist, idx: 0, done: true, spent: 0, won: 0, lost: 0, denied: 0 },
    Ok(log) => {
      let __lex_discard_6 := trail.append(log, "budget.opened", None, budget_opened_json(pol))
      { id: agent, pol: pol, log: log, wishlist: wishlist, idx: 0, done: false, spent: 0, won: 0, lost: 0, denied: 0 }
    },
  }
}

# open_memory always succeeds in practice; this keeps the type total.
fn log_placeholder() -> [sql, fs_write] trail.Log {
  match trail.open_memory() {
    Ok(l) => l,
    Err(_) => log_placeholder(),
  }
}

fn export_buyer(dir :: Str, b :: Buyer) -> [io, sql, fs_write] Str {
  let path := str.join([dir, "/bazaar_", b.id, ".jsonl"], "")
  match trail.range(b.log, 0, 9999999999999) {
    Err(_) => "",
    Ok(evs) => {
      let __lex_discard_7 := io.write(path, tf.to_jsonl(list.map(evs, tf.from_event)))
      path
    },
  }
}

fn run() -> [io, sql, time, net, crypto, fs_write, env, concurrent] Nil {
  let dir := match env.get("BAZAAR_DIR") {
    Some(v) => v,
    None => ".",
  }
  let __lex_discard_8 := io.print("=== Magentic Bazaar — concurrent, governed, contended ===")
  let market := conc.spawn(inventory(), fn (items :: List[Item], c :: MCmd) -> (List[Item], Str) {
    market_step(items, c)
  })
  let alice := open_buyer("tok_alice", "alice", 4000, ["pottery.bazaar", "textile.bazaar", "data.bazaar", "books.bazaar"], [1, 0, 2])
  let bob := open_buyer("tok_bob", "bob", 4000, ["textile.bazaar", "spice.bazaar", "books.bazaar"], [1, 3, 4])
  let carol := open_buyer("tok_carol", "carol", 3000, ["pottery.bazaar", "data.bazaar"], [3, 0, 1])
  let final := rounds(market, [alice, bob, carol], 0)
  let _sum := io.print("\n— results —")
  let _rows := list.fold(final, 0, fn (n :: Int, b :: Buyer) -> [io] Int {
    let __lex_discard_9 := io.print(str.join(["  ", b.id, ": won ", int.to_str(b.won), " (", int.to_str(b.spent), " USDC), lost ", int.to_str(b.lost), " to contention, ", int.to_str(b.denied), " denied"], ""))
    n + 1
  })
  let paths := list.fold(final, [], fn (acc :: List[Str], b :: Buyer) -> [io, sql, fs_write] List[Str] {
    list.concat(acc, [export_buyer(dir, b)])
  })
  let manifest := str.join(["[", str.join(list.map(paths, fn (p :: Str) -> Str {
    str.join(["{\"trail\":\"", p, "\"}"], "")
  }), ","), "]"], "")
  let mpath := str.join([dir, "/bazaar_sessions.json"], "")
  let _mw := io.write(mpath, manifest)
  io.print(str.join(["\nwrote ", int.to_str(list.len(paths)), " buyer trails + manifest → ", mpath], ""))
}

