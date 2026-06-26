# examples/nplayer_bazaar.lex — N-player Bazaar Draft referee on the multi-party
# room substrate. Generalizes the 2-player Bazaar to N seats: N agents join over
# WebSocket, take turns drafting from a shared pool under a budget, and the
# highest total cart value wins. Shared game state lives in a conc actor (the
# referee); every state change broadcasts to all seated agents.
#
# Native: net.serve_ws_fn_actor (connections + broadcast) + conc.spawn (referee
# state). No external broker. (b) of the Governed Agent Bazaar epic (#45).
#
# Env: NB_SEATS (players to wait for, default 3), NB_PORT (default 8902)
# Run: NB_SEATS=3 lex run --allow-effects env,net,concurrent,io examples/nplayer_bazaar.lex run

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.net" as net

import "std.conc" as conc

import "std.tuple" as tup

# ── shared game state (held in the referee actor) ────────────────────────────
type Item = { price :: Int, value :: Int, owner :: Str }

# owner "" = unowned
type Game = { items :: List[Item], members :: List[Str], spent :: List[Int], turn :: Int, target :: Int, passes :: Int, started :: Bool, over :: Bool }

# Pass = a seat that can't (or won't) draft yields its turn. When every seat
# passes in a row the draft is over even if affordable-by-nobody items remain.
type Cmd = Join(Str) | Draft((Str, Int)) | Pass(Str)

fn budget() -> Int {
  30
}

fn new_game(target :: Int) -> Game {
  { items: [{ price: 10, value: 8, owner: "" }, { price: 15, value: 20, owner: "" }, { price: 8, value: 5, owner: "" }, { price: 20, value: 24, owner: "" }, { price: 12, value: 10, owner: "" }, { price: 18, value: 22, owner: "" }, { price: 6, value: 9, owner: "" }, { price: 25, value: 28, owner: "" }], members: [], spent: [], turn: 0, target: target, passes: 0, started: false, over: false }
}

fn seat_of(g :: Game, id :: Str) -> Int {
  let r := list.fold(g.members, (0, 0 - 1), fn (acc :: (Int, Int), m :: Str) -> (Int, Int) {
    let i := tup.fst(acc)
    if m == id {
      (i + 1, i)
    } else {
      (i + 1, tup.snd(acc))
    }
  })
  tup.snd(r)
}

fn nth_int(xs :: List[Int], i :: Int) -> Int {
  let r := list.fold(xs, (0, 0), fn (acc :: (Int, Int), v :: Int) -> (Int, Int) {
    if tup.fst(acc) == i {
      (tup.fst(acc) + 1, v)
    } else {
      (tup.fst(acc) + 1, tup.snd(acc))
    }
  })
  tup.snd(r)
}

fn nth_item(xs :: List[Item], i :: Int) -> Item {
  let r := list.fold(xs, (0, { price: 0, value: 0, owner: "?" }), fn (acc :: (Int, Item), v :: Item) -> (Int, Item) {
    if tup.fst(acc) == i {
      (tup.fst(acc) + 1, v)
    } else {
      (tup.fst(acc) + 1, tup.snd(acc))
    }
  })
  tup.snd(r)
}

fn set_nth_int(xs :: List[Int], i :: Int, v :: Int) -> List[Int] {
  let r := list.fold(xs, (0, []), fn (acc :: (Int, List[Int]), x :: Int) -> (Int, List[Int]) {
    (tup.fst(acc) + 1, list.concat(tup.snd(acc), [if tup.fst(acc) == i {
      v
    } else {
      x
    }]))
  })
  tup.snd(r)
}

fn set_owner(items :: List[Item], i :: Int, owner :: Str) -> List[Item] {
  let r := list.fold(items, (0, []), fn (acc :: (Int, List[Item]), it :: Item) -> (Int, List[Item]) {
    let nit := if tup.fst(acc) == i {
      { price: it.price, value: it.value, owner: owner }
    } else {
      it
    }
    (tup.fst(acc) + 1, list.concat(tup.snd(acc), [nit]))
  })
  tup.snd(r)
}

fn any_unowned(items :: List[Item]) -> Bool {
  list.fold(items, false, fn (a :: Bool, it :: Item) -> Bool {
    a or str.is_empty(it.owner)
  })
}

# A compact snapshot the bots/clients parse: turn seat, pool, each seat's score.
fn snapshot(g :: Game) -> Str {
  let pool := list.fold(g.items, "", fn (acc :: Str, it :: Item) -> Str {
    str.join([acc, if str.is_empty(acc) {
      ""
    } else {
      ","
    }, int.to_str(it.price), "/", int.to_str(it.value), "/", it.owner], "")
  })
  let scores := list.fold(g.members, "", fn (acc :: Str, m :: Str) -> Str {
    let mine := list.fold(g.items, 0, fn (s :: Int, it :: Item) -> Int {
      if it.owner == m {
        s + it.value
      } else {
        s
      }
    })
    str.join([acc, if str.is_empty(acc) {
      ""
    } else {
      ","
    }, m, ":", int.to_str(mine)], "")
  })
  let turn_id := if g.turn >= 0 and g.turn < list.len(g.members) {
    tup.fst(list.fold(g.members, ("", 0), fn (acc :: (Str, Int), m :: Str) -> (Str, Int) {
      if tup.snd(acc) == g.turn {
        (m, tup.snd(acc) + 1)
      } else {
        (tup.fst(acc), tup.snd(acc) + 1)
      }
    }))
  } else {
    ""
  }
  str.join(["STATE started=", if g.started {
    "1"
  } else {
    "0"
  }, " over=", if g.over {
    "1"
  } else {
    "0"
  }, " turn=", turn_id, " pool=[", pool, "] scores=[", scores, "]"], "")
}

# Referee transition: (state, cmd) -> (state, reply-snapshot)
fn step(g :: Game, c :: Cmd) -> (Game, Str) {
  match c {
    Join(id) => if g.started or list.len(g.members) >= g.target {
      (g, snapshot(g))
    } else {
      let members2 := list.concat(g.members, [id])
      let spent2 := list.concat(g.spent, [0])
      let started2 := list.len(members2) >= g.target
      let g2 := { items: g.items, members: members2, spent: spent2, turn: 0, target: g.target, passes: 0, started: started2, over: false }
      (g2, snapshot(g2))
    },
    Draft(id, i) => {
      let seat := seat_of(g, id)
      let on_turn := g.started and not g.over and seat >= 0 and seat == g.turn
      let valid_i := i >= 0 and i < list.len(g.items)
      if not on_turn or not valid_i {
        (g, snapshot(g))
      } else {
        let it := nth_item(g.items, i)
        let cur_spent := nth_int(g.spent, seat)
        if not str.is_empty(it.owner) or cur_spent + it.price > budget() {
          (g, snapshot(g))
        } else {
          let items2 := set_owner(g.items, i, id)
          let spent2 := set_nth_int(g.spent, seat, cur_spent + it.price)
          let next := mod_int(g.turn + 1, list.len(g.members))
          let over2 := not any_unowned(items2)
          let g2 := { items: items2, members: g.members, spent: spent2, turn: next, target: g.target, passes: 0, started: true, over: over2 }
          (g2, snapshot(g2))
        }
      }
    },
    Pass(id) => {
      let seat := seat_of(g, id)
      let on_turn := g.started and not g.over and seat >= 0 and seat == g.turn
      if not on_turn {
        (g, snapshot(g))
      } else {
        let next := mod_int(g.turn + 1, list.len(g.members))
        let passes := g.passes + 1
        let over2 := passes >= list.len(g.members) or not any_unowned(g.items)
        let g2 := { items: g.items, members: g.members, spent: g.spent, turn: next, target: g.target, passes: passes, started: true, over: over2 }
        (g2, snapshot(g2))
      }
    },
  }
}

fn mod_int(a :: Int, m :: Int) -> Int {
  if m <= 0 {
    0
  } else {
    a - a / m * m
  }
}

# ── broadcast snapshot to all seated members ─────────────────────────────────
fn broadcast(snap :: Str) -> [concurrent] Int {
  list.fold(conc.registered(), 0, fn (n :: Int, name :: Str) -> [concurrent] Int {
    if str.starts_with(name, "nb:") {
      match conc.lookup(name) {
        Some(p) => {
          let __lex_discard_1 := conc.tell(p, snap)
          n + 1
        },
        None => n,
      }
    } else {
      n
    }
  })
}

fn member_name(c :: WsConn) -> Str {
  str.concat("nb:", c.id)
}

# parse "draft <i>" / "join"
fn parse_idx(s :: Str) -> Int {
  match str.to_int(str.trim(list.fold(str.split(s, " "), "", fn (_a :: Str, seg :: Str) -> Str {
    seg
  }))) {
    Some(n) => n,
    None => 0 - 1,
  }
}

fn run() -> [env, net, concurrent, io] Nil {
  let seats := match env.get("NB_SEATS") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 3,
    },
    None => 3,
  }
  let port := match env.get("NB_PORT") {
    Some(v) => match str.to_int(v) {
      Some(n) => n,
      None => 8902,
    },
    None => 8902,
  }
  let ref := conc.spawn(new_game(seats), fn (g :: Game, c :: Cmd) -> (Game, Str) {
    step(g, c)
  })
  let __lex_discard_2 := io.print(str.join(["[bazaar] N-player draft referee on :", int.to_str(port), " — waiting for ", int.to_str(seats), " seats"], ""))
  net.serve_ws_fn_actor(port, "", member_name, fn (c :: WsConn, m :: WsMessage) -> [concurrent, io] WsAction {
    match m {
      WsText(s) => {
        let t := str.trim(s)
        let is_join := str.starts_with(t, "join")
        let cmd := if is_join {
          Join(c.id)
        } else {
          if str.starts_with(t, "pass") {
            Pass(c.id)
          } else {
            Draft(c.id, parse_idx(s))
          }
        }
        let snap := conc.ask(ref, cmd)
        let __lex_discard_3 := broadcast(snap)
        let __lex_discard_4 := io.print(str.join(["[bazaar] ", c.id, " ", s, " → ", snap], ""))
        if is_join {
          WsSend(str.join(["YOU ", c.id], ""))
        } else {
          WsSend(snap)
        }
      },
      _ => WsNoOp,
    }
  })
}

