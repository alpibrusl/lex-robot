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

1. **`teach_free` had no governed expression at all.** The sidecar has exposed
   `teach_*` since the `/teach` page landed, but no Lex skill named them — so
   no grant covered them. `teach_free` **drops servo torque on five joints**;
   the arm falls unless a hand is already on it. That is an actuating
   capability, and it was reachable from any caller with no envelope. Now
   wrapped and grant-gated in `skills.lex` — and deliberately *not* granted to
   the leLab adapter, whose UI has no button meaning "I am holding the arm".

2. **`sense.read_joints` took no arm.** It sent `{}` and read whichever arm the
   sidecar defaulted to — right for a single-arm build, silently wrong for a
   dual-arm one. `read_joints_arm` now exists; the adapter reads both.
