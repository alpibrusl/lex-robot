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

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("LEX_ROBOT_SIDECAR_HOST", "127.0.0.1")
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))


def make_handler(handle_skill, *, tag, health=None, get_route=None, post_route=None, lock=None):
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


def serve(handle_skill, *, tag, banner, health=None, get_route=None, post_route=None, lock=None, host=None, port=None):
    """Run the sidecar server until Ctrl-C."""
    host = HOST if host is None else host
    port = PORT if port is None else port
    handler = make_handler(handle_skill, tag=tag, health=health,
                           get_route=get_route, post_route=post_route, lock=lock)
    srv = ThreadingHTTPServer((host, port), handler)
    print(f"{banner} on http://{host}:{port}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
