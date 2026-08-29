#!/usr/bin/env python3
"""Differential test: sidecar/ha_sidecar.lex must answer exactly like the .py.

`ha_sidecar.lex` claims to be a drop-in — "same env vars, same HTTP API". This
asserts that claim against both servers on every request, instead of trusting
it. Run by scripts/smoke.sh; also runnable directly:

    LEX_PORT=8951 PY_PORT=8952 python3 scripts/ha_parity.py

Exits 0 when every case matches, 1 (printing each divergence) otherwise. Two
divergences it found when first written are worth knowing about, because both
are now pinned here: a malformed JSON body must be a 400 rather than silently
empty arguments, and POST does NOT strip a query string (sidecar_lib's own
asymmetry — see ha_sidecar.lex's `handle`).
"""
import json
import os
import sys
import urllib.error
import urllib.request

LEX = int(os.environ.get("LEX_PORT", "8951"))
PY = int(os.environ.get("PY_PORT", "8952"))

# (method, path, raw body or None). Ordered: the appliance cases below read
# back the state they just changed, so the two houses are compared as state
# machines, not just as pure functions.
CASES = [
    ("GET", "/health", None),
    ("GET", "/nope", None),
    ("GET", "/skill/read_state", None),
    ("POST", "/skill/read_state", b'{"entity":"washer.main"}'),
    ("POST", "/skill/read_state", b'{"entity":"nope.gone"}'),
    ("POST", "/skill/read_state", b'{"entity":"say \\"hi\\""}'),
    ("POST", "/skill/read_state", b""),
    ("POST", "/skill/read_state", b"not json at all"),
    ("POST", "/skill/read_tariff", b"{}"),
    ("POST", "/skill/read_tariff", b'{"at":"03:00"}'),
    ("POST", "/skill/read_tariff", b'{"at":"08:00"}'),
    ("POST", "/skill/read_tariff", b'{"at":"20:30"}'),
    ("POST", "/skill/read_tariff", b'{"at":"23:59"}'),
    ("POST", "/skill/read_tariff", b'{"at":"25:00"}'),
    ("POST", "/skill/read_tariff", b'{"at":"noon"}'),
    ("POST", "/skill/read_tariff?x=1", b"{}"),
    ("POST", "/skill/appliance_start", b'{"entity":"washer.main"}'),
    ("POST", "/skill/read_state", b'{"entity":"washer.main"}'),
    ("POST", "/skill/appliance_stop", b'{"entity":"washer.main"}'),
    ("POST", "/skill/read_state", b'{"entity":"washer.main"}'),
    ("POST", "/skill/appliance_start", b'{"entity":"tv.livingroom"}'),
    ("POST", "/skill/read_state", b'{"entity":"tv.livingroom"}'),
    ("POST", "/skill/appliance_stop", b'{"entity":"tv.livingroom"}'),
    ("POST", "/skill/read_state", b'{"entity":"tv.livingroom"}'),
    ("POST", "/skill/appliance_start", b"{}"),
    ("POST", "/skill/appliance_stop", b"{}"),
    ("POST", "/skill/appliance_start", b'{"entity":"ghost"}'),
    ("POST", "/skill/no_such_skill", b"{}"),
]

# Real-mode cases, run against a shared sidecar/mock_ha.py (PARITY_CASES=real).
# The stub house never dispatches a service at all, so CASES above cannot reach
# the domain-keyed service map from #198 — these are the only parity coverage
# that logic has.
#
# Both servers are pointed at the SAME mock house and each case is sent to both,
# so every mutation is applied twice. That is fine because it is applied
# identically: the read-backs compare two servers that agreed on what to do.
REAL_CASES = [
    ("POST", "/skill/read_state", b'{"entity":"vacuum.xiaomi_s10"}'),
    ("POST", "/skill/read_state", b'{"entity":"vacuum.nope"}'),
    # Derived from the entity's domain, with no env var set either side.
    ("POST", "/skill/appliance_start", b'{"entity":"vacuum.xiaomi_s10"}'),
    ("POST", "/skill/read_state", b'{"entity":"vacuum.xiaomi_s10"}'),
    ("POST", "/skill/appliance_stop", b'{"entity":"vacuum.xiaomi_s10"}'),
    ("POST", "/skill/read_state", b'{"entity":"vacuum.xiaomi_s10"}'),
    # A different domain, same sidecar, same run — the thing one global
    # service name could never do.
    ("POST", "/skill/appliance_start", b'{"entity":"switch.washer"}'),
    ("POST", "/skill/read_state", b'{"entity":"switch.washer"}'),
    # Unknown domain: guessed at switch.*, then refused rather than sent.
    ("POST", "/skill/appliance_start", b'{"entity":"sensor.pvpc"}'),
    ("POST", "/skill/read_state", b'{"entity":"sensor.pvpc"}'),
    # No tariff entity configured: both must decline the same way.
    ("POST", "/skill/read_tariff", b"{}"),
    ("POST", "/skill/read_tariff", b'{"at":"03:00"}'),
]


def call(port, method, path, body):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=body, method=method,
        headers={"Content-Type": "application/json"} if body is not None else {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:                      # connection refused, timeout
        return 0, f"<unreachable: {e}>"


def parsed(text):
    try:
        return json.loads(text)
    except Exception:
        return text


def main():
    mode = os.environ.get("PARITY_CASES", "stub")
    cases = REAL_CASES if mode == "real" else CASES
    bad = []
    for method, path, body in cases:
        ls, lt = call(LEX, method, path, body)
        ps, pt = call(PY, method, path, body)
        if ls == 0 or ps == 0:
            print(f"ERROR: server unreachable — lex={lt if ls == 0 else 'ok'} "
                  f"py={pt if ps == 0 else 'ok'}")
            return 2
        if ls != ps or parsed(lt) != parsed(pt):
            bad.append((method, path, body, ls, parsed(lt), ps, parsed(pt)))
    if bad:
        print(f"DIVERGENCES ({len(bad)} of {len(cases)}) in {mode} mode:")
        for method, path, body, ls, lb, ps, pb in bad:
            print(f" - {method} {path} {body!r}")
            print(f"     lex[{ls}]: {lb}")
            print(f"     py [{ps}]: {pb}")
        return 1
    print(f"OK: {len(cases)} {mode}-mode requests answered identically "
          f"by .lex and .py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
