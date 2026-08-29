#!/usr/bin/env python3
"""A mock Home Assistant, so the ha_sidecar's REAL mode is testable with no house.

`ha_sidecar.py` has two paths: `StubHouse` (no HA, exercised everywhere) and
`RealHouse` (the actual REST client, exercised nowhere until now). The real
path is where the interesting bugs are — it is the one that talks to a network
service, maps HTTP outcomes onto `t.Outcome`, and carries the token. This
serves the only two endpoints `RealHouse` calls, so that path can be driven in
CI on a machine with no Home Assistant anywhere:

    GET  /api/states/<entity>              -> the entity, or 404
    POST /api/services/<domain>/<service>  -> [] , or 400 for an unknown service

Fidelity that matters (issue #198): real HA accepts a well-formed service call
whose `entity_id` belongs to a DIFFERENT domain, answers 200, and applies it to
nothing. `switch.turn_on` on a `vacuum.*` entity is not an error to HA — it is
a no-op. That asymmetry is the whole reason the sidecar could report `reached`
for a vacuum that never moved, so this mock reproduces it exactly rather than
returning a tidy error the real thing would not return.

Not fidelity, deliberately: no websocket, no auth flow beyond the bearer token,
no entity registry, no state machine beyond what the tests assert on. This is a
test double for one client, not a Home Assistant.

    python3 sidecar/mock_ha.py [port]     # standalone, port 8123 by default
    from mock_ha import MockHA            # as a context manager, in tests
"""

import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "mock-long-lived-token"

# Services this mock knows, by domain. An unknown service 400s, as HA does.
KNOWN_SERVICES = {
    "vacuum": {"start", "stop", "pause", "return_to_base", "locate"},
    "switch": {"turn_on", "turn_off"},
    "media_player": {"turn_on", "turn_off", "play_media"},
    # The generic domain, whose services deliberately act on any entity.
    "homeassistant": {"turn_on", "turn_off"},
}

# What a service call does to an entity's state, when domain and entity agree.
# These are Home Assistant's own state strings: a switch and a media_player are
# `on`/`off`, and a vacuum has its own vocabulary. Getting these right matters
# now that the sidecar verifies an actuation by reading the state back.
_EFFECT = {
    "start": "cleaning", "return_to_base": "returning", "stop": "idle",
    "pause": "paused", "turn_on": "on", "turn_off": "off",
}


# Entities that accept every service call and change nothing — HA answers 200,
# the appliance ignores it. This is not an edge case invented for a test: it is
# what a Samsung TV without Wake-on-LAN does to `media_player.turn_on`, and what
# a Samsung washer whose Remote Start is not armed does to a start. Both are
# same-domain calls, so the domain guard cannot see them; only reading the state
# back can. See issue #198.
DEAF_ENTITIES = {"vacuum.deaf", "media_player.no_wol"}


def default_states():
    return {
        "vacuum.xiaomi_s10": {"state": "docked", "attributes": {
            "battery_level": 100, "fan_speed": "balanced",
            "friendly_name": "Xiaomi S10"}},
        "vacuum.deaf": {"state": "docked", "attributes": {
            "friendly_name": "Accepts every call, does nothing"}},
        "media_player.no_wol": {"state": "off", "attributes": {
            "friendly_name": "Cannot be woken over the network"}},
        "switch.washer": {"state": "off", "attributes": {}},
        "sensor.pvpc": {"state": "0.11", "attributes": {}},
    }


def _make_handler(states, calls):
    class Handler(BaseHTTPRequestHandler):
        def _auth(self):
            if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                return self._json({"message": "Unauthorized"}, 401) or False
            return True

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return None

        def do_GET(self):
            if not self._auth():
                return
            if self.path.startswith("/api/states/"):
                entity = self.path[len("/api/states/"):]
                if entity not in states:
                    return self._json({"message": "Entity not found."}, 404)
                return self._json({"entity_id": entity, **states[entity]})
            self._json({"message": "not found"}, 404)

        def do_POST(self):
            if not self._auth():
                return
            if not self.path.startswith("/api/services/"):
                return self._json({"message": "not found"}, 404)
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            domain, _, service = self.path[len("/api/services/"):].partition("/")
            entity = body.get("entity_id", "")
            calls.append({"service": f"{domain}.{service}", "entity_id": entity})
            if service not in KNOWN_SERVICES.get(domain, ()):
                return self._json(
                    {"message": f"Service {domain}.{service} not found."}, 400)
            # The case this mock exists for: valid service, wrong domain for the
            # entity. HA says 200 and does nothing. See the module docstring.
            if entity and not entity.startswith(domain + "."):
                return self._json([])
            if (entity in states and service in _EFFECT
                    and entity not in DEAF_ENTITIES):
                states[entity]["state"] = _EFFECT[service]
            return self._json([])

        def log_message(self, *args):
            pass

    return Handler


class MockHA:
    """A running mock HA on a free port. `url` is what LEX_HA_URL wants.

    `states` and `calls` are live — a test reads `states` to assert what the
    house actually did, and `calls` to assert what the sidecar actually sent.
    Those are different questions, and the bug in #198 is exactly a case where
    a call was sent and the state did not change.
    """

    def __init__(self, states=None):
        self.states = default_states() if states is None else states
        self.calls = []
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}"
        self._srv = None

    def __enter__(self):
        self._srv = ThreadingHTTPServer(
            ("127.0.0.1", self.port), _make_handler(self.states, self.calls))
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        if self._srv:
            self._srv.shutdown()
            self._srv.server_close()

    def state_of(self, entity):
        return self.states[entity]["state"]


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8123
    states, calls = default_states(), []
    print(f"mock HA on http://127.0.0.1:{port}  (token: {TOKEN})")
    ThreadingHTTPServer(("127.0.0.1", port), _make_handler(states, calls)).serve_forever()
