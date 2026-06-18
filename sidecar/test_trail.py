import hashlib
from trail import Trail, compute_id

def test_compute_id_matches_lex_trail_formula():
    # Mirror lex-trail/src/event.lex: sha256 of join([kind, parent, payload, ts], " ").
    expected = hashlib.sha256(b"cap.invoked  {} 0").hexdigest()
    assert compute_id("cap.invoked", None, "{}", 0) == expected

def test_chain_links_parent_to_prev_id():
    t = Trail()
    e1 = t.emit("cap.invoked", '{"capability":"move_to"}', ts_ms=1)
    e2 = t.emit("cap.completed", '{"capability":"move_to","result":"reached"}', ts_ms=2)
    assert e2["parent"] == e1["id"]
    assert t.verify()

def test_verify_detects_tampering():
    t = Trail()
    t.emit("cap.invoked", "{}", ts_ms=1)
    t.events[0]["payload_json"] = "{\"tampered\":true}"
    assert not t.verify()
