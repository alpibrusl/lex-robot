#!/usr/bin/env python3
"""Curriculum training: learn the fetch task with the workspace walls wide
open, then anneal them down to the real grant box during the same run.

The structural follow-up docs/RL_TRAINING.md's attempt log points at:
fixed-wall training (attempts 1-4) and fixed-wall finetuning from a
competent baseline (attempt 6) both fail the same way — the policy
either ignores the walls or forgets the task. This trainer instead runs
one continuous PPO session against `CurriculumXLeRobotFetchEnv`
(gym_env/xlerobot_curriculum_env.py), whose arm box starts wide enough
that the known-winning ungoverned strategy fits, and tightens linearly
to the exact bounds the replay gate checks. Nothing about the grant, the
governed skill surface, or the replay gate changes — training-time
scaffolding only.

Usage:
    pip install stable-baselines3
    python3 sidecar/xlerobot_rl_curriculum.py --timesteps 3000000 --out /tmp/xlerobot_ppo_curr.zip

Then evaluate + replay through the grant gate exactly like every other
policy in this repo:
    python3 gym_env/xlerobot_rl_eval.py /tmp/xlerobot_ppo_curr.zip /tmp/rollout.json
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "gym_env"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--timesteps", type=int, default=3_000_000, help="total training timesteps (default: 3M)")
    ap.add_argument("--envs", type=int, default=4, help="parallel envs (DummyVecEnv; default: 4)")
    ap.add_argument("--warmup", type=float, default=0.35, help="fraction of training with walls fully wide (default: 0.35)")
    ap.add_argument("--final", type=float, default=0.85, help="fraction of training by which walls reach the grant box (default: 0.85)")
    ap.add_argument("--out", default="/tmp/xlerobot_ppo_curr.zip", help="where to save the trained policy")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    try:
        from stable_baselines3 import PPO
        from stable_baselines3.common.vec_env import DummyVecEnv
    except ImportError as e:
        print(f"error: stable-baselines3 not installed ({e}). `pip install stable-baselines3`.", file=sys.stderr)
        return 1

    from xlerobot_curriculum_env import make_curriculum_env

    # Each env instance anneals against its own share of the budget, so N
    # lockstep copies reach the grant box at the same wall-clock point a
    # single env would.
    horizon = args.timesteps // args.envs
    env = DummyVecEnv([
        (lambda: make_curriculum_env(horizon_steps=horizon, warmup_frac=args.warmup, final_frac=args.final))
        for _ in range(args.envs)
    ])
    env.seed(args.seed)

    model = PPO("MlpPolicy", env, verbose=1, seed=args.seed)
    model.learn(total_timesteps=args.timesteps, progress_bar=False)
    model.save(args.out)
    print(f"saved curriculum-trained policy: {args.out}")
    print(f"evaluate it: python3 gym_env/xlerobot_rl_eval.py {args.out} /tmp/xlerobot_rl_rollout.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
