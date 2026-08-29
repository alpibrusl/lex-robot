"""Tests for /vision/scan and the JSON extraction it depends on.

Both behaviours here were found by a live failure, not by design review, and
both fail in ways that look like something else:

  * A reply capped by the provider's default max_tokens arrives TRUNCATED, not
    as an error. `_extract_json` then reported "Expecting value: line 1
    column 129" — a message that points at the parser, not at the cause.
  * `scan` feeds a planner deciding whether it may drive. Every failure path
    must answer "unknown". An exception, an empty list, or a missing key that
    a caller reads as falsey are all ways of accidentally saying "yes".
"""
import json

import pytest

import vision_service as vs


# ── _extract_json ────────────────────────────────────────────────────────────

def test_plain_object():
    assert vs._extract_json('{"a": 1}', "{", "}") == {"a": 1}


def test_object_followed_by_prose():
    # VLMs add "and that's my answer" often enough that this must not break.
    assert vs._extract_json('{"a": 1} and that is my answer.', "{", "}") == {"a": 1}


def test_object_inside_a_markdown_fence():
    assert vs._extract_json('```json\n{"a": 1}\n```', "{", "}") == {"a": 1}


def test_nested_object_closes_at_the_outer_brace_not_the_last_one():
    """Regression: the old implementation used rfind(closer).

    With a stray brace after the object, rfind lands past the real end and the
    slice is invalid. Depth-matching stops at the brace that actually closes
    the object it started.
    """
    text = 'prose {"o": [{"b": 2}]} trailing {stray'
    assert vs._extract_json(text, "{", "}") == {"o": [{"b": 2}]}


def test_truncated_reply_blames_truncation_not_the_parser():
    """The actual bug this file exists for.

    A reply cut mid-object used to surface as a column number. It must name
    the cause and the knob, or the next person loses the same hour.
    """
    cut = '{"obstacles": [{"what": "door", "bearing_deg": -32}, {"what": "books'
    with pytest.raises(ValueError) as ei:
        vs._extract_json(cut, "{", "}")
    msg = str(ei.value).lower()
    assert "truncated" in msg
    assert "max_tokens" in msg


def test_no_opener_at_all_is_its_own_error():
    with pytest.raises(ValueError) as ei:
        vs._extract_json("I cannot see anything.", "{", "}")
    assert "no {" in str(ei.value)


# ── scan() ───────────────────────────────────────────────────────────────────

def _stub_chat(monkeypatch, reply):
    monkeypatch.setattr(vs, "MOCK", False)
    monkeypatch.setattr(vs, "_chat", lambda *a, **k: reply)


def test_scan_parses_obstacles_and_clearance(monkeypatch):
    _stub_chat(monkeypatch, json.dumps({
        "obstacles": [{"what": "bookshelf", "bearing_deg": 0},
                      {"what": "door", "bearing_deg": -30.4}],
        "clear_ahead": "no", "detail": "blocked"}))
    out = vs.scan("aGk=", "")
    assert out["clear_ahead"] == "no"
    assert out["obstacles"] == [{"what": "bookshelf", "bearing_deg": 0.0},
                                {"what": "door", "bearing_deg": -30.4}]


def test_a_model_failure_answers_unknown_rather_than_raising(monkeypatch):
    monkeypatch.setattr(vs, "MOCK", False)

    def boom(*a, **k):
        raise RuntimeError("model exploded")
    monkeypatch.setattr(vs, "_chat", boom)
    out = vs.scan("aGk=", "")
    assert out["clear_ahead"] == "unknown"
    assert "model exploded" in out["detail"]


def test_an_empty_frame_answers_unknown(monkeypatch):
    monkeypatch.setattr(vs, "MOCK", False)
    out = vs.scan("", "")
    assert out["clear_ahead"] == "unknown"
    assert out["obstacles"] == []


def test_an_unrecognised_clearance_value_is_downgraded_to_unknown(monkeypatch):
    """A model answering "probably" must never be read as "yes"."""
    _stub_chat(monkeypatch, '{"obstacles": [], "clear_ahead": "probably", "detail": ""}')
    assert vs.scan("aGk=", "")["clear_ahead"] == "unknown"


def test_clear_ahead_is_case_insensitive(monkeypatch):
    _stub_chat(monkeypatch, '{"obstacles": [], "clear_ahead": "YES", "detail": ""}')
    assert vs.scan("aGk=", "")["clear_ahead"] == "yes"


def test_an_obstacle_without_a_usable_bearing_is_dropped(monkeypatch):
    """A bearing the base cannot steer to is not an obstacle report, it is
    noise — and keeping it would put a None into the planner's table."""
    _stub_chat(monkeypatch, json.dumps({
        "obstacles": [{"what": "chair", "bearing_deg": "left"},
                      {"what": "table", "bearing_deg": 12}],
        "clear_ahead": "no", "detail": ""}))
    assert vs.scan("aGk=", "")["obstacles"] == [{"what": "table", "bearing_deg": 12.0}]


def test_a_truncated_model_reply_answers_unknown_not_an_exception(monkeypatch):
    """End of the chain: truncation must reach the planner as 'unknown'."""
    _stub_chat(monkeypatch, '{"obstacles": [{"what": "do')
    out = vs.scan("aGk=", "")
    assert out["clear_ahead"] == "unknown"
    assert "truncated" in out["detail"].lower()


def test_mock_mode_never_claims_clearance(monkeypatch):
    monkeypatch.setattr(vs, "MOCK", True)
    out = vs.scan("aGk=", "")
    assert out["clear_ahead"] == "unknown"
    assert "mock" in out["detail"].lower()


def test_chat_sends_an_explicit_max_tokens():
    """Guards the root cause: without this the provider default truncates."""
    assert vs.MAX_TOKENS >= 512
