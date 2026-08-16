#!/usr/bin/env python3
"""ha_sidecar — the house's appliances as governed lex-robot skills.

One sidecar makes every Home Assistant device a grant-gated skill: HA already
normalizes TVs, washers, plugs, and chargers into entities behind one LOCAL
REST API with a token, so this is a single adapter instead of one sidecar per
appliance brand. The lex side gates each command with the same Grant
machinery that gates an arm reach — an appliance command is an actuation
with real-world costs (water, heat, energy cents), and "may this program
start the washer, at this tariff?" becomes a typed, auditable, refusable
question.

Skills (POST /skill/<name>, same protocol as every lex-robot sidecar):

    read_state   {"entity": "..."}          -> {"entity","state","detail"?}
    read_tariff  {"at": "HH:MM"?}           -> {"price_cents_kwh": N, "period":
                                                "peak|flat|valley", "at": "HH:MM"}
    appliance_start {"entity": "..."}       -> outcome
    appliance_stop  {"entity": "..."}       -> outcome

Money/price convention: INTEGER cents per kWh (lex-os: never floats in a
budget). The tariff shape follows the Spanish PVPC three-period day —
valley (cheap, overnight), flat, peak (expensive, midday + evening) — the
stub schedule is a caricature of it, and the real mode reads whatever your
tariff sensor publishes.

Out of the box it runs as a **stub house** (stdlib only, no HA): one washer
(`washer.main`, idle), one TV (`tv.livingroom`, off), and the caricature
tariff. Deterministic for CI: "now" is LEX_HA_STUB_NOW (default "13:00" —
peak, so the wash demo's refusal is reproducible).

Real mode — set both:
    LEX_HA_URL     e.g. http://homeassistant.local:8123
    LEX_HA_TOKEN   a long-lived access token (HA profile -> security)
and the sidecar answers from the real house:
    read_state       GET  /api/states/<entity>
    appliance_start  POST /api/services/<domain>/<service> {"entity_id": ...}
                     service from LEX_HA_START_SERVICE (default
                     "switch.turn_on") — appliance service names vary by
                     integration (a SmartThings washer differs from a smart
                     plug), so this is configuration, not code.
    appliance_stop   LEX_HA_STOP_SERVICE (default "switch.turn_off")
    read_tariff      the state of LEX_HA_TARIFF_ENTITY (e.g. a PVPC or
                     Nordpool sensor), read as EUR/kWh and converted to
                     integer cents. Asking for a future "at" is answered
                     honestly as unsupported in real mode — forecasting
                     needs the sensor's forecast attributes, not implemented.

Trust: same localhost posture as every lex-robot sidecar; the HA token grants
whatever HA grants it — scope it to the entities you mean to govern.
"""

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))

HA_URL = os.environ.get("LEX_HA_URL", "").rstrip("/")
HA_TOKEN = os.environ.get("LEX_HA_TOKEN", "")
USE_HA = bool(HA_URL and HA_TOKEN)
START_SERVICE = os.environ.get("LEX_HA_START_SERVICE", "switch.turn_on")
STOP_SERVICE = os.environ.get("LEX_HA_STOP_SERVICE", "switch.turn_off")
TARIFF_ENTITY = os.environ.get("LEX_HA_TARIFF_ENTITY", "")
STUB_NOW = os.environ.get("LEX_HA_STUB_NOW", "13:00")

# Stub tariff: a caricature of the Spanish PVPC three-period day, integer
# cents/kWh. Hour -> (price, period).
def _stub_tariff(hour):
    if 0 <= hour < 8:
        return 11, "valley"
    if 10 <= hour < 14 or 18 <= hour < 22:
        return 32, "peak"
    return 19, "flat"


class StubHouse:
    def __init__(self):
        self.entities = {
            "washer.main": "idle",
            "tv.livingroom": "off",
        }

    def read_state(self, entity):
        if entity not in self.entities:
            return {"entity": entity, "state": "",
                    "detail": f"(stub) unknown entity '{entity}' (stub house has: "
                              f"{', '.join(sorted(self.entities))})"}
        return {"entity": entity, "state": self.entities[entity], "detail": "(stub house)"}

    def read_tariff(self, at):
        at = at or STUB_NOW
        try:
            hour = int(str(at).split(":", 1)[0]) % 24
        except ValueError:
            return {"error": f"bad time '{at}' (use HH:MM)"}
        price, period = _stub_tariff(hour)
        return {"price_cents_kwh": price, "period": period, "at": f"{hour:02d}:00"}

    def _set(self, entity, running, verb):
        if entity not in self.entities:
            return {"outcome": "stalled",
                    "detail": f"(stub) unknown entity '{entity}'"}
        self.entities[entity] = "running" if running else ("idle" if entity.startswith("washer") else "off")
        return {"outcome": "reached", "detail": f"(stub) {entity} {verb}"}

    def start(self, entity):
        return self._set(entity, True, "started")

    def stop(self, entity):
        return self._set(entity, False, "stopped")


class RealHouse:
    """The same skills against a live Home Assistant. Errors are passed
    through honestly — an unreachable HA is a stalled outcome with the
    reason, never a fabricated success."""

    def _req(self, method, path, body=None):
        req = urllib.request.Request(
            f"{HA_URL}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {HA_TOKEN}",
                     "Content-Type": "application/json"},
            method=method)
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read() or b"{}")

    def read_state(self, entity):
        try:
            out = self._req("GET", f"/api/states/{entity}")
        except Exception as e:
            return {"entity": entity, "state": "", "detail": f"HA unreachable: {e}"}
        return {"entity": entity, "state": str(out.get("state", "")),
                "detail": f"HA @ {HA_URL}"}

    def read_tariff(self, at):
        if not TARIFF_ENTITY:
            return {"error": "no LEX_HA_TARIFF_ENTITY configured — real-mode tariff "
                             "needs a price sensor (e.g. PVPC/Nordpool)"}
        if at:
            return {"error": "future-tariff lookup not implemented in real mode — "
                             "needs the sensor's forecast attributes; only 'now' is read"}
        try:
            out = self._req("GET", f"/api/states/{TARIFF_ENTITY}")
            eur_kwh = float(out.get("state"))
        except Exception as e:
            return {"error": f"tariff sensor unreadable: {e}"}
        return {"price_cents_kwh": round(eur_kwh * 100), "period": "live", "at": "now"}

    def _call_service(self, service, entity, verb):
        domain, _, name = service.partition(".")
        try:
            self._req("POST", f"/api/services/{domain}/{name}", {"entity_id": entity})
        except Exception as e:
            return {"outcome": "stalled", "detail": f"HA service {service} failed: {e}"}
        return {"outcome": "reached", "detail": f"{entity} {verb} via {service}"}

    def start(self, entity):
        return self._call_service(START_SERVICE, entity, "started")

    def stop(self, entity):
        return self._call_service(STOP_SERVICE, entity, "stopped")


HOUSE = RealHouse() if USE_HA else StubHouse()


def handle_skill(name, args):
    if name == "read_state":
        return HOUSE.read_state(args.get("entity", ""))
    if name == "read_tariff":
        return HOUSE.read_tariff(args.get("at", ""))
    if name == "appliance_start":
        entity = args.get("entity", "")
        if not entity:
            return {"outcome": "stalled", "detail": "appliance_start needs an entity"}
        return HOUSE.start(entity)
    if name == "appliance_stop":
        entity = args.get("entity", "")
        if not entity:
            return {"outcome": "stalled", "detail": "appliance_stop needs an entity"}
        return HOUSE.stop(entity)
    return {"error": f"unknown skill: {name}"}


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/health":
            return self._json(200, {"ok": True, "ha": USE_HA,
                                    "mode": "home-assistant" if USE_HA else "stub house"})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        try:
            args = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "invalid json"})
        if self.path.startswith("/skill/"):
            return self._json(200, handle_skill(self.path[len("/skill/"):], args))
        return self._json(404, {"error": "not found"})

    def log_message(self, *a):
        print("[ha]", self.command, self.path)


def main():
    mode = f"HOME ASSISTANT @ {HA_URL}" if USE_HA else "stub house (no HA)"
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot HA sidecar [{mode}] on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
