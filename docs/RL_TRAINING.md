# Self-supervised RL: training, governance, and retraining from usage

No joystick, no human demonstrations. This is the self-learning loop for
`LexXLeRobotFetch-v0` (`gym_env/xlerobot_env.py`) — train a policy with
plain PPO, roll it out through the **real grant gate** (no bypass for
being "trained"), turn the resulting denials into a retraining signal, and
finetune against that signal. Moved out of the main README so the README
stays a tour of the repo rather than an RL lab notebook; this is the lab
notebook.

Related code: `sidecar/xlerobot_rl_train.py`, `gym_env/xlerobot_rl_eval.py`,
`examples/xlerobot_policy_rollout.lex`, `gym_env/xlerobot_usage_log.py`,
`sidecar/xlerobot_rl_finetune.py`, `gym_env/xlerobot_governed_env.py`.
Makefile targets: `xlerobot-rl-train`, `xlerobot-rl-run`, `xlerobot-rl-usage`,
`xlerobot-rl-finetune`.

## What the observations are — no camera, no pixels

`LexXLeRobotFetch-v0`'s observation space is `Box(shape=(11,))`:
`[base_x, base_y, left_ee_xyz, right_ee_xyz, cup_xyz]` — privileged
ground-truth simulator state, not camera frames. Action space is
`Box(shape=(6,))`: base vx/vy, left-EE arm-frame dx/dy/dz, a grasp trigger.
Reward is `-distance + 10 lift bonus`; an episode terminates early
(`terminated = bool(lifted)`) the moment the cup is actually lifted, so a
falling `ep_len_mean` during training is a real success signal, not noise.
This is not vision-based RL — training on `read_camera` frames is a
different, harder setup this repo does not currently implement.

## The safe-RL/eval loop, closed (`examples/xlerobot_policy_run.sh`)

The hand-written Fetch-the-Cup mission (`make xlerobot-task`) is a fixed
script. This closes the loop the gym env was built for — **train, roll
out through the grant gate, verify, earn reputation**:

```sh
examples/xlerobot_policy_run.sh /path/to/venv/bin/python   # or no arg: replays the committed fixture
#   [replay] move_base(2.61,1.10) reached
#   [replay] move_arm(0.33,-0.15,0.46) reached
#   [replay] grasp(15N) reached
#   [replay] move_base(0.5,1.5) reached
#   [verify] {"verified":true,"legal":true,"goal_met":true,"score":142}
#   reputation: did:lex:agent:xlerobot-reach-greedy  score=142  apps=['robot']  (credited=1, rejected=0)
```

`gym_env/xlerobot_policy_eval.py` runs a **closed-loop** policy — a reactive
geometric controller today, but state-in/action-out exactly like a trained
one would be — against the same physics core the gym wraps: it *observes*
the cup's position and the base's actual post-drive pose (a
differential-drive base doesn't land on a fixed heading), then *computes*
the arm-reach target from that observation, rather than replaying
memorized waypoints. Its rollout is then **replayed through the actual
grant gate** (`examples/xlerobot_policy_rollout.lex`, reusing
`skills.move_base` / `move_arm` / `grasp_arm`): the policy doesn't get a
bypass — an out-of-grant arm target in the rollout is denied at the
capability layer exactly as it would be for the fixed mission. The
resulting trail is verified by the same `robot_task` referee, and a
verified run is **signed and folded into the durable `did:lex` reputation
registry** (`examples/agent_registry.lex`). Any future policy, hand-coded
or trained, earns reputation the same way: by producing a rollout that
survives the grant gate and replays clean.

## The "train" step, closed for real

`sidecar/xlerobot_rl_train.py` + `gym_env/xlerobot_rl_eval.py`: standard
PPO (stable-baselines3), off the shelf, trained against
`LexXLeRobotFetch-v0` with no changes to the env, the grant, or the
governed skill surface — the env's action/observation spaces and reward
were already RL-shaped; the trainer was the missing piece:

```sh
pip install stable-baselines3          # + mujoco numpy gymnasium
python3 sidecar/xlerobot_rl_train.py --timesteps 300000 --out /tmp/xlerobot_ppo.zip
python3 gym_env/xlerobot_rl_eval.py --stochastic /tmp/xlerobot_ppo.zip /tmp/rollout.json
#   RL policy eval: SUCCESS — 181 env ticks, 17 governed rollout steps (downsampled every 25 ticks), episode return -109.91
examples/xlerobot_rl_run.sh /path/to/venv/bin/python   # roll out -> verify -> reputation
#   [replay] move_base(0.67,1.41) reached
#   [replay] move_arm(0.50,-0.33,0.33) denied: left arm target outside granted workspace
#   [replay] move_base(0.87,1.38) reached
#   [replay] move_arm(1.00,-0.47,0.35) denied: left arm target outside granted workspace
#   ...
#   [replay] grasp(15N) reached
#   ...
#   [verify] {"verified":true,"legal":true,"goal_met":true,"actions":17,"denials":8,"score":91}
#   reputation: did:lex:policy:xlerobot-ppo-trained  score=91  apps=['robot']
```

That output is real, from an actual 300k-timestep training run (measured
locally; not CI-gated). It makes the governance property vivid rather
than theoretical: this policy genuinely **solves the task in raw physics**
(it lifts the cup — `SUCCESS` above is MuJoCo ground truth, not a claim) —
and if it had been deployed ungoverned, every one of its arm reaches
would have executed as commanded. Every single `move_arm` call in this
rollout lands outside the granted workspace box (the policy's EE offset
just accumulates in whatever direction reduces distance to the cup,
unconstrained during training) and is **denied before it reaches the
sidecar** — only `move_base` and the single `grasp` are admitted. A
genuinely successful policy, entirely ungoverned by construction, caught
the same way the keep-out zone demo's synthetic one is. Training doesn't
earn a bypass.

Mechanics: the raw per-tick trajectory is downsampled into governed
`move_base`/`move_arm`/`grasp` calls (finer-grained than the fixed
mission's four waypoints — see `gym_env/xlerobot_rl_eval.py`'s docstring
for exactly how and why). `examples/xlerobot_rl_run.sh` (no venv/model
available) replays the **committed fixture**
(`examples/fixtures/xlerobot_rl_rollout.json` — literally the run shown
above) instead of training+evaluating, mirroring
`examples/xlerobot_policy_run.sh`'s fallback; the ML steps are out-of-band
like the other ML demos, not CI-gated. Two honest caveats: first, 300k
timesteps of default-hyperparameter PPO is a smoke test of the *training
loop*, not a mastered policy — the **deterministic** policy
(`model.predict` without `--stochastic`) reliably fails on this same
seed; only sampled rollouts found the solution the training run
converged toward, so success here is real but not yet robust. Second,
the trail's `verify` event is unconditional (`xlerobot_policy_rollout.lex`
always emits "outcome reached" after replaying every step, regardless of
what physically happened) — the real success/failure signal is the eval
script's own printed line above (`SUCCESS`/`FAILED`, from the sim), not
the referee's `goal_met`.

## Retraining from actual usage data

`gym_env/xlerobot_usage_log.py` + `gym_env/xlerobot_governed_env.py` +
`sidecar/xlerobot_rl_finetune.py`: the policy above solved the task by
drifting its arm reach wherever reduced distance to the cup,
unconstrained — the training loop had no notion of the grant. This closes
that gap using the **denial pattern from a real governed rollout** as the
retraining signal, not a guess:

```sh
python3 gym_env/xlerobot_usage_log.py /tmp/xlerobot_policy_trail.jsonl --json > /tmp/usage.json
#   {"total": 16, "denied": 8, "denial_rate": 0.5,
#    "axis_weights": {"move_to.x": 2.69, "move_to.y": 0.23, "move_to.z": 0.08}}
python3 sidecar/xlerobot_rl_finetune.py /tmp/xlerobot_ppo.zip \
  --usage-log /tmp/usage.json --timesteps 250000 --out /tmp/xlerobot_ppo_v2.zip
```

`xlerobot_usage_log.py` reads the trail every governed replay already
writes (nothing new needed there — `skill`, `args`, `grant`, `outcome`
were already recorded) and computes, per axis, how often and how far it
was denied. `xlerobot_governed_env.py` wraps `LexXLeRobotFetch-v0` with
the *exact same bounds* the grant checks, clipping violations and
applying a penalty weighted by those real per-axis numbers — an axis
usage actually hit hardest gets the strongest training signal, not a
uniform guess. `xlerobot_rl_finetune.py` warm-starts from the existing
checkpoint and continues training against the governed env, so the
retrained policy keeps its task-solving competence while (in principle)
learning to stay inside the envelope it's actually held to.

### Attempt log — honest results, not success claims

The mechanism runs correctly end to end — verified in isolation (forcing
max-delta actions drives `ee_off` to exactly the workspace boundary,
never beyond) — and has been run for real five times so far, at
increasing seriousness. None has yet converged to a policy that is both
compliant *and* successful within the budget used, though attempt 5
settled the "is the budget the problem?" half of the question.

| # | train | finetune | denial rate before → after | notes |
|---|---|---|---|---|
| 1 | (warm start from an earlier checkpoint) | 30k timesteps | — | smoke test of the mechanism only |
| 2 | (same checkpoint) | 250k timesteps | flat | penalty alone wasn't enough to change strategy; kept violating the box exactly as before |
| 3 | (same checkpoint) | 250k timesteps, **after a reward bug fix** | flat, but stopped violating | see bug note below — stopped violating the box by no longer solving the task either, trading away its only learned strategy without finding an in-bounds replacement |
| 4 | 200k timesteps (fresh) | 100k timesteps | 69% (33/48) → 50% (24/48) | see below — real improvement this time, still not solved |
| 5 | **2M timesteps (fresh)** | none yet | 44–50% (4/8–4/9) | see below — **first policy to solve the task on the deterministic eval**; compliance still open |

**Attempt 3's bug, fixed regardless of what came next**: the wrapper's
reward was computed from the *pre-clip* position, so the dominant
`-distance` term kept crediting the violation the penalty was trying to
suppress. Recomputing both reward terms from the corrected (post-clip)
pose was a genuine, needed fix — landed on its own merits, not because it
produced a good result.

**Attempt 4 (this run)**: a fresh 200k-timestep PPO train (not a
warm-started continuation of an old checkpoint), replayed through the
real grant gate, then a 100k-timestep usage-informed finetune from that
checkpoint's own denial pattern. Per-axis violation counts and mean
overshoot, before and after:

```
== before finetune (fresh 200k-timestep policy) ==
actions: 48  denied: 33  denial rate: 69%
  move_to.x:   24 violations, mean overshoot 0.961m, max 1.167m
  move_to.y:   17 violations, mean overshoot 0.869m, max 2.169m
  move_base.y:  9 violations, mean overshoot 0.688m, max 1.336m
  move_to.z:   22 violations, mean overshoot 0.139m, max 0.279m
suggested penalty weights: move_to.x 1.45x, move_to.y 1.31x, move_base.y 1.04x, move_to.z 0.21x

== after finetune (+100k timesteps, usage-weighted) ==
actions: 48  denied: 24  denial rate: 50%
  move_to.x: 22 violations, mean overshoot 0.301m (was 0.961m)
  move_to.z: 24 violations, mean overshoot 0.343m (was 0.139m, slightly worse)
  move_to.y: 0 violations (was 17)
  move_base.y: 0 violations (was 9)
```

Read honestly: the y-axis violations (26 of the original 33 denials)
were fully eliminated, and x-axis overshoot dropped roughly 70%. z got
slightly worse in overshoot magnitude — expected, since the usage log
gave it the *lowest* penalty weight (0.21x, it had the smallest overshoot
last round), so the optimizer spent its budget fixing x/y instead. This
is the clearest evidence yet that the usage-informed signal is real and
directionally correct, not just noise — but neither the before nor after
policy actually **solved** the task in the single deterministic eval
episode (`RL policy eval: FAILED` both times, episode return -289 then
-339). This run was pure local experimentation (temp checkpoints/trails,
not committed) — reproducible via:

```sh
python3 sidecar/xlerobot_rl_train.py --timesteps 200000 --envs 4 --out /tmp/xle.zip
python3 gym_env/xlerobot_rl_eval.py /tmp/xle.zip /tmp/rollout.json
# start sidecar/xlerobot_sidecar.py, then:
lex run --allow-effects net,sense,actuate,io,fs_write,time \
  examples/xlerobot_policy_rollout.lex run '"/tmp/rollout.json"' '"/tmp/trail.jsonl"'
python3 gym_env/xlerobot_usage_log.py /tmp/trail.jsonl --json > /tmp/usage.json
python3 sidecar/xlerobot_rl_finetune.py /tmp/xle.zip --usage-log /tmp/usage.json --timesteps 100000 --out /tmp/xle_v2.zip
```

**Attempt 5 — scale timesteps 10x (2M, ~33 min wall-clock on 4 cores)**:
the training scripts' docstrings had claimed all along that "millions,
not hundreds of thousands" of timesteps were needed for real mastery.
This run tested that claim directly: same PPO, same env, same default
hyperparameters, just `--timesteps 2000000`. It is the first policy in
this repo's history to pass the **deterministic** eval — every earlier
success needed `--stochastic` sampling to stumble onto the solution:

```
== deterministic eval ==
RL policy eval: SUCCESS — 90 env ticks, 9 governed rollout steps, episode return -94.13
== stochastic eval ==
RL policy eval: SUCCESS — 93 env ticks, 9 governed rollout steps, episode return -94.31
```

`ep_len_mean` fell from 600 (never lifts, always truncated) to ~98 over
training — episodes end early only on a real lift, so that curve is
ground-truth task success, not a proxy. Replayed through the real grant
gate, the run is short and efficient (9 governed steps vs 48), and the
denial pattern has *concentrated* rather than vanished:

```
actions: 8  denied: 4  denial rate: 50%   (deterministic; stochastic ≈ same)
  move_to.x: 4 violations, mean overshoot 0.749m, max 1.349m
  move_to.y: 4 violations, mean overshoot 0.476m, max 0.723m
```

Every `move_arm` call in the winning trajectory lands outside the
granted box and is denied before it reaches the sidecar; only the base
drives and the grasp are admitted. Governance holds at full training
scale — 2M timesteps earns exactly as much bypass as 20k did: none.

What attempt 5 settles, honestly: **budget was the blocker for task
mastery, and was never the blocker for compliance.** The policy now
solves the task robustly, and it does so with the exact ungoverned
arm-drift strategy the earlier runs used — more training made that
strategy *better*, not legal. Same temp-file experiment protocol as
attempt 4 (nothing committed); reproducible with the attempt-4 commands
plus `--timesteps 2000000`.

### The likely reason compliance hasn't converged, and what's next

Stated as a hypothesis, not fixed fact: the cup's position may simply not
be reachable from the trained base-approach strategy *within* the
granted workspace box at all — compliance may require the policy to also
change *where the base parks*, not just clamp how far the arm reaches
from wherever it stopped, and nothing in the current reward rewards that
joint change explicitly. Attempt 5 sharpens this: "just more timesteps"
is now tested and does **not** produce compliance on its own, so the
remaining candidates are curriculum learning (train ungoverned until the
task is solved, then gradually tighten the box toward the grant) and a
base-positioning-aware reward term. The natural next experiment is the
usage-informed finetune (attempts 1–4's mechanism) warm-started from
attempt 5's checkpoint — for the first time it would start from a policy
with real competence to preserve, which is the regime that mechanism was
designed for. What exists today is the real thing that was asked for —
an actual training loop and an actual usage-driven retraining mechanism,
correctly implemented and honestly evaluated across five real runs — not
yet a converged compliant policy, which remains the open work.
