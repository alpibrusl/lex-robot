# examples/nplayer_bazaar_bot.lex — a heuristic agent for the N-player Bazaar
# Draft referee (examples/nplayer_bazaar.lex). It dials the referee over
# WebSocket, joins a seat, and on every broadcast STATE that lands on its turn
# it drafts one affordable, unowned item. Everything but its own seat id is
# derived from the STATE string, so the bot is stateless apart from a tiny conc
# actor that remembers "which seat am I".
#
# Strategy (BOT_STRAT): 0 = greedy by raw value, 1 = greedy by value/price.
# Different bots with different strats make a free-for-all interesting.
#
# Env: NB_PORT (referee port, default 8902), BOT_STRAT (0|1, default 0)
# Run: BOT_STRAT=1 lex run --allow-effects env,net,concurrent,io examples/nplayer_bazaar_bot.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.net" as net

import "std.conc" as conc

import "std.tuple" as tup

fn budget() -> Int {
  30
}

# ── per-bot memory: just the server-assigned seat id ─────────────────────────
type Bot = { myid :: Str, strat :: Int }

# The actor takes a raw inbound line and returns the command to send next
# ("" = nothing). It learns its id from "YOU <id>", and on a STATE that is its
# turn it returns "draft <i>".
type Msg = Line(Str)

# pool entry "price/value/owner" → Entry
type Entry = { price :: Int, value :: Int, owner :: Str }

fn parse_entry(e :: Str) -> Entry {
  let parts := str.split(e, "/")
  { price: to_i(nth_str(parts, 0)), value: to_i(nth_str(parts, 1)), owner: nth_str(parts, 2) }
}

fn nth_str(xs :: List[Str], i :: Int) -> Str {
  let r := list.fold(xs, (0, ""), fn (acc :: (Int, Str), x :: Str) -> (Int, Str) {
    if tup.fst(acc) == i {
      (tup.fst(acc) + 1, x)
    } else {
      (tup.fst(acc) + 1, tup.snd(acc))
    }
  })
  tup.snd(r)
}

fn to_i(s :: Str) -> Int {
  match str.to_int(str.trim(s)) {
    Some(n) => n,
    None => 0,
  }
}

# pull the value of a "key=val" token out of the STATE line
fn field(s :: Str, key :: Str) -> Str {
  list.fold(str.split(s, " "), "", fn (acc :: Str, tok :: Str) -> Str {
    if str.starts_with(tok, key) {
      str.slice(tok, str.len(key), str.len(tok))
    } else {
      acc
    }
  })
}

# everything between the first '[' and the matching ']'
fn bracket(s :: Str, after :: Str) -> Str {
  let tail := snd_split(s, after)
  let inside := snd_split(tail, "[")
  list.fold(str.split(inside, "]"), "", fn (acc :: Str, seg :: Str) -> Str {
    if str.is_empty(acc) {
      seg
    } else {
      acc
    }
  })
}

fn snd_split(s :: Str, sep :: Str) -> Str {
  let parts := str.split(s, sep)
  if list.len(parts) >= 2 {
    nth_str(parts, 1)
  } else {
    s
  }
}

# Choose the best item index given the pool string + how much I've already spent.
# Returns -1 if nothing affordable/unowned.
type Pick = { idx :: Int, best_i :: Int, best_s :: Int }

fn choose(pool :: Str, my_spent :: Int, strat :: Int) -> Int {
  let entries := str.split(pool, ",")
  let r := list.fold(entries, { idx: 0, best_i: 0 - 1, best_s: 0 - 1 }, fn (acc :: Pick, e :: Str) -> Pick {
    let it := parse_entry(e)
    let affordable := str.is_empty(it.owner) and my_spent + it.price <= budget()
    let score := if strat == 1 {
      if it.price > 0 {
        it.value * 100 / it.price
      } else {
        it.value * 100
      }
    } else {
      it.value
    }
    if affordable and score > acc.best_s {
      { idx: acc.idx + 1, best_i: acc.idx, best_s: score }
    } else {
      { idx: acc.idx + 1, best_i: acc.best_i, best_s: acc.best_s }
    }
  })
  r.best_i
}

# how much have I spent = sum of prices of pool entries I own
fn my_spend(pool :: Str, myid :: Str) -> Int {
  list.fold(str.split(pool, ","), 0, fn (s :: Int, e :: Str) -> Int {
    let it := parse_entry(e)
    if it.owner == myid {
      s + it.price
    } else {
      s
    }
  })
}

# decide the next command for an inbound line, updating bot memory
fn decide(b :: Bot, line :: Str) -> (Bot, Str) {
  if str.starts_with(line, "YOU ") {
    ({ myid: str.trim(str.slice(line, 4, str.len(line))), strat: b.strat }, "")
  } else {
    if str.starts_with(line, "STATE") {
      let started := field(line, "started=") == "1"
      let over := field(line, "over=") == "1"
      let turn := field(line, "turn=")
      if not started or over or turn != b.myid or str.is_empty(b.myid) {
        (b, "")
      } else {
        let pool := bracket(line, "pool=")
        let i := choose(pool, my_spend(pool, b.myid), b.strat)
        if i >= 0 {
          (b, str.join(["draft ", int.to_str(i)], ""))
        } else {
          (b, "pass")
        }
      }
    } else {
      (b, "")
    }
  }
}

fn run() -> [env, net, concurrent, io] Nil {
  let port := match env.get("NB_PORT") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 8902,
    },
    None => 8902,
  }
  let strat := match env.get("BOT_STRAT") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 0,
    },
    None => 0,
  }
  let url := str.join(["ws://127.0.0.1:", int.to_str(port)], "")
  let mind := conc.spawn({ myid: "", strat: strat }, fn (b :: Bot, m :: Msg) -> (Bot, Str) {
    match m {
      Line(s) => decide(b, s),
    }
  })
  let __lex_discard_1 := io.print(str.join(["[bot] dialing ", url, " strat=", int.to_str(strat)], ""))
  let res := net.dial_ws(url, "", fn () -> [concurrent, io] WsAction {
    WsSend("join")
  }, fn (m :: WsMessage) -> [concurrent, io] WsAction {
    match m {
      WsText(s) => {
        let cmd := conc.ask(mind, Line(s))
        let __lex_discard_2 := io.print(str.join(["[bot] <- ", s, if str.is_empty(cmd) {
          ""
        } else {
          str.join(["  =>  ", cmd], "")
        }], ""))
        if str.is_empty(cmd) {
          WsNoOp
        } else {
          WsSend(cmd)
        }
      },
      _ => WsNoOp,
    }
  })
  match res {
    Ok(_) => io.print("[bot] closed"),
    Err(e) => io.print(str.join(["[bot] error: ", e], "")),
  }
}

