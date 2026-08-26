# Which language, and why

> Policy: **if a thing can be written about as easily in Lex as in Python, it
> is written in Lex.** Python is for what needs Python — torch, drivers,
> cameras, MuJoCo — and for the narrow case where code must run *inside* a
> Python process.
>
> This file is the audit of the whole repo against that rule, so the next
> person porting something knows whether it is a gap or a decision.

## Why it isn't just taste

Lex buys one thing a library cannot: **effects are types, so authority cannot
be acquired by forgetting a check.** That is worth spending a port on wherever
authority is involved, and worth nothing at all in a file that multiplies
tensors.

`src/lelab_adapter.lex` is the worked example. The Python version it replaced
was bounded only because the sidecar it called happened to check the grant; it
had no authority model of its own, and its read-only story was a table of 501
strings written by hand. The Lex version splits along the effect row instead:

| module | effect row | what it can do |
|---|---|---|
| `src/lelab_adapter.lex` | `[env, io, net, sense]` | read joints, cameras, recording state |
| `src/lelab_adapter_full.lex` | `[env, io, net, sense, actuate]` | the above, plus move the arm and record |

`lex run --allow-effects io,env,net,sense src/lelab_adapter.lex run_readonly`
serves leLab's UI against a robot it **cannot** move — not because a flag is
off, but because nothing reachable from that entry point declares `actuate`.
The same command against `..._full.lex` is refused before the port is bound.

**The lesson that generalises: the module boundary is the authority boundary.**
`--allow-effects` is checked over the whole reachable import graph, not just
the functions the entry point calls. A single file that imports `skills` is
refused under a sense-only policy *even if the entry point never actuates*. So
a read-only program may not merely avoid calling an actuating function — it
must not be able to reach one. That is why `sense.lex` was split from
`skills.lex`, and why the adapter is two modules rather than two functions.

## The audit

### Should be Lex — no dependency reason not to

Ranked by value, not size. Nothing here imports anything heavier than the
standard library.

| file | lines | why it belongs in Lex |
|---|---|---|
| ~~`sidecar/lelab_adapter.py`~~ | 552 | **ported** → `src/lelab_adapter{,_full}.lex` |
| `scripts/reconcile_audit.py` | 77 | Reconciles a **lex-trail** chain against a **lex-os** audit log — it reasons about Lex artifacts, in Python, re-deriving a hash formula whose canonical definition is `lex-trail/src/event.lex`. Smallest file with the biggest mismatch. |
| `sidecar/ha_sidecar.py` | 198 | Its own docstring says "the house's appliances as governed lex-robot skills". It is a grant story written in a language with no grants. Pure HTTP glue to Home Assistant. |
| `sidecar/vision_service.py` | 252 | `[net]` in, `[net]` out. The model horsepower is on the *other* machine; this half only forwards a JPEG and parses a box. `std.http` with a per-host scope is a better fit than `http.server`. |
| `sidecar/depot_sidecar.py` | 140 | A Tier-1 stub, stdlib only — the exact class `sidecar/sim_sidecar.py` already has a Lex twin for (`sim_sidecar.lex`, "same env vars, same HTTP API, no Python"). Precedent is set; this one just hasn't been done. |
| `examples/skills_api_stub.py` | 177 | Same: a Tier-1 stub backing `examples/skill_library.lex`. A stub for a Lex program, in Python. |
| `gym_env/xlerobot_usage_log.py` | 127 | Reads a lex-trail JSONL and summarises denials into a retraining signal. Pure logic over a Lex-produced artifact. |
| `gym_env/xlerobot_experiment_ledger.py` | 68 | Append-only experiment ledger. Pure + `fs_write`. |
| `gym_env/server.py` | 63 | Thin HTTP wrapper — but it fronts `BazaarEnv`, which is MuJoCo. Port only if the env boundary moves; low value. |

Suggested order: `reconcile_audit` (smallest, sharpest), then `ha_sidecar`
(most authority per line), then `vision_service`, then the stubs.

### Python by necessity — not a gap

| class | files |
|---|---|
| torch / learned policies | `gym_sidecar.py`, `g1_bc_reach.py`, `xlerobot_rl_{train,finetune,curriculum}.py`, `xlerobot_policy_eval.py`, `xlerobot_rl_eval.py` |
| serial buses, servos, cameras, mics | `xlerobot_sidecar.py`, `tower.py`, `probe_range.py`, `scripted_teleop.py`, `teach.py`, `capture_waypoints.py`, `depot_hw_sidecar.py`, `collision.py` |
| MuJoCo / physics | `xlerobot_sim.py`, `xlerobot_{,governed_,curriculum_}env.py`, `bazaar_env.py`, `depot_{g1,mujoco}_sidecar.py`, `examples/physics/mujoco_validate.py` |
| OpenCV / dataset writing | `episode_verifier.py`, `vision_reset_teleop.py`, `teach_to_dataset.py`, `record_scripted.py` |

`teach_to_dataset.py` deserves its own note: it is Python *on purpose* beyond
the cv2 dependency, because the dataset is written by **lerobot's own API**
rather than by hand. Every field, index and metadata file is lerobot's, so the
schema is whatever `lerobot-train` expects rather than whatever we guessed.

### In-process mirrors — Lex is canonical, Python is the copy

This is a real category, and it should stay small.

| file | why it cannot be Lex |
|---|---|
| `sidecar/trail.py` | Mirrors `lex-trail/src/event.lex`'s event-id formula so the *sidecar process* can emit a genuine chain. The Lex file is the spec; this is the copy that runs where the calls happen. |
| `sidecar/governance.py` | Observes skill dispatch **inside** the sidecar. Its whole purpose is catching callers that never went through Lex — a Lex ledger could only see Lex's own calls, which is precisely the blind spot the page exists to close. |
| `sidecar/sidecar_lib.py` | The shared HTTP skeleton for the Python sidecars. Lives exactly as long as they do. |

### Deliberate duplication — do not "simplify" this

`xlerobot_sidecar.py` re-implements the grant checks that `src/grant.lex`
already performs: `_grant_workspace_violation`, `_grant_max_grip_force`,
`_grant_floor_violation`, `_grant_max_base_speed`.

**This is not a missing Lex port.** It is defense in depth for callers that
never went through Lex — `curl`, the `/control` page, anything on the HTTP
port. Deleting it as redundant re-opens the hole #177 closed. Lex protects the
programs Lex compiled; Python is the only wall in front of everything else.

### Tests

Tests for Python code stay Python. Tests for **pure** logic that moves to Lex
become `examples {}` blocks on the functions themselves — the port of the
adapter turned 187 lines of `pytest` into examples folded into the SigId, which
run at `lex check` time and cannot drift from the code they document.

## Two things the port found

Neither was the point of the exercise; both were only visible because writing
the Lex version forced the question "which governed skill expresses this?".

1. **A whole family of actuating skills had no governed expression at all.**
   The sidecar has exposed `teach_*` since the `/teach` page landed, but no Lex
   skill named them — so no grant covered them. `teach_free` **drops servo
   torque on five joints**; the arm falls unless a hand is already on it. Nor
   did `teach_replay`, `teach_home_go`, `release_arm` or `reset`. Each is an
   actuating capability that was reachable from any caller with no capability
   envelope. All are now wrapped and grant-gated in `skills.lex` — and
   `teach_free` is deliberately *not* granted to the leLab adapter, whose UI
   has no button meaning "I am holding the arm". See "Two kinds of bound"
   below for what closing that gap turned out to require.

2. **`sense.read_joints` took no arm.** It sent `{}` and read whichever arm the
   sidecar defaulted to — right for a single-arm build, silently wrong for a
   dual-arm one. `read_joints_arm` now exists; the adapter reads both.

## Two kinds of bound

Wrapping those five in `skills.lex` gates *whether the program may ask*. For
`teach_replay` and `teach_home_go` that was not the whole hole, and finding out
why is worth writing down.

Replay was never unbounded in *how* it moves: `teach.replay_on_bus` already had
a discontinuity pre-flight, 6°-per-step smoothing, and a per-frame collision
veto that stops it. What nothing bounded was **where it ended up**. A
demonstration can be taught anywhere a hand can physically reach, and the
grant's workspace box is Cartesian while a recording is joint-space, so the box
simply did not apply to it. `_grant_trajectory_violation` closes that: it runs
every frame through forward kinematics and refuses the whole recording if any
end-effector position leaves the granted box. `teach_home_go` goes through the
same check as a one-frame trajectory.

Three properties of that workspace check are deliberate:

- **Checked whole, before any torque.** A replay stopped at frame 40 leaves the
  arm in a pose it was only ever meant to pass *through*. All of it or none of
  it — the same never-sent semantics `move_arm` has.
- **Refuse, don't downgrade.** If a box is declared but FK is unavailable (no
  URDF configured, or the recording predates a joint the model needs), the
  check cannot run and the replay is refused. Running it anyway would be
  claiming an envelope nothing verified.
- **No box declared means no refusal.** An arm the grant doesn't cover is
  unbounded and honestly so; inventing a box would be a bound nobody granted.

### The same recording, the other bound

`teach_replay` takes a `speed` multiplier, and the gap between frames is
`1 / (fps * speed)` — so `speed: 10` drives the taught path ten times faster.
Nothing bounded that. The workspace check constrains where the arm goes and
the collision model constrains what it hits, but a demonstration recorded at a
safe pace could be replayed at any pace at all.

`_grant_clamp_replay_speed` closes it against `arms.*.max_velocity_mps`, and
the choice of verb is the point: **clamped, not refused.** That is the same
split `move_base` and `grasp_arm` already use — a position cannot be squeezed
into an envelope without inventing a destination, but a speed can. Slowing the
replay preserves the taught path frame for frame; refusing would reject a
perfectly good recording over a number the caller picked. It is the *peak*
per-step speed that has to fit, not the average: a path is only inside the
envelope if its fastest moment is, and averaging would let a brief lunge
through on the strength of a slow tail.

The ceiling binds the **recording**, not just the multiplier. A demonstration
taught faster than `max_velocity_mps` is slowed even at `speed: 1.0` — the
bound is on how fast the arm may move, and who chose the number does not
change that:

```console
$ curl -s -X POST :8900/skill/teach_replay -d '{"name":"demo","speed":8.0}'
{"outcome":"reached",
 "detail":"replayed 5 frames over 1.2s (speed clamped to 0.25 m/s by arms.left.max_velocity_mps)",
 "clamps":[{"bound":"arms.left.max_velocity_mps","source":"grant",
            "requested":9.6,"ceiling":0.25}]}
```

That `clamps` field is how the ledger sees it. `governance.py` has no robot and
cannot compute a ceiling that depends on the recording's own kinematics, so the
sidecar reports the clamp in its reply and `classify()` reads it — the same
posture as everything else there: report the decision that was made, never
re-derive one.

Both checks run against the frames that will actually be **sent** — `replay`
interpolates with `smooth_steps` before driving, and a straight line in joint
space can bulge outside the box in Cartesian space. The handler smooths once
with `teach.MAX_STEP_DEG`, checks that, and hands `replay_on_bus` the same
constant so it re-derives an identical path. Checking one path and driving
another would prove nothing, so that determinism has its own test.

Two things this still does not cover, named rather than implied:

- **The approach path.** `replay_on_bus` first drives from wherever the arm
  currently is to the recording's first frame, at the same frame rate. That
  path depends on live joint positions the check has no access to, so neither
  the box nor the ceiling applies to it. It is bounded in joint space (no step
  over `MAX_STEP_DEG`) and vetoed by the collision model — but its Cartesian
  speed and destination are unchecked.
- **`move_arm` has no velocity to bound.** It is a closed-loop IK servo: it
  commands positions every 50 ms and the servos travel at whatever rate they
  travel. Enforcing a speed there would mean *building* a rate limiter, which
  is writing a motion controller, not enforcing a bound. So the governance
  row says `max_velocity_mps` is enforced for `teach_replay` **and explicitly
  not for `move_arm`**, rather than claiming the bound wholesale.

The generalisation: *a capability whose Lex wrapper exists is not thereby
bounded.* The wrapper answers "may this program ask?"; the sidecar still has to
answer "is what was asked inside the envelope?", and for anything whose
parameters aren't the bound's own coordinates, that second answer takes real
work. The governance page's honest column is what makes the difference visible
instead of assumed.

### Two wire-contract bugs the wrappers exposed

Writing a typed wrapper forces the question "what does this actually return?",
and twice the answer was wrong:

- **`reset` answered on no contract at all.** It returned the new state
  (`{"base": ..., "arms": ...}`) with no `outcome` key, so `parse_outcome` could
  only read a *successful* reset as `Stalled`. Both the Tier-1 stub and the
  MuJoCo sidecar now answer `outcome: "reached"` like every other actuating
  skill.
- **`parse_outcome` had no `Denied` branch.** A refusal from the sidecar's own
  grant checks — the second wall, the one that catches callers who never went
  through Lex — arrived in Lex as `Stalled`, i.e. as the arm having failed to
  get there rather than an envelope having said no. That mattered immediately:
  the new trajectory check answers `denied`, and it would have been reported as
  a hardware problem. Both now map to `Denied`, with `examples {}` pinning all
  four cases at `lex check` time.

The ledger had the mirror-image bug: `teach_replay` on a missing recording
answers `outcome: "refused"`, which `classify()` didn't know, so it fell through
to **`allowed`** — the governance page reporting an action that never happened.
`refused` is now `failed`: the arm didn't move, but no envelope spoke, so it is
neither `allowed` nor `denied`.

### One bound that is declared and deliberately not enforced here

`actuation.skills` — the capsule's skill allowlist — is loaded by the sidecar
and checked by nothing in it. That is on purpose, and `grant_enforcement()`
says so rather than implying otherwise.

The list is the **agent's** grant, and `grant.skill_allowed` refuses anything
outside it before a Lex program sends the call. But this port answers a second
principal: the operator's own `/control`, `/teach` and `/display` pages, which
legitimately invoke skills no agent capsule names. Enforcing the agent's
allowlist port-wide would break them, and widening it until they fit would make
it mean nothing. Two principals, one of which is enforced in Lex — stated, not
papered over.
