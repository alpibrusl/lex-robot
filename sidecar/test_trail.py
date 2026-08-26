import hashlib
from trail import Trail, compute_id

def test_compute_id_matches_lex_trail_formula():
    # Mirror lex-trail/src/event.lex exactly: sha256 of the fields joined by NUL
    # (\x00), with a None parent contributing the empty string. For
    # ("cap.invoked", None, "{}", 0): ["cap.invoked", "", "{}", "0"] joined by
    # \x00 == b"cap.invoked\x00\x00{}\x000".
    expected = hashlib.sha256(b"cap.invoked\x00\x00{}\x000").hexdigest()
    assert compute_id("cap.invoked", None, "{}", 0) == expected

def test_compute_id_matches_a_digest_lex_trail_ACTUALLY_produced():
    """Pin the cross-language agreement, not a restatement of it.

    The test above re-derives the formula in the test body, so if
    lex-trail/src/event.lex ever changed its separator, trail.py and that test
    would go on agreeing with each other while both diverged from the spec --
    which is the one failure mode an in-process mirror actually has.

    These two digests came out of lex-trail itself. Regenerate with:

        # cid.lex
        import "std.io" as io
        import "lex-trail/src/event" as ev
        fn main() -> [io] Unit {
          let __0 := io.print(ev.compute_id("cap.invoked", None, "{}", 0))
          let __1 := io.print(ev.compute_id("cap.completed", Some("parent123"),
                                            "{\"capability\":\"move_arm\"}", 1700000000000))
        }
        lex run --allow-effects io cid.lex main
    """
    assert compute_id("cap.invoked", None, "{}", 0) == (
        "3c5057c42beb79a3636bbec8033698ef8fe20b8b5813ea743c8c83b081fa2a62")
    assert compute_id("cap.completed", "parent123",
                      '{"capability":"move_arm"}', 1700000000000) == (
        "da0e4b98fa6efb5c19f7d96d9f3b94a00f8d8aebe18fb6139da2ffe93a715324")


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
