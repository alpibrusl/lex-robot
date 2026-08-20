"""Self-grading: the robot decides whether its own episode succeeded.

#148/#149 let the robot generate episodes unattended, but nobody knows if they
worked. Without this, every success rate in the training epic (#150) is a
number a human produced by watching rollouts — not autonomous, and it does not
scale past a few dozen episodes.

**Two independent checks, and they must agree.**

  1. GeometricCheck — detect the object, project it onto the calibrated plane
     (the same pinhole path as vision_reset_teleop), and test whether it landed
     inside the target region. Grounded in geometry: it can be wrong about
     WHERE the object is, but it cannot talk itself into "looks done to me".
  2. VlmJudge — an outcome question ("was the cup placed on the plate?") to
     /vision/judge, which takes a `model` override so the grader can be a
     DIFFERENT model than the one that drove the episode.

Agreement is the verdict. **Disagreement is not averaged away** — the episode
is marked `needs_audit` and excluded from training data. That is the mitigation
for #152's stated risk: if one model both acts and grades, correlated errors
read as success. Two mechanisms that fail differently make that visible instead
of silent.

`score()` turns verdicts plus human labels into the numbers #152 is graded on —
and reports FAILURE recall separately, because a verifier that answers "success"
every time scores well on a mostly-successful set while being useless.
"""

from __future__ import annotations

import base64
import json
import logging
import urllib.request
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)


@dataclass
class Verdict:
    """One episode's grade. `success` is only meaningful when `agreed` is True."""
    success: bool
    agreed: bool
    geometric: bool | None
    judge: bool | None
    reason: str
    detail: dict[str, Any] = field(default_factory=dict)

    @property
    def needs_audit(self) -> bool:
        """True when the two checks disagree, or either could not run. Such an
        episode is not evidence either way and must not be trained on."""
        return not self.agreed

    @property
    def usable(self) -> bool:
        return self.agreed


def _post(url: str, payload: dict, timeout: float) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def encode_frame(frame) -> str:
    import cv2
    ok, buf = cv2.imencode(".jpg", frame)
    if not ok:
        raise RuntimeError("could not JPEG-encode frame")
    return base64.b64encode(buf.tobytes()).decode()


class EpisodeVerifier:
    """Grades a finished episode from its final frame."""

    def __init__(
        self,
        camera,                       # vision_reset_teleop.CameraModel
        target_region,                # [[x0, x1], [y0, y1]] in the arm frame
        object_name: str,
        question: str,
        vision_url: str = "http://127.0.0.1:8901",
        judge_model: str | None = None,
        plane_z: float = 0.0,
        min_confidence: float = 0.5,
        tolerance_m: float = 0.05,
        timeout_s: float = 120.0,
    ):
        self.camera = camera
        self.target_region = target_region
        self.object_name = object_name
        self.question = question
        self.vision_url = vision_url.rstrip("/")
        self.judge_model = judge_model
        self.plane_z = plane_z
        self.min_confidence = min_confidence
        self.tolerance_m = tolerance_m
        self.timeout_s = timeout_s

    # -- check 1: geometry ---------------------------------------------------

    def geometric_check(self, image_b64: str):
        """(landed_in_region, detail). Returns (None, ...) when it cannot tell —
        never a guess, matching src/camera.lex's refusal contract."""
        det = _post(f"{self.vision_url}/vision/detect",
                    {"image_b64": image_b64, "name": self.object_name}, self.timeout_s)
        if not det.get("found"):
            return None, {"why": f"{self.object_name!r} not visible", "det": det}
        conf = float(det.get("confidence", 0.0))
        if conf < self.min_confidence:
            return None, {"why": f"confidence {conf:.2f} below floor", "det": det}
        try:
            x, y, _ = self.camera.project_to_plane(
                float(det["cx"]), float(det["cy"]), self.plane_z)
        except ValueError as e:
            return None, {"why": f"projection refused: {e}", "det": det}
        (x0, x1), (y0, y1) = self.target_region
        t = self.tolerance_m
        inside = (x0 - t) <= x <= (x1 + t) and (y0 - t) <= y <= (y1 + t)
        return inside, {"xy": (round(x, 4), round(y, 4)), "confidence": conf}

    # -- check 2: an independent opinion ------------------------------------

    def judge_check(self, image_b64: str):
        payload = {"image_b64": image_b64, "question": self.question}
        if self.judge_model:
            payload["model"] = self.judge_model
        v = _post(f"{self.vision_url}/vision/judge", payload, self.timeout_s)
        if "success" not in v or v.get("detail", "").startswith("vision model failed"):
            return None, v
        return bool(v["success"]), v

    # -- the verdict ---------------------------------------------------------

    def verify(self, final_frame) -> Verdict:
        b64 = encode_frame(final_frame)
        geo, geo_detail = self.geometric_check(b64)
        jud, jud_detail = self.judge_check(b64)

        if geo is None or jud is None:
            missing = "geometric" if geo is None else "judge"
            return Verdict(False, False, geo, jud,
                           f"{missing} check could not run — episode not evidence either way",
                           {"geometric": geo_detail, "judge": jud_detail})
        if geo != jud:
            return Verdict(False, False, geo, jud,
                           f"checks disagree (geometric={geo}, judge={jud}) — needs audit",
                           {"geometric": geo_detail, "judge": jud_detail})
        return Verdict(geo, True, geo, jud,
                       "both checks agree", {"geometric": geo_detail, "judge": jud_detail})


# ── measuring the verifier itself (#152's pass criterion) ───────────────────

def score(verdicts: list[Verdict], human_labels: list[bool]) -> dict:
    """Grade the grader against a human-labelled set.

    Reports failure recall separately and deliberately: a verifier that always
    answers "success" looks excellent on a mostly-successful set while catching
    nothing. #152 passes on agreement AND failure recall, not accuracy alone.
    """
    if len(verdicts) != len(human_labels):
        raise ValueError("verdicts and human_labels must be the same length")
    n = len(verdicts)
    if n == 0:
        raise ValueError("nothing to score")

    usable = [(v, h) for v, h in zip(verdicts, human_labels) if v.usable]
    audits = n - len(usable)
    agree = sum(1 for v, h in usable if v.success == h)

    real_fail = [(v, h) for v, h in usable if h is False]
    real_ok = [(v, h) for v, h in usable if h is True]
    caught_fail = sum(1 for v, _ in real_fail if v.success is False)
    caught_ok = sum(1 for v, _ in real_ok if v.success is True)

    return {
        "episodes": n,
        "audited_out": audits,
        "audit_rate": audits / n,
        "scored": len(usable),
        "agreement": (agree / len(usable)) if usable else 0.0,
        "failure_recall": (caught_fail / len(real_fail)) if real_fail else None,
        "success_recall": (caught_ok / len(real_ok)) if real_ok else None,
        "real_failures": len(real_fail),
    }
