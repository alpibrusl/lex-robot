#!/usr/bin/env python3
"""Train a real RL policy against `LexXLeRobotFetch-v0` (stable-baselines3 PPO).

Closes the "train" half of the safe-RL/eval loop `gym_env/xlerobot_env.py`
was built for. Until now every "policy" in this repo was either a scripted
geometric controller (`gym_env/xlerobot_policy_eval.py` — its own docstring
says "not a trained network") or *inference* on an already-pretrained
checkpoint (`sidecar/gym_sidecar.py`'s `run_policy`, PushT only). This is the
first actual training loop: standard PPO, off-the-shelf, against the
existing Gymnasium env — no changes to the env, the grant, or the governed
skill surface. The env's action/observation spaces and reward
(`-distance + 10 lift bonus`) were already RL-shaped; this is the trainer
that was missing.

Usage:
    pip install stable-baselines3          # not in sidecar/requirements.txt by
                                            # default — this is the one demo
                                            # that needs it; see there.
    python3 sidecar/xlerobot_rl_train.py --timesteps 200000 --out /tmp/xlerobot_ppo.zip

Then evaluate + roll the trained policy out through the grant gate exactly
like the scripted policy already does:
    python3 gym_env/xlerobot_rl_eval.py /tmp/xlerobot_ppo.zip /tmp/xlerobot_rl_rollout.json
    LEX_ROBOT_HW= examples/xlerobot_policy_run.sh   # (see that script; point
                                                      # ROLLOUT at the file above)

Honest expectations: this is a sparse-ish, contact-rich, real-physics
reach+grasp+lift task with a 4-dimensional continuous action space run for
up to 600 steps/episode — PPO with default hyperparameters and a short
training budget will NOT reliably solve it (peak coverage/success rate
tracked the same way the PushT policy's is in README — "near-spec, not
reliable"). The point of this script is that the training loop is real and
wired end-to-end, not that 200k timesteps produces a mastered policy; scale
--timesteps up (millions, tuned hyperparameters, reward shaping) for that.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "gym_env"))

import gymnasium  # noqa: E402
import xlerobot_env  # noqa: E402,F401 — registers LexXLeRobotFetch-v0 as a side effect


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--timesteps", type=int, default=200_000, help="total training timesteps (default: 200k)")
    ap.add_argument("--envs", type=int, default=4, help="parallel envs (in-process, DummyVecEnv; default: 4)")
    ap.add_argument("--out", default="/tmp/xlerobot_ppo.zip", help="where to save the trained policy")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    try:
        from stable_baselines3 import PPO
        from stable_baselines3.common.env_util import make_vec_env
    except ImportError as e:
        print(f"error: stable-baselines3 not installed ({e}). `pip install stable-baselines3`.", file=sys.stderr)
        return 1

    env = make_vec_env("LexXLeRobotFetch-v0", n_envs=args.envs, seed=args.seed)
    model = PPO("MlpPolicy", env, verbose=1, seed=args.seed)
    model.learn(total_timesteps=args.timesteps, progress_bar=False)
    model.save(args.out)
    print(f"saved trained policy: {args.out}")
    print(f"evaluate it: python3 gym_env/xlerobot_rl_eval.py {args.out} /tmp/xlerobot_rl_rollout.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
