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
    ap.add_argument("--arm-mode", choices=("clip", "deny"), default="clip",
                    help="what a violating arm step does once walls are active: clip to the "
                         "boundary, or deny the whole delta like the real gate (default: clip)")
    ap.add_argument("--deny-from", type=float, default=None,
                    help="fraction of training at which arm violations switch from clip to deny "
                         "(e.g. 0.85 = deny during the hold phase only; default: no switch)")
    ap.add_argument("--grant-pull", type=float, default=0.0,
                    help="always-on soft cost per metre the arm offset sits outside the FINAL "
                         "grant box, from step 0 (0 = off). Shapes strategy toward near-body "
                         "reaches without hard walls; keep well below the wall PENALTY_SCALE (5.0)")
    ap.add_argument("--grant-pull-end", type=float, default=None,
                    help="anneal the pull linearly from --grant-pull down to this value over the "
                         "run (default: constant pull). Strong early breaks the stretch; the decay "
                         "lets the deterministic policy stabilize late")
    ap.add_argument("--checkpoint-every", type=int, default=0,
                    help="save a rolling checkpoint every N timesteps (0 = off)")
    ap.add_argument("--resume-from", default=None,
                    help="checkpoint .zip to continue from (pairs with --resume-step)")
    ap.add_argument("--resume-step", type=int, default=0,
                    help="total timesteps already trained by --resume-from; fast-forwards "
                         "the wall-annealing schedule so the walls pick up where they were")
    args = ap.parse_args()

    try:
        from stable_baselines3 import PPO
        from stable_baselines3.common.callbacks import CheckpointCallback
        from stable_baselines3.common.vec_env import DummyVecEnv
    except ImportError as e:
        print(f"error: stable-baselines3 not installed ({e}). `pip install stable-baselines3`.", file=sys.stderr)
        return 1

    from xlerobot_curriculum_env import make_curriculum_env

    # Each env instance anneals against its own share of the budget, so N
    # lockstep copies reach the grant box at the same wall-clock point a
    # single env would. The schedule is anchored to the FULL budget even on
    # resume — resuming replays the remaining timesteps, not the whole run.
    horizon = args.timesteps // args.envs
    start_n = args.resume_step // args.envs

    def make_one():
        e = make_curriculum_env(horizon_steps=horizon, warmup_frac=args.warmup, final_frac=args.final,
                                arm_mode=args.arm_mode, deny_from=args.deny_from, grant_pull=args.grant_pull,
                                grant_pull_end=args.grant_pull_end)
        e.n_steps = start_n
        e._apply_schedule()
        return e

    env = DummyVecEnv([make_one for _ in range(args.envs)])
    env.seed(args.seed)

    if args.resume_from:
        model = PPO.load(args.resume_from, env=env)
        print(f"resumed from {args.resume_from} at ~{args.resume_step} timesteps "
              f"(schedule progress {env.envs[0].progress():.2f})")
    else:
        model = PPO("MlpPolicy", env, verbose=1, seed=args.seed)

    callback = None
    if args.checkpoint_every > 0:
        ckpt_dir = str(Path(args.out).parent)
        callback = CheckpointCallback(save_freq=max(1, args.checkpoint_every // args.envs),
                                      save_path=ckpt_dir, name_prefix="curr_ckpt")
    remaining = args.timesteps - args.resume_step
    model.learn(total_timesteps=max(1, remaining), progress_bar=False, callback=callback,
                reset_num_timesteps=not args.resume_from)
    model.save(args.out)
    print(f"saved curriculum-trained policy: {args.out}")
    print(f"evaluate it: python3 gym_env/xlerobot_rl_eval.py {args.out} /tmp/xlerobot_rl_rollout.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
