"""HTTP server wrapping BazaarEnv — called by the Lex sidecar when PHYSICS_URL is set.

Endpoints:
  POST /reset              — reset simulation, returns robot_state
  POST /skill              — {"skill": "move_to", "args": {"stall": "pottery"}}
  GET  /state              — current robot_state
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

# Allow importing bazaar_env from the same directory
sys.path.insert(0, str(Path(__file__).parent))

from bazaar_env import BazaarEnv
from flask import Flask, jsonify, request

app = Flask(__name__)
env = BazaarEnv()
env.reset()

SKILL_MAP = {
    "move_to":     lambda args: env.skill_move_to(args.get("stall", "")),
    "scan_area":   lambda args: env.skill_scan_area(),
    "robot_state": lambda args: env.skill_robot_state(),
}


@app.post("/reset")
def reset():
    env.reset()
    return jsonify(env.skill_robot_state())


@app.post("/skill")
def skill():
    body  = request.get_json(force=True)
    name  = body.get("skill", "")
    args  = body.get("args", {})
    if name not in SKILL_MAP:
        return jsonify({"error": f"unknown skill '{name}'"}), 400
    result = SKILL_MAP[name](args)
    return jsonify(result)


@app.get("/state")
def state():
    return jsonify(env.skill_robot_state())


@app.get("/health")
def health():
    return jsonify({"ok": True})


if __name__ == "__main__":
    port = int(os.environ.get("PHYSICS_PORT", "9000"))
    print(f"[physics] BazaarEnv server on :{port}", flush=True)
    app.run(host="0.0.0.0", port=port, threaded=False)
