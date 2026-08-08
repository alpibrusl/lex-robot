#!/usr/bin/env python3
"""examples/geocode_stub.py — a Tier-1 STUB geocoding service, same shape as
this repo's other Tier-1 hardware stubs (sidecar/xlerobot_sidecar.py): no
real dependency, deterministic, clearly labeled as a stand-in.

Serves GET /search?q=<place> -> Nominatim-shaped JSON (a JSON array of
{lat, lon, display_name}), so the tool body registered against it in
examples/skill_acquisition_demo.lex is IDENTICAL to what would run against
the real https://nominatim.openstreetmap.org/search in an environment whose
egress policy allows it (this sandbox's proxy blocks that host — see the
demo's own comment). Swapping the stub's URL for the real one is the only
change a real deployment needs.

Deps: none (stdlib only). Run: python3 examples/geocode_stub.py [port]
"""

import http.server
import json
import sys
from urllib.parse import urlparse, parse_qs

GAZETTEER = {
    "eiffel tower": {"lat": "48.8584", "lon": "2.2945", "display_name": "Tour Eiffel, Paris, France"},
    "statue of liberty": {"lat": "40.6892", "lon": "-74.0445", "display_name": "Statue of Liberty, New York, USA"},
    "madrid, spain": {"lat": "40.4168", "lon": "-3.7038", "display_name": "Madrid, Spain"},
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._json(200, {"status": "ok"})
            return
        if parsed.path != "/search":
            self._json(404, {"error": "not found"})
            return
        q = parse_qs(parsed.query).get("q", [""])[0].strip().lower()
        hit = GAZETTEER.get(q)
        results = [hit] if hit else []
        self._json(200, results)

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8930
    print(f"[geocode_stub] listening on :{port} — known places: {list(GAZETTEER)}")
    http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
