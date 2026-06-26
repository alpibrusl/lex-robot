# examples/bazaar_room.lex — a live WebSocket bazaar room (the contention arbiter).
#
# Increment 7 of the Governed Agent Bazaar (#45): the concurrent bazaar goes
# REMOTE. Buyer agents connect over WebSocket and compete for a scarce inventory;
# a shared MARKET actor (conc.spawn) reserves each item to exactly one buyer (no
# double-sell). The server does NOT hold anyone's budget or settle payments — it
# is a pure contention arbiter. Each buyer governs + settles its own purchases on
# its own side (examples/bazaar_room_buyer.lex), so every agent holds its own
# capability-bounded token and produces its own verifiable trail. That mirrors
# how a real agent marketplace works: the venue matches; the parties pay.
#
# Protocol (one line each):
#   buyer → "reserve <item_id>"   server → "OK <merchant> <pay_to> <price>" | "SOLD"
#   buyer → "release <item_id>"   server → "RELEASED"      (after a denied settle)
#
# Env: NB_PORT (default 8910)
# Run: lex run --allow-effects env,net,concurrent,io examples/bazaar_room.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.net" as net

import "std.conc" as conc

type Item = { id :: Int, merchant :: Str, pay_to :: Str, price :: Int, stock :: Int }

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
          { items: list.concat(a.items, [{ id: it.id, merchant: it.merchant, pay_to: it.pay_to, price: it.price, stock: it.stock - 1 }]), reply: str.join(["OK ", it.merchant, " ", it.pay_to, " ", int.to_str(it.price)], "") }
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

fn member_name(c :: WsConn) -> Str {
  str.concat("buyer:", c.id)
}

# parse the integer after the first space (e.g. "reserve 3" → 3)
fn arg_int(s :: Str) -> Int {
  let parts := str.split(str.trim(s), " ")
  match list.head(list.tail(parts)) {
    None => 0 - 1,
    Some(a) => match str.to_int(a) {
      Some(n) => n,
      None => 0 - 1,
    },
  }
}

fn run() -> [env, net, concurrent, io] Nil {
  let port := match env.get("NB_PORT") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 8910,
    },
    None => 8910,
  }
  let market := conc.spawn(inventory(), fn (items :: List[Item], c :: MCmd) -> (List[Item], Str) {
    market_step(items, c)
  })
  let __lex_discard_1 := io.print(str.join(["[room] bazaar contention arbiter on :", int.to_str(port), " — 5 scarce items, first to reserve wins"], ""))
  net.serve_ws_fn_actor(port, "", member_name, fn (c :: WsConn, m :: WsMessage) -> [concurrent, io] WsAction {
    match m {
      WsText(s) => {
        let t := str.trim(s)
        let reply :: Str := if str.starts_with(t, "reserve") {
          conc.ask(market, Take(arg_int(t)))
        } else {
          if str.starts_with(t, "release") {
            conc.ask(market, Release(arg_int(t)))
          } else {
            "?"
          }
        }
        let _l := io.print(str.join(["[room] ", c.id, ": ", t, " → ", reply], ""))
        WsSend(reply)
      },
      _ => WsNoOp,
    }
  })
}

