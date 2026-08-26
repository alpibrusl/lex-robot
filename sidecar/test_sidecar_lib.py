"""The shared sidecar HTTP skeleton — route resolution.

Written when porting ha_sidecar.py to Lex surfaced that do_POST kept the query
string while do_GET stripped it, so POST /skill/read_tariff?x=1 resolved to a
skill literally named "read_tariff?x=1". These pin both verbs to the same rule.
"""
import json
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from sidecar_lib import make_handler


def _skill(name, args):
    return {"skill": name, "args": args}


def _post_route(path, args):
    parts = path.strip("/").split("/")
    if len(parts) == 4 and parts[0] == "v1" and parts[1] == "chargers":
        return 200, {"charger": parts[2], "action": parts[3]}
    return None


@pytest.fixture
def server():
    handler = make_handler(_skill, tag="test", health=lambda: {"mode": "test"},
                           post_route=_post_route)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv.server_address[1]
    srv.shutdown()


def call(port, path, body=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 method=method or ("POST" if data is not None else "GET"),
                                 headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def test_post_strips_the_query_before_resolving_the_skill(server):
    # Used to answer {"error": "unknown skill: read_tariff?x=1"}.
    status, body = call(server, "/skill/read_tariff?x=1", {})
    assert status == 200
    assert body["skill"] == "read_tariff"


def test_post_route_sees_a_query_free_path(server):
    # depot's OCPP route splits on "/" and matched parts[3] == "start", so a
    # query turned the last segment into "start?x=1" and fell through to 404.
    status, body = call(server, "/v1/chargers/CP-1/start?x=1", {})
    assert status == 200
    assert body == {"charger": "CP-1", "action": "start"}


def test_get_still_strips_the_query(server):
    status, body = call(server, "/health?cache=0")
    assert status == 200
    assert body["ok"] is True and body["mode"] == "test"


def test_a_malformed_body_is_a_400_not_empty_arguments(server):
    status, body = call(server, "/skill/read_state", method="POST")
    assert status == 200          # no body at all is an empty argument object
    req = urllib.request.Request(f"http://127.0.0.1:{server}/skill/read_state",
                                 data=b"not json", method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=5)
        assert False, "expected 400"
    except urllib.error.HTTPError as e:
        assert e.code == 400
        assert json.loads(e.read())["error"] == "invalid json"


def test_an_unknown_path_is_404_on_both_verbs(server):
    assert call(server, "/nope")[0] == 404
    assert call(server, "/nope", {})[0] == 404
