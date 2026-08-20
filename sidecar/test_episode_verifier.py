"""Tests for M1 self-grading (#152). No camera, no robot, no model.

The interesting cases are the ones where the two checks pull apart -- that
disagreement is the whole mechanism, so most of this file is about it.
"""
import numpy as np
import pytest

import episode_verifier as ev
from episode_verifier import EpisodeVerifier, Verdict, score
from vision_reset_teleop import CameraModel

REGION = [[0.20, 0.30], [-0.05, 0.05]]


def overhead():
    return CameraModel(pos=(0.25, 0.0, 0.6), right=(1.0, 0.0, 0.0), down=(0.0, 1.0, 0.0),
                       forward=(0.0, 0.0, -1.0), fx=1.0, fy=1.0, cx0=0.5, cy0=0.5)


def verifier(**kw):
    kw.setdefault("tolerance_m", 0.0)
    return EpisodeVerifier(camera=overhead(), target_region=REGION,
                           object_name="cup", question="was the cup placed on the plate?", **kw)


def stub_posts(monkeypatch, detect=None, judge=None):
    def fake(url, payload, timeout):
        return detect if url.endswith("/vision/detect") else judge
    monkeypatch.setattr(ev, "_post", fake)


FRAME = np.zeros((32, 32, 3), dtype=np.uint8)

# (0.5, 0.5) projects to x=0.250, y=0.000 -> inside REGION
IN_BOX = {"found": True, "cx": 0.5, "cy": 0.5, "confidence": 0.9}
# (0.9, 0.9) projects far outside
OUT_BOX = {"found": True, "cx": 0.9, "cy": 0.9, "confidence": 0.9}
YES = {"success": True, "confidence": 0.9, "reason": "cup is on the plate", "detail": "model x"}
NO = {"success": False, "confidence": 0.9, "reason": "cup is elsewhere", "detail": "model x"}


def test_both_agree_success(monkeypatch):
    stub_posts(monkeypatch, IN_BOX, YES)
    v = verifier().verify(FRAME)
    assert v.success and v.agreed and v.usable and not v.needs_audit


def test_both_agree_failure(monkeypatch):
    stub_posts(monkeypatch, OUT_BOX, NO)
    v = verifier().verify(FRAME)
    assert v.success is False and v.agreed and v.usable


def test_disagreement_is_flagged_not_averaged(monkeypatch):
    """The point of two checks: a judge that says yes while the geometry says
    the object is elsewhere must NOT be recorded as a success."""
    stub_posts(monkeypatch, OUT_BOX, YES)
    v = verifier().verify(FRAME)
    assert v.needs_audit and not v.usable and v.success is False
    assert "disagree" in v.reason


def test_undetectable_object_is_not_evidence(monkeypatch):
    stub_posts(monkeypatch, {"found": False}, YES)
    v = verifier().verify(FRAME)
    assert v.needs_audit and v.geometric is None


def test_low_confidence_detection_refuses(monkeypatch):
    stub_posts(monkeypatch, {"found": True, "cx": 0.5, "cy": 0.5, "confidence": 0.1}, YES)
    v = verifier(min_confidence=0.8).verify(FRAME)
    assert v.needs_audit and v.geometric is None


def test_projection_refusal_propagates(monkeypatch):
    """A camera whose plane is behind it must refuse, not yield a position."""
    stub_posts(monkeypatch, IN_BOX, YES)
    vf = verifier()
    vf.plane_z = 1.0                      # plane above the camera -> refused
    v = vf.verify(FRAME)
    assert v.needs_audit and v.geometric is None
    assert "projection refused" in v.detail["geometric"]["why"]


def test_judge_model_override_is_sent(monkeypatch):
    """The grader must be able to differ from the actor -- #152's core risk."""
    seen = {}
    def fake(url, payload, timeout):
        seen[url] = payload
        return IN_BOX if url.endswith("/vision/detect") else YES
    monkeypatch.setattr(ev, "_post", fake)
    verifier(judge_model="a-different-model").verify(FRAME)
    judge_payload = [p for u, p in seen.items() if u.endswith("/vision/judge")][0]
    assert judge_payload["model"] == "a-different-model"
    detect_payload = [p for u, p in seen.items() if u.endswith("/vision/detect")][0]
    assert "model" not in detect_payload


def test_tolerance_widens_the_target(monkeypatch):
    # cx=0.62 projects to x=0.322 (camera.lex's own worked example), which is
    # 0.022 outside REGION's upper bound of 0.30.
    stub_posts(monkeypatch, {"found": True, "cx": 0.62, "cy": 0.5, "confidence": 0.9}, YES)
    assert verifier(tolerance_m=0.0).verify(FRAME).geometric is False
    assert verifier(tolerance_m=0.10).verify(FRAME).geometric is True


# ── scoring the grader ──────────────────────────────────────────────────────

def _v(success, agreed=True):
    return Verdict(success, agreed, success, success, "")


def test_score_reports_failure_recall_separately():
    """A verifier that always says success must NOT look good, even though
    accuracy on a mostly-successful set is high."""
    verdicts = [_v(True)] * 9 + [_v(True)]      # last one is really a failure
    labels = [True] * 9 + [False]
    s = score(verdicts, labels)
    assert s["agreement"] == 0.9                # looks fine...
    assert s["failure_recall"] == 0.0           # ...but catches no failures


def test_score_excludes_audited_episodes():
    verdicts = [_v(True), _v(False), _v(True, agreed=False)]
    labels = [True, False, True]
    s = score(verdicts, labels)
    assert s["episodes"] == 3 and s["scored"] == 2 and s["audited_out"] == 1
    assert s["agreement"] == 1.0
    assert s["audit_rate"] == pytest.approx(1 / 3)


def test_score_perfect_verifier():
    verdicts = [_v(True), _v(False), _v(True), _v(False)]
    labels = [True, False, True, False]
    s = score(verdicts, labels)
    assert s["agreement"] == 1.0
    assert s["failure_recall"] == 1.0 and s["success_recall"] == 1.0


def test_score_rejects_mismatched_lengths():
    with pytest.raises(ValueError):
        score([_v(True)], [True, False])


def test_score_rejects_empty():
    with pytest.raises(ValueError):
        score([], [])
