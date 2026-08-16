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

> Machine-readable companion: [`docs/experiments.jsonl`](experiments.jsonl)
> — one JSON object per attempt (config, eval results, denial profile),
> appended via `gym_env/xlerobot_experiment_ledger.py append` and
> summarized with `... show`. This table stays the narrative; the ledger
> is the queryable record (and imports cleanly into MLflow-style tools
> later). Committed to git because that is the only store that survives
> the ephemeral containers these runs actually happen in.

The mechanism runs correctly end to end — verified in isolation (forcing
max-delta actions drives `ee_off` to exactly the workspace boundary,
never beyond) — and has been run for real thirteen times so far, at
increasing seriousness. None has yet converged to a policy that is both
compliant *and* successful within the budget used: attempt 5 settled
the "is the budget the problem?" half of the question, attempt 6
settled the "does the finetune just need a competent starting point?"
half, attempt 7 (curriculum) is the first to keep the task solved
while eliminating whole axes of violation, attempts 8–9 showed that
deploy-faithful deny semantics is *bad training* semantics in every
dose tried — during the anneal or as a final hold phase — and
attempt 10 (grant-pull reward shaping) is the first to push the denial
rate below 50% and break the 0.75m x-lean plateau.

| # | train | finetune | denial rate before → after | notes |
|---|---|---|---|---|
| 1 | (warm start from an earlier checkpoint) | 30k timesteps | — | smoke test of the mechanism only |
| 2 | (same checkpoint) | 250k timesteps | flat | penalty alone wasn't enough to change strategy; kept violating the box exactly as before |
| 3 | (same checkpoint) | 250k timesteps, **after a reward bug fix** | flat, but stopped violating | see bug note below — stopped violating the box by no longer solving the task either, trading away its only learned strategy without finding an in-bounds replacement |
| 4 | 200k timesteps (fresh) | 100k timesteps | 69% (33/48) → 50% (24/48) | see below — real improvement this time, still not solved |
| 5 | **2M timesteps (fresh)** | none yet | 44–50% (4/8–4/9) | see below — **first policy to solve the task on the deterministic eval**; compliance still open |
| 6 | 2M timesteps (fresh, replicates 5) | **500k timesteps from the competent baseline** | 50% → 50%, task competence **lost** | see below — the strongest evidence yet for the geometric hypothesis |
| 7 | **3M timesteps, curriculum (walls anneal wide → grant)** | (single run, no separate finetune) | 50%, but y violations **eliminated**, z at 2cm noise | see below — task competence **kept** (det SUCCESS); residual is x-only "leaning on the wall" |
| 8 | 3M timesteps, curriculum + **deny-mode walls** | (single run) | 73%, task competence **destroyed mid-anneal** | see below — solved at 1M (walls still wide), dead by 2M; deny's frozen-arm plateau starves the anneal of gradient |
| 9 | 3M timesteps, **clip anneal → deny hold** (`--deny-from 0.85`) | (single run) | 50%, task competence **destroyed by the deny hold** | see below — SUCCESS at 2.5M with walls 97% closed (clip); dead within 200k steps of the deny switch |
| 10 | 3M timesteps, clip curriculum + **grant-pull 0.4** | (single run) | **46%** — first below 50%; x-overshoot mean 0.410m (was ~0.75m) | see below — stochastic SUCCESS, deterministic FAILED; the residual violation flipped from far-stretch to a small inner-bound tuck |
| 11 | 3M timesteps, clip curriculum + **grant-pull 0.2** | (single run) | 50%, x-overshoot back at 0.744m | see below — deterministic SUCCESS recovered; pull strength directly trades competence against compliance |
| 12 | 3M timesteps, clip curriculum + **pull anneal 0.5 → 0.1** | (single run) | 50%, x-overshoot 0.410m | see below — no better than constant 0.4; deep parking achieved but the argmax policy freezes in the inner-bound tuck |
| 13 | **6M timesteps**, clip curriculum + pull 0.4 | (single run) | 50%, **both evals FAILED**, z drifts out | see below — more time entrenches the tuck; refutes the "more time converges" precedent for shaped landscapes. First entry with **committed, notebooklab-verified evidence** |

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

**Attempt 6 — the finetune, finally given a competent starting point**:
attempts 1–4 finetuned weak policies, so "it traded away the task"
(attempt 3) was ambiguous — maybe there was just nothing worth
preserving. This run removed that ambiguity: a fresh 2M-timestep
baseline (replicating attempt 5 almost exactly — deterministic
`SUCCESS`, 50% denial, x 0.749m / y 0.476m mean overshoot), then a
500k-timestep usage-informed finetune warm-started from it, with
penalty weights from the baseline's own real denial trail (x 1.22x,
y 0.78x). The result is unambiguous — and negative:

```
== baseline (2M) ==       SUCCESS (det), 50% denial (4/8), 9 governed steps
== after finetune ==      FAILED det (-218.62) and stochastic (-243.77), full 600 ticks
actions: 48  denied: 24  denial rate: 50%
  move_to.y: 20 violations, mean overshoot 0.603m  (was 0.476m — worse)
  move_to.x: 19 violations, mean overshoot 0.358m  (was 0.749m — better)
  move_to.z:  9 violations, mean overshoot 0.010m  (negligible)
```

The finetuned policy parks the base at one spot and oscillates its arm
out-of-bounds without ever lifting — exactly attempt 3's failure mode,
reproduced from a genuinely competent start. Even with real competence
to preserve, 500k timesteps of clip-and-penalize destroyed the lift
without buying a single point of denial rate.

**Attempt 7 — curriculum: walls wide first, annealed to the grant box
(`sidecar/xlerobot_rl_curriculum.py` + `gym_env/xlerobot_curriculum_env.py`)**:
the first structural candidate, built and run: one continuous 3M-timestep
PPO session where the arm box starts wide enough for attempt 5's winning
ungoverned strategy, holds there for the first 35% of training, anneals
linearly to the *exact* grant bounds by 85%, and stays there. (Building
this surfaced a second latent bug, fixed on its own merits: the governed
wrapper's base-clip wrote `qvel` at a `qpos` address — the cup freejoint
takes 7 qpos slots but 6 DOFs — crashing the first time a training run's
base actually crossed the floor bounds, which attempts 1–6 never did.)

```
== deterministic eval ==   SUCCESS — 98 ticks, return -94.57   (competence KEPT)
== stochastic eval ==      SUCCESS — 372 ticks, return -218.94
== grant-gate replay ==    9 governed steps, 4/8 denied (50%)
  move_to.x: 4 violations, mean overshoot 0.789m, max 1.509m
  move_to.z: 2 violations, mean overshoot 0.021m   (2cm — boundary noise)
  move_to.y: 0 violations                          (was 4 in attempt 5)
```

Read honestly, this is the first genuinely mixed-positive result:
unlike attempt 6, the curriculum **kept the task solved** while training
against the real box, and it **eliminated the y-axis violations
entirely** (z is 2cm noise). The residual is one axis, x — and its shape
is diagnostic: the replayed `move_arm` targets march x outward
0.5 → 1.0 → 1.5 → 1.96 while y/z stay in-box. The policy learned to
**lean on the wall**: during training the clip absorbs the excess
(overshoot per step is capped at one EE_DMAX = 2cm, so the penalty per
step is tiny) and the *effective* clipped position is good enough to
lift from — but at deploy time the real gate doesn't clip, it **denies**
(refuse, don't downgrade), so the same commanded targets bounce.

**Attempt 8 — deny-mode walls (`arm_mode="deny"`)**: attempt 7's
residual pointed at a semantics mismatch — training clips a violating
step to the boundary (you get most of what you asked for), the real
gate denies it whole (you get nothing). So `GovernedXLeRobotFetchEnv`
grew an `arm_mode="deny"` that rejects the entire arm delta on
violation, with one escape hatch for curriculum annealing (a strictly
inward move from an already-outside position is accepted, else the
walls sweeping past the arm would freeze it out-of-bounds forever).
Same 3M curriculum schedule as attempt 7, deny active whenever a wall
is hit. The result is the sharpest negative yet — and the surviving
rolling checkpoints pin down exactly when it went wrong:

```
ckpt @ 1.0M (walls still fully wide):  SUCCESS — 89 ticks, return -93.90
ckpt @ 2.0M (mid-anneal):              FAILED  — 600 ticks, return -306.64
final @ 3.0M (walls at grant):         FAILED  — 600 ticks, return -1913.43
replay: 48 actions, 35 denied (73%) — arm commands diverged to ±7m,
        base drove off the floor area (11 move_base.y denials)
```

The task was learned perfectly in the wide phase and destroyed during
the anneal — the identical schedule clip mode survived. The mechanism
is visible in the numbers: when the walls sweep inward under deny, most
steps get *zero* movement (frozen arm), the dense `-distance` gradient
that carried attempt 7 through the anneal goes flat, and PPO diverges
into commanding ever-larger offsets. **Deploy-faithful semantics is bad
training semantics**: the gate's refuse-don't-downgrade is right for
deployment precisely because it is absolute, and absolute is exactly
what a gradient can't climb.

**Attempt 9 — clip through the anneal, deny only at the hold
(`--deny-from 0.85`)**: the attempts-7/8 synthesis, run as designed.
The rolling checkpoints tell the whole story:

```
ckpt @ 2.0M (mid-anneal, clip):        SUCCESS — return -94.00
ckpt @ 2.5M (walls 97% closed, clip):  SUCCESS — return -94.23
ckpt @ 2.75M (200k into deny hold):    FAILED  — return -225.29
final @ 3.0M:                          FAILED  — return -316.25 (park-and-oscillate)
```

The clip-anneal did exactly what attempt 7 established: at 2.5M the
policy solved the task with the training walls 97% of the way to the
grant box, and its grant-gate replay is the best combined profile of
any policy so far — 50% denial with y down to 7.7cm mean overshoot and
z at 2cm, x still leaning at 0.744m. Then the deny switch destroyed
task competence **within 200k steps**, from the most favorable starting
point the mechanism will ever get: competent, 97%-annealed, only the
x-lean left to unlearn. Not attempt 8's divergence — the milder
park-and-oscillate stall of attempts 3/6 — but dead all the same.

The verdict across 8 and 9 is one sentence: **deny semantics destroys
training in every dose tried.** And a second pattern is now visible
across attempts 5, 7, and 9: every clip-trained policy converges to the
*same* x-lean (~0.75m mean commanded overshoot) — the shallow-park,
long-reach strategy is what this reward landscape locally prefers, and
walls alone (soft or hard) do not dislodge it.

**Attempt 10 — grant-pull reward shaping (`--grant-pull 0.4`)**: the
walls were being asked to do a job the *reward* should be doing —
nothing distinguished a far reach from a near one, so the base parked
shallow and the arm did the traveling. `grant_pull` is an always-on
per-step cost of 0.4/metre for however far `ee_off` sits outside the
*final* grant box (zero anywhere inside it — legal reaches are
bit-identically unaffected, verified), active from step 0 even while
the curriculum walls are wide. Same 3M clip-curriculum recipe as
attempt 7 otherwise. First run to move the compliance needle:

```
== deterministic eval ==   FAILED  — 600 ticks, return -160.66
== stochastic eval ==      SUCCESS — 98 ticks, return -95.70
== grant-gate replay ==    48 actions, 22 denied (46%)   ← first below 50%
  move_to.x: 22 violations, mean overshoot 0.410m (was ~0.75m in 5/7/9), max 1.049m
  move_to.z:  3 violations, mean overshoot 0.005m (5mm — noise)
  move_to.y:  0 violations
```

Three real changes at once: the denial rate dropped below 50% for the
first time, the x-overshoot plateau (~0.75m across every clip-trained
policy) nearly halved, and the violation *flipped sides* — the denied
arm targets now sit at x ≈ −0.3 to −0.4, a small tuck **below the
box's inner bound** (x-lo = 0.05), not the old 1.5–1.8m stretch past
the outer one. The pull worked: the stretch strategy is gone. The cost
was determinism — the argmax policy no longer lifts (the sampled one
does), echoing attempt 5's pre-convergence behavior rather than the
catastrophic collapses of 6/8/9.

The tuck also surfaced a **grant-design observation** worth flagging
upstream: the arm's rest offset (`HOME_OFF`, x = 0) lies *outside* the
granted box (x-lo = 0.05), so every gentle ramp-in from rest is denied
by construction until the commanded x crosses 0.05 — some of attempt
10's denials are this artifact, not policy misbehavior. Whether x-lo
should be 0.0 is a grant-policy decision for the repo owner, not
something training code should decide.

**Attempt 11 — the pull halved (`--grant-pull 0.2`)**: a clean
single-variable test of option (a). The result is the sharpest
trade-off curve the series has produced:

```
== deterministic eval ==   SUCCESS — 89 ticks, return -94.43   (recovered)
== stochastic eval ==      SUCCESS — 415 ticks, return -220.90
== grant-gate replay ==    8 actions, 4 denied (50%)
  move_to.x: 4 violations, mean overshoot 0.744m, max 1.329m   (the plateau is back)
  move_to.z: 1 violation, 1mm
  move_to.y: 0 violations
```

Deterministic competence came back — and so did the exact 0.744m
x-lean, to the millimetre of attempts 5/7/9. Read together, attempts
10 and 11 bracket the pull cleanly: at 0.2 the stretch strategy's
basin is still cheaper than re-parking (the policy pays the tax and
keeps stretching); at 0.4 the tax dislodges the stretch but destabilizes
the argmax policy. The x-lean is not noise — it is a strong attractor
whose escape price sits somewhere between 0.2 and 0.4 per metre-step.

**Attempt 12 — the pull anneal (`--grant-pull 0.5 --grant-pull-end 0.1`)**:
option (a) from the bracket, run as designed — start above the known
escape price, end below the destabilization threshold:

```
== deterministic eval ==   FAILED  — 600 ticks, return -204.39
== stochastic eval ==      SUCCESS — 472 ticks, return -239.78 (slow)
== grant-gate replay ==    48 actions, 24 denied (50%)
  move_to.x: 22 violations, mean overshoot 0.410m, max 1.549m
  move_to.z:  6 violations, mean overshoot 0.045m
  move_to.y:  0 violations
```

The honest read: **the anneal bought nothing over constant 0.4** —
same 0.410m x-overshoot, denial back at 50%, deterministic still
failing, stochastic success slower than attempt 10's. One genuinely
new behavior appeared in the deterministic trajectory: the base now
**parks deep** (x = 2.88 — the re-parking the whole series was trying
to induce) — but the arm then freezes in the inner-bound tuck
(x ≈ −0.16, below x-lo = 0.05) instead of extending into the box for
the reach. The strategy the pull was meant to teach is half-learned:
drive close ✓, reach in-box ✗. The tuck is a stable local optimum for
the argmax policy at every pull strength ≥0.4-early tried; only
sampling noise escapes it.

**Attempt 13 — attempt 10's recipe at double budget (6M timesteps)**:
the last cheap hypothesis, from the attempt-5 precedent (300k det-FAILED
→ 2M det-SUCCESS on the raw env): give the shaped landscape more time
at fixed conditions and let the argmax policy converge. The opposite
happened:

```
== deterministic eval ==   FAILED — 600 ticks, return -497.13
== stochastic eval ==      FAILED — 600 ticks, return -492.69   (first stoch failure since 9)
== grant-gate replay ==    48 actions, 24 denied (50%)
  move_to.x: 22 violations, mean 0.443m    move_to.z: 17 violations, mean 0.348m
  move_to.y:  5 violations, mean 0.180m
ckpt diag: det SUCCESS at 2M (-94.51) and 3.5M (-94.86); dead by 5M (-362)
```

More time made it worse: the policy over-converged into a stable
hover-tuck (arm at x ≈ −0.07, z ≈ 0.88 — z drifted *out* of the box for
the first time since attempt 8) that not even sampling noise escapes.
The 3.5M checkpoint — deterministic SUCCESS with the pull active,
mid-anneal — replays at the standard attractor profile (50%, x 0.749m),
so no hidden gem either. The attempt-5 precedent does **not** transfer
to shaped landscapes: longer pull exposure entrenches the tuck rather
than polishing the reach.

This attempt is also the series' first with **durable, verifiable
evidence**: its governed-replay trail is committed
(`docs/trails/attempt13.jsonl`) and the run is recorded in
`docs/notebooklab_runs.jsonl` via lex-notebooklab — every claimed
metric re-derived from the trail and `VERIFIED` (`notebooklab verify`,
exit 0). From here on, attempts should be recorded this way.

The back-catalogue has since been migrated into the same store.
Attempts 1–12 were imported from `docs/experiments.jsonl` with
lex-notebooklab's ledger importer; each lands as `UNVERIFIABLE` —
honestly, since those runs' trails died with their containers and
there is nothing to recompute the claims from. The one exception is
attempt 11, whose replay artifacts survived: its governed-replay trail
is committed as `docs/trails/attempt11.jsonl` and a `VERIFIED` record
(all nine claims re-derived bit-exact, including the 0.744 m mean /
1.329 m max x-overshoot) supersedes the imported entry. The trained
policy itself is also preserved: `docs/checkpoints/attempt11.zip`
(sha256 `fc7f1b32fe28…51cb7949`) is the sb3 PPO checkpoint the trail
was replayed from, so the rollout is reproducible end to end, not just
recheckable. So the store
now holds the full series — thirteen attempts, two of them backed by
recomputable evidence — and `notebooklab verify` over the whole store
exits 0.

### Where the series stands after thirteen runs

The apparatus is complete and every cheap hypothesis is tested —
including, as of attempt 13, "just give it more time." What
the thirteen runs establish: walls (fixed, annealed, deny, phase-mixed)
never dislodge the stretch strategy; reward shaping does, reliably —
but at every shaping schedule tried, the deterministic policy lands in
one of two attractors (far-stretch at weak pull, inner-tuck at strong
pull) and only the stochastic policy threads between them. The
remaining ideas are qualitatively different investments, not knob
turns: an **asymmetric pull** (tax the outer bound, leave the inner
approach free — the tuck is only an attractor because the tax field is
symmetric around a box that excludes home), **PPO hyperparameter work**
aimed at deterministic convergence (entropy schedule, learning-rate
decay), a much larger timestep budget, or accepting the stochastic
policy and hardening around it. The apparatus — training loop,
usage-driven retraining, curriculum walls in both semantics, constant
and annealed reward shaping, a committed experiment ledger — is the
durable deliverable; the converged compliant deterministic policy
remains open.
