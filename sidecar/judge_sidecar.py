#!/usr/bin/env python3
"""judge_sidecar — a typed-judgment provider for the planner (Jev or Laya).

This is JUDGMENT, not authority (DESIGN.md §1). It answers one question — which
of the skills the caller offered should run next — and nothing it says can
widen what the robot may do:

  * the CALLER builds the option list, and src/judge.lex only offers options
    the grant would admit (skill allowlisted, target in the workspace, outside
    keep-out). A skill the grant lacks is never shown, so it cannot be picked;
  * this service refuses to return an option that was not offered;
  * code picks WHERE (targets, forces); the model only picks WHICH. System One
    models return a choice among labels, not a continuous command.

Backends (LEX_JUDGE_BACKEND):
    mock   the task oracle's answer at a fixed probability, flattened on a
           `sensor_conflict` fact so the abstain path is exercised. For CI and
           demos. Every reply carries "mock": true — never fakes judgment
           silently.
    laya   Convai's open-weight model, local (pip install "laya>=0.3.3").
           LEX_JUDGE_LAYA_MODEL (default convaiinnovations/laya),
           LEX_JUDGE_LAYA_SUBFOLDER, LEX_JUDGE_LAYA_REVISION (pin a commit).
    jev    TypeSafe's hosted model. Key from TYPESAFE_API_KEY or the file named
           by LEX_JUDGE_JEV_KEY_FILE. LEX_JUDGE_JEV_MODEL (default jev-latest).

Contract (flat JSON so the Lex side parses it with sense.jstr/jfloat):

    GET  /health -> {"ok": true, "backend": "...", "model": "...", "mock": bool}
    POST /judge/next_skill
         {"task": "tidy_cup", "facts": {...}, "options": [{"id": "...", "note": "..."}]}
      -> {"ok": true, "choice": "...", "p": 0.93, "probabilities": {...},
          "backend": "...", "model": "...", "latency_ms": 31.2, "mock": bool}
      -> {"ok": false, "error": "..."}            (never a guessed choice)

`p` is the probability of the returned choice. It is NOT a threshold: what p
is trustworthy has to be measured per task (sidecar/judge_calibrate.py) — Jev
measured on lex-social had a dead band between 0.5 and 0.9, and Laya's own
`confidence` field is an entropy measure that does not transfer from Jev.

Env: LEX_JUDGE_HOST (default 127.0.0.1), LEX_JUDGE_PORT (default 8902),
     LEX_JUDGE_TIMEOUT_S (jev upstream budget, default 10).
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("LEX_JUDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("LEX_JUDGE_PORT", "8902"))
BACKEND = os.environ.get("LEX_JUDGE_BACKEND", "mock")
TIMEOUT_S = float(os.environ.get("LEX_JUDGE_TIMEOUT_S", "10"))

MOCK_P = 0.97

# ── Tasks: the goal, and what each option means ──────────────────────────────
# Wording lives HERE only, so the Lex planner and the calibration harness ask
# the model the identical question. The caller decides which of these ids are
# offered; a description is never sent for an option the caller withheld.

TASKS = {
    "tidy_cup": {
        "goal": "Put the cup from the table into the bin, then stop.",
        "instructions": (
            "Which skill should the robot run next to make progress on `goal`, "
            "given `facts`? Choose hold when acting now would be unsafe or the "
            "facts do not allow progress."
        ),
        "options": {
            "approach_cup": "Move the open gripper to the cup on the table.",
            "grasp_cup": "Close the gripper on the cup. Only useful when the gripper is at the cup.",
            "carry_to_bin": "Move the gripper, holding the cup, to above the bin.",
            "release": "Open the gripper to drop what it holds. Only useful above the bin.",
            "done": "Stop: the goal is achieved.",
            "hold": "Do nothing this step and wait.",
        },
    },
}


def tidy_cup_oracle(facts: dict) -> str:
    """Ground truth for the tidy_cup task: what a correct planner does next.

    Deterministic, so a calibration set built from it needs no human labels —
    and so a scene can be regenerated when the question wording changes.
    """
    where = facts.get("cup_location")
    if where == "bin":
        return "done"   # stopping moves nothing, so a bystander doesn't change it
    if facts.get("person_near_arm"):
        return "hold"
    if where == "gripper":
        return "release" if facts.get("gripper_at") == "bin" else "carry_to_bin"
    # on the table
    if not facts.get("cup_seen", True):
        return "hold"
    return "grasp_cup" if facts.get("gripper_at") == "cup" else "approach_cup"


ORACLES = {"tidy_cup": tidy_cup_oracle}


class JudgeError(Exception):
    pass


def build_question(task: str, options: list[dict]) -> dict:
    """The one Choice question, restricted to the offered options. A note
    (precomputed feasibility, e.g. "gripper is at the cup: no") rides along
    with its option — the jev-drone lesson: the model can only weigh what the
    state actually tells it."""
    spec = TASKS.get(task)
    if spec is None:
        raise JudgeError(f"unknown task {task!r}")
    if not options:
        raise JudgeError("no options offered")
    criteria = {}
    for o in options:
        oid = o.get("id")
        if oid not in spec["options"]:
            raise JudgeError(f"option {oid!r} is not part of task {task!r}")
        desc = spec["options"][oid]
        note = (o.get("note") or "").strip()
        criteria[oid] = f"{desc} ({note})" if note else desc
    return {"next": {"type": "choice", "instructions": spec["instructions"], "criteria": criteria}}


NOUL_PREFIX = "next_is_"


def build_nouls(task: str, options: list[dict]) -> dict:
    """The noul strategy: one yes/no per offered option, all in ONE request
    (same state, several questions). A yes/no about one option is closer to
    a lookup than a six-way choice — and lookups are what Laya got right."""
    choice = build_question(task, options)["next"]   # same validation, same wording
    return {NOUL_PREFIX + oid: {
        "type": "noul",
        "instructions": f"Given `facts`, is this the right next step toward `goal`? {desc}",
    } for oid, desc in choice["criteria"].items()}


def build_state(task: str, facts: dict) -> dict:
    return {"goal": TASKS[task]["goal"], "facts": facts}


# ── Backends ─────────────────────────────────────────────────────────────────

class MockBackend:
    name = "mock"
    model = "mock-oracle"
    mock = True

    def answers(self, task, facts, questions):
        if "next" in questions:
            return {"next": {"type": "choice", "probabilities": self._choice(task, facts, questions["next"])}}
        # noul strategy: yes for the oracle's option, no for the rest
        opts = [k[len(NOUL_PREFIX):] for k in questions]
        want = ORACLES[task](facts)
        if want not in opts:
            want = "hold" if "hold" in opts else opts[0]
        other = next((o for o in opts if o != want), None)
        out = {}
        for o in opts:
            if facts.get("sensor_conflict"):
                v = 0.55 if o == want else (0.45 if o == other else 0.05)
            else:
                v = MOCK_P if o == want else 1 - MOCK_P
            out[NOUL_PREFIX + o] = {"type": "noul", "noul": v}
        return out

    def _choice(self, task, facts, question):
        opts = list(question["criteria"])
        want = ORACLES[task](facts)
        if want not in opts:
            want = "hold" if "hold" in opts else opts[0]
        if facts.get("sensor_conflict"):
            # Two readings disagree: a spread distribution, so the caller's
            # gate has to abstain rather than act on a coin flip.
            rest = [o for o in opts if o != want]
            probs = {o: 0.1 / max(len(rest) - 1, 1) for o in rest}
            if rest:
                probs[rest[0]] = 0.42
            probs[want] = 0.48 if rest else 1.0
        else:
            rest = [o for o in opts if o != want]
            probs = {o: (1 - MOCK_P) / len(rest) for o in rest} if rest else {}
            probs[want] = MOCK_P if rest else 1.0
        return probs


class LayaBackend:
    name = "laya"
    mock = False

    def __init__(self):
        import laya  # heavy (torch); imported only when this backend is chosen
        repo = os.environ.get("LEX_JUDGE_LAYA_MODEL", "convaiinnovations/laya")
        kw = {}
        if os.environ.get("LEX_JUDGE_LAYA_SUBFOLDER"):
            kw["subfolder"] = os.environ["LEX_JUDGE_LAYA_SUBFOLDER"]
        if os.environ.get("LEX_JUDGE_LAYA_REVISION"):
            kw["revision"] = os.environ["LEX_JUDGE_LAYA_REVISION"]
        self.agent = laya.load(repo, **kw)
        self.model = "/".join([repo] + ([kw["subfolder"]] if "subfolder" in kw else [])) + (
            "@" + kw["revision"] if "revision" in kw else "")

    def answers(self, task, facts, questions):
        return self.agent.system_one(build_state(task, facts), questions)["answers"]


class JevBackend:
    name = "jev"
    mock = False
    URL = "https://api.typesafe.ai/v1/systemone"

    def __init__(self):
        key = os.environ.get("TYPESAFE_API_KEY", "")
        kf = os.environ.get("LEX_JUDGE_JEV_KEY_FILE", "")
        if not key and kf:
            with open(os.path.expanduser(kf)) as f:
                key = f.read().strip()
        if not key:
            raise JudgeError("jev backend needs TYPESAFE_API_KEY or LEX_JUDGE_JEV_KEY_FILE")
        self.key = key
        self.model = os.environ.get("LEX_JUDGE_JEV_MODEL", "jev-latest")

    def answers(self, task, facts, questions):
        body = json.dumps({"state": build_state(task, facts), "model": self.model,
                           "questions": questions}).encode()
        req = urllib.request.Request(self.URL, data=body, headers={
            "Content-Type": "application/json", "Authorization": f"Bearer {self.key}"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
                r = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            raise JudgeError(f"jev HTTP {e.code}") from None
        except (urllib.error.URLError, TimeoutError) as e:
            raise JudgeError(f"jev unreachable: {e}") from None
        self.model = r.get("model", self.model)   # the resolved version, e.g. jev-1.13.0
        return r["answers"]


def make_backend(name: str):
    if name == "mock":
        return MockBackend()
    if name == "laya":
        return LayaBackend()
    if name == "jev":
        return JevBackend()
    raise JudgeError(f"unknown backend {name!r} (mock | laya | jev)")


STRATEGY = os.environ.get("LEX_JUDGE_STRATEGY", "choice")


def noul_margin(nouls: dict) -> tuple[str, float]:
    """Turn per-option yes-probabilities into one decision. The score is the
    weaker of 'the best is a yes' and 'the runner-up is a no', so two options
    both looking right — or none — can never clear a threshold."""
    ranked = sorted(nouls.items(), key=lambda kv: -kv[1])
    best, pb = ranked[0]
    second = ranked[1][1] if len(ranked) > 1 else 0.0
    return best, min(pb, 1 - second)


def decide(backend, task: str, facts: dict, options: list[dict], strategy: str | None = None) -> dict:
    """One judgment. Raises JudgeError instead of ever inventing an answer."""
    strategy = strategy or STRATEGY
    if strategy == "choice":
        questions = build_question(task, options)
        offered = set(questions["next"]["criteria"])
    elif strategy == "nouls":
        questions = build_nouls(task, options)
        offered = {k[len(NOUL_PREFIX):] for k in questions}
    else:
        raise JudgeError(f"unknown strategy {strategy!r} (choice | nouls)")
    t0 = time.perf_counter()
    answers = backend.answers(task, facts, questions)
    ms = (time.perf_counter() - t0) * 1000
    if strategy == "choice":
        probs = {k: float(v) for k, v in answers["next"]["probabilities"].items()}
        if not probs:
            raise JudgeError("backend returned no probabilities")
        choice = max(probs, key=probs.get)
        p = probs[choice]
    else:
        probs = {k[len(NOUL_PREFIX):]: float(a["noul"]) for k, a in answers.items()
                 if k.startswith(NOUL_PREFIX)}
        if set(probs) != offered:
            raise JudgeError("backend did not answer every option")
        choice, p = noul_margin(probs)
    if choice not in offered:
        # A backend answering outside the offered set is broken, not creative.
        raise JudgeError(f"backend chose {choice!r}, which was not offered")
    return {"ok": True, "choice": choice, "p": round(p, 4), "strategy": strategy,
            "probabilities": {k: round(v, 4) for k, v in probs.items()},
            "backend": backend.name, "model": backend.model,
            "latency_ms": round(ms, 1), "mock": backend.mock}


# ── HTTP ─────────────────────────────────────────────────────────────────────

def make_handler(backend):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, obj):
            data = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path == "/health":
                self._send(200, {"ok": True, "backend": backend.name,
                                 "model": backend.model, "mock": backend.mock})
            else:
                self._send(404, {"ok": False, "error": "not found"})

        def do_POST(self):
            if self.path != "/judge/next_skill":
                self._send(404, {"ok": False, "error": "not found"})
                return
            try:
                n = int(self.headers.get("Content-Length", "0"))
                req = json.loads(self.rfile.read(n) or b"{}")
                out = decide(backend, req.get("task", ""), req.get("facts") or {},
                             req.get("options") or [], req.get("strategy"))
                self._send(200, out)
            except JudgeError as e:
                self._send(200, {"ok": False, "error": str(e)})
            except Exception as e:  # noqa: BLE001 — report, never guess
                self._send(200, {"ok": False, "error": f"{type(e).__name__}: {e}"})

    return Handler


def main():
    import perimeter  # same bind guard as the robot sidecar
    perimeter.assert_loopback(HOST)
    backend = make_backend(BACKEND)
    srv = ThreadingHTTPServer((HOST, PORT), make_handler(backend))
    print(f"judge_sidecar: backend={backend.name} model={backend.model} strategy={STRATEGY} on {HOST}:{PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
