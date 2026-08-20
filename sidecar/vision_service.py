#!/usr/bin/env python3
"""vision_service — the GPU half of the split-compute vision path.

Runs on the machine with the model horsepower (a Mac Studio serving Ollama,
a Jetson, any box exposing an OpenAI-compatible chat API) and answers vision
JUDGMENTS about frames the robot's sidecar captured. The split follows the
line the repo already draws (see README's fridge-report discussion): the
camera read on the robot is the [sense] effect; interpreting a photo already
in hand is judgment on existing data — so it can honestly live off-robot.

Contract — /vision/describe matches examples/skills_api_stub.py exactly, so
src/skills.lex `list_visible_items` works against this service unchanged:

    GET  /health                          -> {"ok": true, "model": "...", "mock": bool}
    POST /vision/describe {"image_b64"}   -> {"items": ["...", ...]}
    POST /vision/detect   {"image_b64", "name"}
         -> {"found": bool, "cx","cy","w","h", "confidence", "detail"}
            cx/cy/w/h are the object's bounding box, NORMALIZED 0..1
            (center + size) in the frame — 2D image coordinates, honestly
            NOT a 3D pose. Turning a box into a world position needs depth
            or calibration the caller must bring.

Model access is one OpenAI-compatible chat-completions call with the frame
attached as a data: URL. That single surface covers:
  * Ollama natively         LEX_VISION_LLM_URL=http://127.0.0.1:11434/v1
  * anything behind LiteLLM LEX_VISION_LLM_URL=http://127.0.0.1:4000/v1
    (OpenAI, vLLM, opencode-served models, ... — LiteLLM normalizes them)
No SDK — stdlib urllib only, so the service deploys with `python3` alone.

Env:
    LEX_VISION_HOST        bind address (default 0.0.0.0 — this is a LAN
                           service by design; bind to a network you own.
                           Same no-auth posture as the sidecar, one step
                           wider — see deploy/VISION_SPLIT.md.)
    LEX_VISION_PORT        default 8901
    LEX_VISION_LLM_URL     OpenAI-compatible base URL
                           (default http://127.0.0.1:11434/v1 — Ollama)
    LEX_VISION_MODEL       vision-capable model tag (default qwen2.5vl:7b;
                           llava, minicpm-v, or a LiteLLM route all work)
    LEX_VISION_API_KEY     optional bearer token (LiteLLM virtual keys;
                           Ollama ignores it)
    LEX_VISION_TIMEOUT_S   upstream call budget (default 60)
    LEX_VISION_MOCK=1      canned answers, no model consulted — CI and
                           bench-without-GPU. Every mock reply says so in
                           its content; this service never fakes sight
                           silently.
"""

import json
import os
import re
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("LEX_VISION_HOST", "0.0.0.0")
PORT = int(os.environ.get("LEX_VISION_PORT", "8901"))
LLM_URL = os.environ.get("LEX_VISION_LLM_URL", "http://127.0.0.1:11434/v1").rstrip("/")
MODEL = os.environ.get("LEX_VISION_MODEL", "qwen2.5vl:7b")
API_KEY = os.environ.get("LEX_VISION_API_KEY", "")
TIMEOUT_S = float(os.environ.get("LEX_VISION_TIMEOUT_S", "60"))
MOCK = os.environ.get("LEX_VISION_MOCK", "0") == "1"

MOCK_ITEMS = ["(mock) a cup", "(mock) a plate", "(mock) a folded towel"]

DESCRIBE_PROMPT = (
    "List the distinct physical items visible in this photo. Reply with ONLY "
    "a JSON array of short item names (strings), no prose, no markdown fence."
)

# Deliberately phrased as an OUTCOME question, not a localization one: the
# judge must not simply re-run the detector's reasoning. See sidecar/
# episode_verifier.py -- correlated errors between the model that acted and
# the model that grades would read as success.
JUDGE_PROMPT = (
    "You are grading whether a robot completed a task. Task: {question}\n"
    "Look at the photo and decide. Be strict: if you cannot clearly see that "
    "the task was completed, answer false. Reply with ONLY a JSON object, no "
    'prose, no markdown fence: {{"success": true/false, "confidence": 0..1, '
    '"reason": "one short sentence"}}'
)

DETECT_PROMPT = (
    "Locate the {name} in this photo. Reply with ONLY a JSON object, no prose, "
    'no markdown fence: {{"found": true/false, "cx": 0..1, "cy": 0..1, '
    '"w": 0..1, "h": 0..1, "confidence": 0..1}} where cx/cy is the bounding-box '
    "center and w/h its size, all normalized to the image dimensions. If the "
    'object is not visible, reply {{"found": false}}.'
)


def _chat(image_b64, prompt, model=None):
    """One OpenAI-compatible chat-completions call with the frame attached.

    *model* overrides LEX_VISION_MODEL for this call — /vision/judge uses it so
    an episode can be graded by a DIFFERENT model than the one that drove it.

    Raises on transport/HTTP errors; returns the assistant text otherwise.
    """
    content = [{"type": "text", "text": prompt}]
    if image_b64:
        content.append({
            "type": "image_url",
            "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"},
        })
    body = json.dumps({
        "model": model or MODEL,
        "messages": [{"role": "user", "content": content}],
        "temperature": 0,
    }).encode()
    headers = {"Content-Type": "application/json"}
    if API_KEY:
        headers["Authorization"] = f"Bearer {API_KEY}"
    req = urllib.request.Request(f"{LLM_URL}/chat/completions", data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        out = json.loads(resp.read())
    return out["choices"][0]["message"]["content"]


def _extract_json(text, opener, closer):
    """Pull the first JSON value delimited by opener/closer out of model text.

    VLMs wrap JSON in prose or ```fences``` often enough that strict parsing
    of the whole reply would fail on honest answers; slicing the outermost
    delimiters is the standard robust middle ground.
    """
    start = text.find(opener)
    end = text.rfind(closer)
    if start == -1 or end == -1 or end <= start:
        raise ValueError(f"no {opener}...{closer} JSON in model reply: {text[:200]!r}")
    return json.loads(text[start:end + 1])


def _clamp01(v):
    try:
        return min(1.0, max(0.0, float(v)))
    except (TypeError, ValueError):
        return 0.0


def describe(image_b64):
    if MOCK:
        return {"items": MOCK_ITEMS}
    if not image_b64:
        return {"error": "empty image_b64 — the sidecar's camera produced no frame"}
    try:
        reply = _chat(image_b64, DESCRIBE_PROMPT)
        items = _extract_json(reply, "[", "]")
    except Exception as e:
        return {"error": f"vision model failed: {e}"}
    return {"items": [str(x) for x in items if str(x).strip()]}


def detect(image_b64, name):
    if not name:
        return {"found": False, "detail": "detect needs a non-empty object name"}
    if MOCK:
        return {"found": True, "cx": 0.62, "cy": 0.55, "w": 0.18, "h": 0.22,
                "confidence": 0.99,
                "detail": "(mock) canned detection — no model consulted"}
    if not image_b64:
        return {"found": False,
                "detail": "empty image_b64 — the sidecar's camera produced no frame"}
    # A model prompted for {name} sees the literal braces in DETECT_PROMPT's
    # JSON example, hence the doubled {{ }} in the template above.
    prompt = DETECT_PROMPT.format(name=re.sub(r"[^\w \-]", "", name))
    try:
        reply = _chat(image_b64, prompt)
        box = _extract_json(reply, "{", "}")
    except Exception as e:
        return {"found": False, "detail": f"vision model failed: {e}"}
    if not box.get("found"):
        return {"found": False, "detail": f"model reports no '{name}' visible"}
    return {"found": True,
            "cx": _clamp01(box.get("cx")), "cy": _clamp01(box.get("cy")),
            "w": _clamp01(box.get("w")), "h": _clamp01(box.get("h")),
            "confidence": _clamp01(box.get("confidence", 0.5)),
            "detail": f"model {MODEL}"}


def judge(image_b64, question, model=None):
    """Grade an outcome from a frame. A JUDGMENT about data already in hand —
    exactly the split this service exists to serve (see module docstring)."""
    if not question:
        return {"success": False, "confidence": 0.0,
                "detail": "judge needs a non-empty question"}
    if MOCK:
        return {"success": True, "confidence": 0.99,
                "reason": "(mock) canned verdict — no model consulted",
                "detail": "(mock) canned verdict — no model consulted"}
    if not image_b64:
        return {"success": False, "confidence": 0.0,
                "detail": "empty image_b64 — the sidecar's camera produced no frame"}
    prompt = JUDGE_PROMPT.format(question=re.sub(r"[^\w \-.,?']", "", question))
    try:
        reply = _chat(image_b64, prompt, model=model)
        v = _extract_json(reply, "{", "}")
    except Exception as e:
        return {"success": False, "confidence": 0.0, "detail": f"vision model failed: {e}"}
    return {"success": bool(v.get("success")),
            "confidence": _clamp01(v.get("confidence", 0.5)),
            "reason": str(v.get("reason", ""))[:200],
            "detail": f"model {model or MODEL}"}


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/health":
            return self._json(200, {"ok": True, "model": MODEL, "mock": MOCK,
                                    "llm_url": LLM_URL})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        try:
            args = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._json(400, {"error": "invalid json"})
        path = self.path.split("?", 1)[0]
        if path == "/vision/describe":
            return self._json(200, describe(args.get("image_b64", "")))
        if path == "/vision/detect":
            return self._json(200, detect(args.get("image_b64", ""), args.get("name", "")))
        if path == "/vision/judge":
            return self._json(200, judge(args.get("image_b64", ""), args.get("question", ""),
                                         args.get("model") or None))
        return self._json(404, {"error": "not found"})

    def log_message(self, *a):
        print("[vision]", self.command, self.path)


def main():
    mode = "MOCK (no model)" if MOCK else f"{MODEL} via {LLM_URL}"
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot vision service [{mode}] on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
