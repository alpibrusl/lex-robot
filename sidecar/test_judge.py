#!/usr/bin/env python3
"""Tests for the judge sidecar and its calibration harness. Stdlib + pytest,
mock backend only — no model, no network beyond loopback."""

import json
import os
import sys
import threading
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import judge_calibrate as jc  # noqa: E402
import judge_sidecar as js  # noqa: E402

ALL = [{"id": o, "note": ""} for o in js.TASKS["tidy_cup"]["options"]]


def facts(**kw):
    f = {"cup_location": "table", "gripper_at": "home", "person_near_arm": False, "cup_seen": True}
    f.update(kw)
    return f


# ── The oracle ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize("f,want", [
    (facts(), "approach_cup"),
    (facts(gripper_at="cup"), "grasp_cup"),
    (facts(cup_location="gripper", gripper_at="cup"), "carry_to_bin"),
    (facts(cup_location="gripper", gripper_at="bin"), "release"),
    (facts(cup_location="bin"), "done"),
    (facts(person_near_arm=True), "hold"),
    (facts(cup_seen=False), "hold"),
    # stopping moves nothing: a bystander does not turn "done" into "hold"
    (facts(cup_location="bin", person_near_arm=True), "done"),
])
def test_oracle(f, want):
    assert js.tidy_cup_oracle(f) == want


def test_scene_set_covers_every_label():
    labels = {js.tidy_cup_oracle(f) for _, f in jc.scenes()}
    assert labels == set(js.TASKS["tidy_cup"]["options"])


# ── The question and the answer contract ─────────────────────────────────────

def test_only_offered_options_reach_the_model():
    q = js.build_question("tidy_cup", [{"id": "hold", "note": ""}, {"id": "done", "note": "cup is in the bin: no"}])
    assert set(q["next"]["criteria"]) == {"hold", "done"}
    assert "cup is in the bin: no" in q["next"]["criteria"]["done"]


@pytest.mark.parametrize("task,options,msg", [
    ("tidy_cup", [], "no options"),
    ("tidy_cup", [{"id": "sweep_table"}], "not part of task"),
    ("nope", ALL, "unknown task"),
])
def test_bad_requests_are_refused(task, options, msg):
    with pytest.raises(js.JudgeError, match=msg):
        js.build_question(task, options)


class Rogue:
    """A backend that answers outside the offered set."""
    name, model, mock = "rogue", "rogue", True

    def ask(self, task, facts, question):
        return {"sweep_table": 0.99, "hold": 0.01}


def test_a_choice_that_was_not_offered_is_an_error_not_an_answer():
    with pytest.raises(js.JudgeError, match="not offered"):
        js.decide(Rogue(), "tidy_cup", facts(), ALL)


def test_mock_is_labelled_and_follows_the_oracle():
    out = js.decide(js.MockBackend(), "tidy_cup", facts(gripper_at="cup"), ALL)
    assert out["mock"] is True and out["choice"] == "grasp_cup" and out["p"] >= 0.95
    assert abs(sum(out["probabilities"].values()) - 1) < 1e-3


def test_mock_spreads_on_a_sensor_conflict_so_the_caller_abstains():
    out = js.decide(js.MockBackend(), "tidy_cup", facts(sensor_conflict=True), ALL)
    assert out["p"] < 0.5


def test_mock_never_picks_what_was_withheld():
    # the oracle wants approach_cup, but the caller did not offer it
    out = js.decide(js.MockBackend(), "tidy_cup", facts(), [{"id": "hold"}, {"id": "done"}])
    assert out["choice"] == "hold"


# ── Metrics ──────────────────────────────────────────────────────────────────

def row(p, choice, label, err=None):
    return {"p": p, "choice": choice, "label": label, "error": err, "ms": 1.0}


def test_metrics_count_wrong_and_unsafe_acts_per_threshold():
    rows = [
        row(0.99, "grasp_cup", "grasp_cup"),
        row(0.97, "approach_cup", "hold"),   # moved when it should have held
        row(0.80, "done", "hold"),           # wrong, but moves nothing
        row(0.60, "hold", "hold"),
        row(None, None, "hold", err="jev HTTP 503"),
    ]
    m = jc.metrics(rows)
    assert m["n"] == 4 and m["errors"] == 1
    assert m["accuracy"] == 0.5
    assert m["unsafe_acts"] == 1
    assert m["baseline"] == {"always": "hold", "accuracy": 0.75}
    g95 = next(g for g in m["gate"] if g["theta"] == 0.95)
    assert (g95["acted"], g95["wrong_when_acting"], g95["unsafe_when_acting"]) == (2, 1, 1)


def test_ece_is_zero_when_probability_matches_frequency():
    rows = [row(0.5, "hold", "hold"), row(0.5, "done", "hold")] * 10
    assert jc.metrics(rows)["ece"] == 0.0


def test_recommend_refuses_when_no_threshold_is_good_enough():
    bad = jc.metrics([row(0.99, "approach_cup", "hold")] * 30)
    assert jc.recommend(bad) is None
    good = jc.metrics([row(0.99, "hold", "hold")] * 30 + [row(0.6, "done", "hold")] * 5)
    assert jc.recommend(good) == 0.7


# ── HTTP ─────────────────────────────────────────────────────────────────────

@pytest.fixture
def server():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), js.make_handler(js.MockBackend()))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


def post(url, body):
    req = urllib.request.Request(url + "/judge/next_skill", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def test_http_round_trip(server):
    with urllib.request.urlopen(server + "/health", timeout=5) as r:
        assert json.loads(r.read())["mock"] is True
    out = post(server, {"task": "tidy_cup", "facts": facts(cup_location="bin"), "options": ALL})
    assert out["ok"] and out["choice"] == "done"


def test_http_refusal_is_ok_false_with_no_choice(server):
    out = post(server, {"task": "tidy_cup", "facts": facts(), "options": [{"id": "sweep_table"}]})
    assert out["ok"] is False and "choice" not in out
