# stream_demo — the /stream WebSocket state channel, closed out of SIDECAR.md's
# "not in v1" list: the sidecar pushes joint + base state as text frames at
# LEX_STREAM_HZ, and Lex consumes them with net.dial_ws — no polling loop, no
# per-reading HTTP request.
#
# Lifetime honesty: a dial_ws handler's WsAction (WsSend / WsSendBinary /
# WsNoOp) cannot hang up, so a bounded stream ends from the SERVER side —
# the demo runs with LEX_STREAM_MAX_FRAMES=3 and the sidecar closes after
# the third frame; dial_ws then returns Ok. A monitoring program runs
# unbounded (max frames 0) and receives until the robot goes away.
#
# Streaming is SENSING: the channel carries state out and nothing in — the
# only frames this client ever sends are the protocol's own close/pong.
#
# Run it:  bash scripts/demo.sh stream

import "std.io" as io

import "std.str" as str

import "std.net" as net

fn on_open() -> [io] WsAction {
  let __p := io.print("stream opened")
  WsNoOp
}

fn on_frame(m :: WsMessage) -> [io] WsAction {
  match m {
    WsText(frame) => {
      let __p := io.print(str.concat("stream frame: ", frame))
      WsNoOp
    },
    WsPing => WsNoOp,
    WsBinary(_) => WsNoOp,
    WsClose => WsNoOp,
  }
}

fn run() -> [net, io] Unit {
  match net.dial_ws("ws://127.0.0.1:8900/stream", "", on_open, on_frame) {
    Ok(_) => io.print("stream closed cleanly (server-bounded)"),
    Err(e) => io.print(str.concat("stream failed: ", e)),
  }
}

