#!/usr/bin/env python3
"""Retrain an existing XLeRobot policy using ACTUAL USAGE DATA — a real
governed rollout's denial pattern — as the training signal.

Closes the loop `sidecar/xlerobot_rl_train.py` opened: that script trains
against the raw, ungoverned env, so nothing stops the policy's arm reach
from drifting outside the workspace box it's actually held to at replay
time (see README — the first trained policy solved the task in physics and
then had every `move_arm` call denied). This script:

  1. Reads a real trail JSONL from `examples/xlerobot_policy_rollout.lex`
     (produced by replaying a policy's rollout through the actual grant
     gate) via `gym_env/xlerobot_usage_log.py`, and derives per-axis
     penalty weights from which axis usage actually violated most.
  2. Loads the EXISTING trained policy (warm start — keeps its
     task-solving competence) and continues training
     (`reset_num_timesteps=False`) against `LexXLeRobotFetchGoverned-v0`
     (gym_env/xlerobot_governed_env.py), which clips + penalizes exactly
     the violations that usage log showed, weighted toward the axes real
     usage actually hit hardest.
  3. Saves the retrained policy. Re-run `xlerobot_rl_eval.py` + the grant
     replay on the new checkpoint to see whether the denial rate actually
     dropped — this script does not claim success, only that the training
     signal now includes real usage feedback.

Without --usage-log, all axes are weighted equally (1.0x) — still a real
governed-training pass, just not informed by a specific recorded rollout's
failure pattern.

Usage:
    python3 gym_env/xlerobot_usage_log.py /tmp/trail.jsonl --json > /tmp/usage.json
    python3 sidecar/xlerobot_rl_finetune.py /tmp/xlerobot_ppo.zip \
        --usage-log /tmp/usage.json --timesteps 100000 --out /tmp/xlerobot_ppo_v2.zip
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "gym_env"))

import gymnasium  # noqa: E402
import xlerobot_governed_env  # noqa: E402,F401 — registers LexXLeRobotFetchGoverned-v0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model", help="existing checkpoint to continue training (warm start)")
    ap.add_argument("--usage-log", help="JSON summary from `xlerobot_usage_log.py --json`")
    ap.add_argument("--timesteps", type=int, default=100_000, help="additional training timesteps (default: 100k)")
    ap.add_argument("--envs", type=int, default=4)
    ap.add_argument("--out", default="/tmp/xlerobot_ppo_finetuned.zip")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    try:
        from stable_baselines3 import PPO
        from stable_baselines3.common.env_util import make_vec_env
    except ImportError as e:
        print(f"error: stable-baselines3 not installed ({e}). `pip install stable-baselines3`.", file=sys.stderr)
        return 1

    axis_weights = {}
    if args.usage_log:
        with open(args.usage_log) as f:
            axis_weights = json.load(f).get("axis_weights", {})
        print(f"usage-informed axis weights: {axis_weights}")
    else:
        print("no --usage-log given — training against the governed env with uniform (1.0x) axis weights")

    env = make_vec_env(
        "LexXLeRobotFetchGoverned-v0",
        n_envs=args.envs,
        seed=args.seed,
        env_kwargs={"axis_weights": axis_weights},
    )
    model = PPO.load(args.model, env=env)
    model.learn(total_timesteps=args.timesteps, reset_num_timesteps=False, progress_bar=False)
    model.save(args.out)
    print(f"saved retrained policy: {args.out}")
    print(f"re-evaluate it: python3 gym_env/xlerobot_rl_eval.py --stochastic {args.out} /tmp/xlerobot_rl_rollout_v2.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
