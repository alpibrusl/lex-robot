#!/usr/bin/env python3
"""sidecar_lib — the shared HTTP skeleton every lex-robot sidecar re-implements.

Every sidecar speaks the same protocol (SIDECAR.md): JSON over localhost HTTP,
`GET /health` for liveness, `POST /skill/<name>` dispatching into a
`handle_skill(name, args) -> dict` function. Until now each sidecar hand-rolled
the same ~40 lines of BaseHTTPRequestHandler around that; this module is that
skeleton, once. Stdlib only, like the sidecars it serves.

Usage:

    from sidecar_lib import serve

    def handle_skill(name, args):
        ...

    serve(handle_skill, tag="depot", banner="lex-robot depot sidecar")

Extension points cover what the non-trivial sidecars need beyond /skill:

    health()            -> dict merged into the /health payload (after {"ok": True})
    get_route(path)     -> (code, payload) or None for extra GET endpoints
    post_route(path, a) -> (code, payload) or None, consulted BEFORE /skill/
    lock                -> a threading.Lock held around every POST dispatch
                           (for sidecars whose skill handlers share mutable state
                           and want request serialization, e.g. the depot)

The big dashboard-embedding sidecars (sim_sidecar, xlerobot_sidecar) still
carry their own handlers — their HTML/event surface is most of their code, and
migrating them is a follow-up, not a blocker for the smaller ones.
"""

import base64
import hashlib
import json
import os
import select
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("LEX_ROBOT_SIDECAR_HOST", "127.0.0.1")
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))

# ── /stream — the WebSocket state channel (SIDECAR.md's streaming add-on) ────
# Minimal RFC 6455 server half, stdlib-only like everything else here. The
# stream is send-mostly: json(sample()) as a text frame at `hz`, answering
# client pings and stopping cleanly on a client close frame. Consumed from
# Lex via net.dial_ws — see examples/stream_demo.lex.

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _ws_send_frame(sock, opcode, payload=b""):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + struct.pack(">H", n)
    else:
        header += bytes([127]) + struct.pack(">Q", n)
    sock.sendall(header + payload)


def _ws_read_frame(sock):
    """Read one client frame (always masked per RFC 6455); return (opcode, payload)."""
    head = sock.recv(2)
    if len(head) < 2:
        return 0x8, b""
    opcode = head[0] & 0x0F
    length = head[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", sock.recv(8))[0]
    mask = sock.recv(4)
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            break
        payload += chunk
    return opcode, bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def maybe_stream(handler, sample, hz=10.0, max_frames=0):
    """If `handler`'s current request is a WebSocket upgrade, take the socket
    over: complete the handshake, then send json(sample()) at `hz` until the
    client closes, the socket dies, or `max_frames` frames have been sent
    (0 = unbounded; a bounded stream ends with a server-initiated close —
    the WsAction a Lex dial_ws handler returns cannot hang up, so bounding
    happens HERE). Returns True when the request was handled as a stream,
    False when it wasn't a WebSocket upgrade."""
    if handler.headers.get("Upgrade", "").lower() != "websocket":
        return False
    key = handler.headers.get("Sec-WebSocket-Key", "")
    if not key:
        return False
    accept = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode()).digest()).decode()
    # Raw response line: BaseHTTPRequestHandler stamps HTTP/1.0 on
    # send_response, and WebSocket clients (rightly) reject a 101 below 1.1.
    handler.wfile.write(
        b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Accept: " + accept.encode() + b"\r\n\r\n")
    handler.wfile.flush()
    handler.close_connection = True
    sock = handler.connection
    sent = 0
    try:
        while True:
            _ws_send_frame(sock, 0x1, json.dumps(sample()).encode())
            sent += 1
            if max_frames and sent >= max_frames:
                _ws_send_frame(sock, 0x8)  # server-initiated close
                _ws_read_frame(sock)       # wait for the client's close echo
                return True
            deadline = time.time() + 1.0 / hz
            while True:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                readable, _, _ = select.select([sock], [], [], remaining)
                if not readable:
                    break
                opcode, payload = _ws_read_frame(sock)
                if opcode == 0x8:  # close: echo it and stop
                    _ws_send_frame(sock, 0x8, payload[:2])
                    return True
                if opcode == 0x9:  # ping → pong
                    _ws_send_frame(sock, 0xA, payload)
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass
    return True


def make_handler(handle_skill, *, tag, health=None, get_route=None, post_route=None, lock=None, stream_source=None, stream_hz=10.0):
    """Build the request-handler class around `handle_skill`."""

    class Handler(BaseHTTPRequestHandler):
        def _json(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if stream_source is not None and path == "/stream":
                if maybe_stream(self, stream_source, hz=stream_hz):
                    return
                return self._json(400, {"error": "/stream requires a WebSocket upgrade"})
            if path == "/health":
                payload = {"ok": True}
                if health is not None:
                    payload.update(health())
                return self._json(200, payload)
            if get_route is not None:
                hit = get_route(path)
                if hit is not None:
                    code, payload = hit
                    return self._json(code, payload)
            return self._json(404, {"error": "not found"})

        def do_POST(self):
            n = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(n) if n else b"{}"
            try:
                args = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return self._json(400, {"error": "invalid json"})

            def dispatch():
                if post_route is not None:
                    hit = post_route(self.path, args)
                    if hit is not None:
                        return hit
                if self.path.startswith("/skill/"):
                    return 200, handle_skill(self.path[len("/skill/"):], args)
                return 404, {"error": "not found"}

            if lock is not None:
                with lock:
                    code, payload = dispatch()
            else:
                code, payload = dispatch()
            return self._json(code, payload)

        def log_message(self, *a):
            print(f"[{tag}]", self.command, self.path)

    return Handler


def serve(handle_skill, *, tag, banner, health=None, get_route=None, post_route=None, lock=None, host=None, port=None, stream_source=None, stream_hz=10.0):
    """Run the sidecar server until Ctrl-C."""
    host = HOST if host is None else host
    port = PORT if port is None else port
    handler = make_handler(handle_skill, tag=tag, health=health,
                           get_route=get_route, post_route=post_route, lock=lock,
                           stream_source=stream_source, stream_hz=stream_hz)
    srv = ThreadingHTTPServer((host, port), handler)
    print(f"{banner} on http://{host}:{port}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
