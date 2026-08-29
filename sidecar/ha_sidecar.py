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
                     service derived from the ENTITY'S OWN DOMAIN (see
                     DOMAIN_SERVICES) — a vacuum is started by vacuum.start,
                     a smart plug by switch.turn_on, and one sidecar drives
                     both. LEX_HA_START_SERVICE overrides it for an appliance
                     whose integration wants a service we do not know.
    appliance_stop   the same, via LEX_HA_STOP_SERVICE.
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

from sidecar_lib import serve

HA_URL = os.environ.get("LEX_HA_URL", "").rstrip("/")
HA_TOKEN = os.environ.get("LEX_HA_TOKEN", "")
USE_HA = bool(HA_URL and HA_TOKEN)
TARIFF_ENTITY = os.environ.get("LEX_HA_TARIFF_ENTITY", "")
STUB_NOW = os.environ.get("LEX_HA_STUB_NOW", "13:00")

# Empty means "derive from the entity's domain". These exist for an appliance
# whose integration wants a service DOMAIN_SERVICES does not know; they are
# NOT the normal path, and a single global service name was the bug in #198 —
# it could only ever be right for one appliance at a time.
START_SERVICE = os.environ.get("LEX_HA_START_SERVICE", "")
STOP_SERVICE = os.environ.get("LEX_HA_STOP_SERVICE", "")

# How to start and stop an entity, by the entity's own domain. HA routes a
# service call to entities of the SERVICE's domain, so `switch.turn_on` with a
# `vacuum.*` entity_id is not an error — it is accepted, answered 200, and
# applied to nothing. Deriving the service from the entity is what lets one
# sidecar drive a vacuum and a washer at once.
#
#   domain         -> (start, stop)
DOMAIN_SERVICES = {
    "vacuum": ("vacuum.start", "vacuum.return_to_base"),
    "media_player": ("media_player.turn_on", "media_player.turn_off"),
    "switch": ("switch.turn_on", "switch.turn_off"),
}

# A vacuum's stop is `return_to_base`, not `vacuum.stop`: stopping the robot
# where it stands leaves it mid-floor, and an appliance that is now an obstacle
# in the hallway is not what a caller asking to stop it meant.

# An unknown domain gets the old default. It is a guess, but a loud one — the
# domain guard below refuses to send it unless the entity really is a switch.
FALLBACK_SERVICES = ("switch.turn_on", "switch.turn_off")

# The one HA domain whose services deliberately act on entities of any domain.
GENERIC_DOMAIN = "homeassistant"


def domain_of(entity_or_service):
    """The part before the first dot. `vacuum.xiaomi_s10` -> `vacuum`."""
    return entity_or_service.partition(".")[0]


def service_for(entity, kind, override=""):
    """Which service starts (or stops) this entity. `kind` is "start"/"stop"."""
    if override:
        return override
    start, stop = DOMAIN_SERVICES.get(domain_of(entity), FALLBACK_SERVICES)
    return start if kind == "start" else stop


def refusal_reason(service, entity):
    """None when the call is worth making, else why it provably is not.

    This is the cheap half of "never report a success we cannot evidence": a
    service from one domain aimed at an entity from another cannot do anything,
    so it is refused BEFORE dispatch rather than sent and misread as reached.
    It does not catch every silent no-op — a TV that needs Wake-on-LAN and a
    washer whose Remote Start is not armed both accept a same-domain call and
    ignore it. Those need the state re-read that is still to come; this catches
    the class that is decidable without asking HA anything.
    """
    sdom, edom = domain_of(service), domain_of(entity)
    if sdom == edom or sdom == GENERIC_DOMAIN:
        return None
    return (f"{service} cannot act on {entity}: a '{sdom}' service does not "
            f"reach a '{edom}' entity. Home Assistant would accept this call, "
            f"answer 200, and change nothing.")

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
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            # Formatted to match ha_sidecar.lex exactly. `http.send` there
            # returns a status rather than raising, so the Lex port composes
            # this string itself; letting urllib's own "HTTP Error 404: Not
            # Found" through instead made the two ports disagree on `detail`
            # for every non-2xx. Real-mode parity caught it — the stub house
            # makes no HTTP calls, so nothing had ever compared this path.
            raise RuntimeError(f"HTTP {e.code} from {path}") from None

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

    def _dispatch(self, entity, kind, override, verb):
        service = service_for(entity, kind, override)
        why = refusal_reason(service, entity)
        if why:
            return {"outcome": "stalled", "detail": why}
        return self._call_service(service, entity, verb)

    def start(self, entity):
        return self._dispatch(entity, "start", START_SERVICE, "started")

    def stop(self, entity):
        return self._dispatch(entity, "stop", STOP_SERVICE, "stopped")


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


def _health():
    return {"ha": USE_HA, "mode": "home-assistant" if USE_HA else "stub house"}


def main():
    mode = f"HOME ASSISTANT @ {HA_URL}" if USE_HA else "stub house (no HA)"
    serve(handle_skill, tag="ha", banner=f"lex-robot HA sidecar [{mode}]", health=_health)


if __name__ == "__main__":
    main()
