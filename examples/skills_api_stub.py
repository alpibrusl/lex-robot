#!/usr/bin/env python3
"""examples/skills_api_stub.py — a Tier-1 STUB backing every network-backed
skill in examples/skill_library.lex, same shape as this repo's other Tier-1
hardware stubs (sidecar/xlerobot_sidecar.py): no real dependency,
deterministic, clearly labeled as a stand-in.

Each endpoint here is a stand-in for a specific real public API a real
deployment would call instead (noted per endpoint below). This sandbox's
egress policy blocks the real hosts outright (confirmed against
nominatim.openstreetmap.org — see examples/skill_acquisition_demo.lex's
module comment); every tool body in skill_library.lex is otherwise
unchanged from what it would be against the real API — swapping the base
URL is the only change a real deployment needs.

Endpoints:
  GET /geocode/search?q=<place>          stand-in for Nominatim /search
  GET /geocode/reverse?lat=&lon=          stand-in for Nominatim /reverse
  GET /route/eta?from=&to=                stand-in for a directions/distance-matrix API
  GET /price/lookup?item=                 stand-in for a market-price API
  GET /currency/rate?from=&to=            stand-in for an FX-rate API
  GET /weather?place=                     stand-in for a weather API
  GET /search?q=                          stand-in for a web-search API
  GET /translate?text=&to=                stand-in for a translation API
  GET /calendar/lookup?query=             stand-in for a calendar API
  GET /health

Deps: none (stdlib only). Run: python3 examples/skills_api_stub.py [port]
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

ROUTES = {
    ("eiffel tower", "madrid, spain"): {"distance_km": "1053.0", "eta_min": "630"},
    ("eiffel tower", "statue of liberty"): {"distance_km": "5837.0", "eta_min": "2160"},
    ("madrid, spain", "statue of liberty"): {"distance_km": "5765.0", "eta_min": "2100"},
}

PRICES = {
    "coffee": {"currency": "EUR", "price": "3.50"},
    "bread": {"currency": "EUR", "price": "2.00"},
    "solar panel": {"currency": "EUR", "price": "150.00"},
    "spice jar": {"currency": "EUR", "price": "6.00"},
}

FX_RATES = {
    ("EUR", "USD"): "1.08",
    ("USD", "EUR"): "0.93",
    ("EUR", "GBP"): "0.85",
    ("GBP", "EUR"): "1.18",
}

WEATHER = {
    "eiffel tower": {"condition": "cloudy", "temp_c": "16"},
    "madrid, spain": {"condition": "sunny", "temp_c": "28"},
    "statue of liberty": {"condition": "rainy", "temp_c": "19"},
}

KNOWLEDGE = {
    "boiling point of water": "100 degrees Celsius at sea-level atmospheric pressure.",
    "capital of spain": "Madrid.",
    "speed of light": "approximately 299,792 kilometers per second.",
}

TRANSLATIONS = {
    ("hello", "es"): "hola",
    ("hello", "fr"): "bonjour",
    ("thank you", "es"): "gracias",
    ("thank you", "fr"): "merci",
}

CALENDAR = {
    "today afternoon": {"busy": True, "note": "cleaning scheduled 14:00-16:00"},
    "tomorrow morning": {"busy": False, "note": "no events"},
}


def _reverse_lookup(lat, lon):
    for name, entry in GAZETTEER.items():
        if entry["lat"] == lat and entry["lon"] == lon:
            return entry["display_name"]
    return None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        def p(name, default=""):
            return params.get(name, [default])[0].strip()

        if path == "/health":
            self._json(200, {"status": "ok"})
        elif path == "/geocode/search":
            q = p("q").lower()
            hit = GAZETTEER.get(q)
            self._json(200, [hit] if hit else [])
        elif path == "/geocode/reverse":
            name = _reverse_lookup(p("lat"), p("lon"))
            self._json(200, {"display_name": name} if name else {})
        elif path == "/route/eta":
            key = (p("from").lower(), p("to").lower())
            hit = ROUTES.get(key) or ROUTES.get((key[1], key[0]))
            self._json(200, hit if hit else {})
        elif path == "/price/lookup":
            hit = PRICES.get(p("item").lower())
            self._json(200, {"item": p("item"), **hit} if hit else {})
        elif path == "/currency/rate":
            hit = FX_RATES.get((p("from").upper(), p("to").upper()))
            self._json(200, {"rate": hit} if hit else {})
        elif path == "/weather":
            hit = WEATHER.get(p("place").lower())
            self._json(200, {"place": p("place"), **hit} if hit else {})
        elif path == "/search":
            hit = KNOWLEDGE.get(p("q").lower())
            self._json(200, {"query": p("q"), "snippet": hit} if hit else {})
        elif path == "/translate":
            hit = TRANSLATIONS.get((p("text").lower(), p("to").lower()))
            self._json(200, {"translated": hit} if hit else {})
        elif path == "/calendar/lookup":
            hit = CALENDAR.get(p("query").lower())
            self._json(200, hit if hit else {})
        else:
            self._json(404, {"error": "not found"})

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8930
    print(f"[skills_api_stub] listening on :{port}")
    http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
