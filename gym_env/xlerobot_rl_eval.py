#!/usr/bin/env python3
"""Run a TRAINED policy (sidecar/xlerobot_rl_train.py) closed-loop against
`LexXLeRobotFetch-v0` and write its rollout in the exact format
gym_env/xlerobot_policy_eval.py writes — the replay/verify/reputation
pipeline (examples/xlerobot_policy_rollout.lex, the lex-games `robot_task`
referee, examples/agent_registry.lex) is agnostic to how the policy was
produced; this is the "future RL-trained policy" that file's docstring
already promised plugs into the same rollout format.

Resolution mismatch, handled honestly: training runs at the env's raw
per-tick action rate (up to MAX_STEPS ticks/episode, ~0.02m EE deltas and
bounded base velocity per tick) — far finer-grained than the governed skill
surface's discrete move_base / move_arm / grasp_arm calls, and replaying
every single tick as its own governed command would blow the rollout
replay's budget_actions cap (100-200, see xlerobot_policy_rollout.lex) for
no added insight. So this DOWNSAMPLES: every CHECKPOINT_EVERY ticks (and at
episode end), it emits one move_base + one move_arm step reflecting the
policy's actual position at that tick — a real waypoint on the policy's real
trajectory, not a fabricated one — plus a single grasp step the first tick
`info["holding"]` goes true. If a checkpoint's position happens to be outside
the grant's workspace/floor-area box, the governed replay will legitimately
DENY that step — that's the grant catching an out-of-envelope policy action,
not a bug in this script (same "ungoverned vs governed" property the
keep-out zone demo shows).

The trained policy never learned a "carry it home" phase (the env
terminates the instant the cup is lifted), so unlike the scripted baseline
this rollout does not fabricate one — it ends wherever the policy's episode
actually ended.

Usage: python3 gym_env/xlerobot_rl_eval.py [model.zip] [out.json] [--stochastic]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import gymnasium  # noqa: E402
import xlerobot_env  # noqa: E402,F401 — registers LexXLeRobotFetch-v0

CHECKPOINT_EVERY = 25
GRASP_FORCE_N = 15.0  # matches the arm grant's max_grip_force ceiling


def step(skill, x=0.0, y=0.0, z=0.0, speed=0.0, force=0.0, sim_outcome=""):
    """Same uniform step shape gym_env/xlerobot_policy_eval.py writes."""
    return {"skill": skill, "x": x, "y": y, "z": z, "speed": speed, "force": force, "sim_outcome": sim_outcome}


def run_policy(model_path, deterministic=True, max_steps=600):
    try:
        from stable_baselines3 import PPO
    except ImportError as e:
        raise SystemExit(f"stable-baselines3 not installed ({e}). `pip install stable-baselines3`.")

    env = gymnasium.make("LexXLeRobotFetch-v0")
    model = PPO.load(model_path)
    obs, _ = env.reset()
    raw = env.unwrapped

    rollout = []
    grasp_emitted = False
    total_reward = 0.0
    ticks = 0
    terminated = truncated = False

    for ticks in range(1, max_steps + 1):
        action, _ = model.predict(obs, deterministic=deterministic)
        obs, reward, terminated, truncated, info = env.step(action)
        total_reward += float(reward)

        if not grasp_emitted and info.get("holding"):
            rollout.append(step("grasp", force=GRASP_FORCE_N, sim_outcome="reached"))
            grasp_emitted = True

        if ticks % CHECKPOINT_EVERY == 0 or terminated or truncated:
            base_x, base_y = float(obs[0]), float(obs[1])
            ee_x, ee_y, ee_z = (float(v) for v in raw.ee_off)
            rollout.append(step("move_base", x=base_x, y=base_y, speed=0.4, sim_outcome="reached"))
            rollout.append(step("move_arm", x=ee_x, y=ee_y, z=ee_z, sim_outcome="reached"))

        if terminated or truncated:
            break

    success = bool(terminated)  # the env terminates exactly when the cup is lifted
    return rollout, success, total_reward, ticks


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model", nargs="?", default="/tmp/xlerobot_ppo.zip")
    ap.add_argument("out", nargs="?", default="/tmp/xlerobot_rl_rollout.json")
    ap.add_argument("--stochastic", action="store_true", help="sample actions instead of taking the argmax/mean")
    ap.add_argument("--max-steps", type=int, default=600)
    args = ap.parse_args()

    rollout, success, total_reward, ticks = run_policy(
        args.model, deterministic=not args.stochastic, max_steps=args.max_steps
    )
    with open(args.out, "w") as f:
        json.dump({"policy": "did:lex:policy:xlerobot-ppo-trained", "steps": rollout}, f)
    print(
        f"RL policy eval: {'SUCCESS' if success else 'FAILED'} — {ticks} env ticks, "
        f"{len(rollout)} governed rollout steps (downsampled every {CHECKPOINT_EVERY} ticks), "
        f"episode return {total_reward:.2f}"
    )
    print(f"rollout written: {args.out}")
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
