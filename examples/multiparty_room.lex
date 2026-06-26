# multi-party room probe — N agents in ONE conversation via net.serve_ws_fn_actor.
#
# Each WebSocket connection is registered as a named actor ("room:<id>") in the
# concurrency registry. When any agent sends a text frame, we enumerate every
# OTHER registered member (conc.registered) and push the frame into their socket
# (conc.lookup |> conc.tell). That's a multi-party broadcast room — >2 agents in
# one shared conversation — using only Lex std (no SLIM, no external broker).
#
# Run:  lex run --allow-effects net,concurrent,io src/room.lex run
# Then connect 3+ WebSocket clients to ws://localhost:8901 and watch each
# client's message fan out to all the others.

import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.net"  as net
import "std.conc" as conc

fn member_name(c :: WsConn) -> Str { str.concat("room:", c.id) }
fn is_member(name :: Str) -> Bool { str.starts_with(name, "room:") }

# Push `text` to every registered room member except `self_name`.
fn broadcast(self_name :: Str, text :: Str) -> [concurrent] Int {
  list.fold(conc.registered(), 0, fn (n :: Int, name :: Str) -> [concurrent] Int {
    if is_member(name) and name != self_name {
      match conc.lookup(name) {
        Some(peer) => { let _ := conc.tell(peer, text) n + 1 },
        None => n,
      }
    } else { n }
  })
}

fn on_message(c :: WsConn, m :: WsMessage) -> [concurrent, io] WsAction {
  match m {
    WsText(s) => {
      let frame := str.join(["[", c.id, "] ", s], "")
      let sent  := broadcast(member_name(c), frame)
      let _ := io.print(str.join(["room ← ", c.id, ": \"", s, "\"  (fan-out to ", int.to_str(sent), " peers)"], ""))
      WsSend(str.concat("ack: delivered to ", int.to_str(sent)))
    },
    WsClose => WsNoOp,
    _ => WsNoOp,
  }
}

fn run() -> [net, concurrent, io] Nil {
  let _ := io.print("[room] multi-party WS room on :8901 — connect N agents; every message broadcasts to all others")
  net.serve_ws_fn_actor(8901, "", member_name, on_message)
}
