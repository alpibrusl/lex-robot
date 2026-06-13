# lex-robot

Effect-typed, capability-bounded, auditable control layer for robots — sitting
**above** [LeRobot](https://github.com/huggingface/lerobot). LeRobot stays the
ML + hardware engine; `lex-robot` is the safety envelope and the
"judgment vs. authority" boundary (the [lex-os](https://github.com/alpibrusl/lex-os)
thesis, applied to a physical body).

> **Status: working prototype (verified on macOS / Apple MPS).** End-to-end:
> bounded skills → real gym-pusht physics → a learned LeRobot policy that solves
> the task (~0.9 peak coverage) → an evidence-gated task graph → a hash-chained
> lex-trail audit → a lex-os grant (static effect-wall + runtime supervised box).
> **Still not safe near a real arm** — software grant ≠ physical safety; you need
> firmware limits + a hardware e-stop (DESIGN.md §8). The Firecracker microVM box
> and (optional) GPU training are the only Linux-only pieces (see issues #1, #2).

## Layout

```
DESIGN.md        full design note (layering, reuse, milestones, constraints)
SIDECAR.md       the Python sidecar HTTP protocol
lex.toml         package manifest (depends on lex-trail)
src/
  types.lex      Pose, JointState, Frame, Outcome, Grant, Robot
  grant.lex      pure capability checks (workspace, force/velocity clamps)
  client.lex     HTTP bridge to the LeRobot sidecar (localhost)
  skills.lex     bounded skill API (move_to, grasp, run_policy, read_*, record_episode)
  task.lex       evidence-gated Perceive→Plan→Execute→Verify graph + lex-trail audit
examples/
  demo.lex       grant gate in action (Denied vs. allowed)
  task_demo.lex  the full gated task graph end to end
sidecar/         3 backends behind one protocol: sim_sidecar (stub) →
                 gym_sidecar (real PushT + LeRobot policy) → hardware
manifests/       lex-os grant for the task (pick_place.capsule.json)
box/             lex-os agent programs + the three-layer enforcement guide
```

## Try the grant gate (no robot needed)

```bash
LEX=/path/to/lex
$LEX check src/skills.lex
$LEX run --allow-effects net,io examples/demo.lex run
# move_to in-bounds   → stalled: ... Connection refused   (allowed → tried sidecar)
# move_to out-bounds  → denied: target outside granted workspace   (blocked, never sent)
# grasp(99N→clamped)  → ...   (allowed; force clamped to the grant ceiling)
```

![LeRobot diffusion policy solving gym-pusht (0.94 coverage), driven through lex-robot on Apple MPS](media/pusht_solve.gif)

*A `lerobot/diffusion_pusht` policy pushing the T to the goal in gym-pusht (~0.94
coverage), run via the lex-robot gym sidecar on Apple MPS — a real recorded rollout.*

## Testing in simulation

Three swappable sidecar backends behind one protocol (see `sidecar/README.md`):
**stub** (stdlib, logic tests) → **gym** (`gym-pusht`, real 2D physics, no
MuJoCo) → **hardware** (LeRobot). The Lex side is identical across all three.

```sh
pip install -r sidecar/requirements.txt   # gym backend
python3 sidecar/gym_sidecar.py &
lex run --allow-effects net,io examples/demo.lex run
```

## Why Lex, not vanilla LeRobot? (a demo where Lex does real work)

PushT-solving is 100% LeRobot — Lex adds nothing there. Lex's value is
**governance**: bounding what a policy is allowed to do. This demo proves it.

A **keep-out zone** (a "bystander" region — the top half of the workspace) is
declared. The *same* learned policy runs two ways against real physics:

```sh
.venv312/bin/python sidecar/gym_sidecar.py &
lex run --allow-effects net,io examples/safe_rollout.lex run
# UNGOVERNED (raw policy):  57/80 unsafe commands EXECUTED into the keep-out zone
# GOVERNED   (Lex grant):   60 unsafe commands BLOCKED, 0 executed
# → same policy; the Lex grant is the only difference
```

Lex sits **in the per-step loop**: it fetches each command the policy wants,
checks it against the grant's keep-out box, and blocks/clamps the unsafe ones.
Vanilla LeRobot has no such boundary — it executes whatever the policy emits.
That is the property Lex adds: a learned policy you don't fully trust, kept
inside an enforced envelope.

## EV-depot demo: physical action gated by a real protocol (lex-robot#4)

Where the safety rules aren't synthetic. A (stationary) humanoid arm connects a
charging connector to a truck, and the charging **session** is the Verify gate:

```sh
python3 sidecar/depot_sidecar.py &
lex run --allow-effects net,io examples/depot_demo.lex run
#   [ok ] perceive — inlet at (0.7,0.5,0.3)
#   [ok ] plan — approach the inlet
#   [ok ] execute.move — reached
#   [ok ] execute.connect (req 99N->clamped 15N) — reached     ← grant clamps the force
#   [ok ] verify — OCPP StartTransaction Accepted, tx=1001     ← real session, only if seated
#   task SUCCESS — truck charging
#   teardown — stopped tx + disconnect
```

Two real properties Lex enforces here:
- **Force ceiling** — the connect skill requests 99N; the grant clamps it to
  15N before it reaches the arm (plus a firmware floor in the sidecar).
- **Protocol-coupled Verify** — the OCPP `StartTransaction` only succeeds when the
  connector is *physically seated*, so a non-zero `transaction_id` is genuine
  evidence the connection completed. Teardown stops the session **before**
  unplugging (disconnect-mid-charge is `reversibility: supervised`).

The charging API (`/v1/chargers/:id/start|stop`) mirrors the real **lex-charge**
service (ev-fleet), so `charge_url` can point at the actual lex-charge/lex-csms
instead of the Tier-1 sidecar with no Lex changes. lex-os grant:
`manifests/depot.capsule.json`.

## Evidence-gated task graph (the lex-loom pattern)

`src/task.lex` runs **Perceive → Plan → Execute → Verify** with a hard gate at
Verify (a task is "done" only when a real outcome confirms it) and bounded
retries — the lex-loom pipeline, self-contained (no DB/orchestrator) so it runs
against any sidecar.

```sh
.venv312/bin/python sidecar/gym_sidecar.py &     # real PushT physics
lex run --allow-effects net,io examples/task_demo.lex run
# attempt 1:
#   [ok ] perceive — agent_pos [...]   (real sensor read)
#   [ok ] plan — target (...)
#   [ok ] execute — reached            (move_to in physics)
#   [ok ] verify — outcome reached     (the gate)
# task SUCCESS after 1 attempt(s)
```

Set `use_policy=true` in `task_demo.lex` to gate Verify on a real LeRobot policy
solving the task (`run_policy`, verified ~0.9 peak coverage on MPS — needs the
gym sidecar + `lerobot`).

## Running under lex-os (the capability box)

`manifests/pick_place.capsule.json` is a [lex-os](https://github.com/alpibrusl/lex-os)
grant: `fs=read-write net=allowlist exec=none`, budgets, egress=localhost. The
real `lex-os` binary enforces it as a static **effect-wall** before anything runs:

```sh
lex-os resolve --manifest manifests/pick_place.capsule.json
#   grant: "fs=read-write net=allowlist exec=none"

lex-os check --grant manifests/pick_place.capsule.json box/agent_ok.lex
#   effects: ["fs_write","io","net"]   ok: true        ← within grant

lex-os check --grant manifests/pick_place.capsule.json box/agent_violation.lex
#   grant violation: effect `proc` needs exec ≥ `sandboxed`, grant provides `none`   ← REFUSED
```

And the **runtime supervisor** runs on macOS too (simulated perimeter, no KVM):

```sh
lex-os run --manifest manifests/pick_place.capsule.json --agent demo --audit-out /tmp/robot-audit.json
#   audit_verified: true   outcome: "BudgetExhausted(...)"   reprovisions: 1
```

It mediates each command against the grant, tags reversibility, enforces the
budget (kill), reprovisions, and emits a verified hash-chained audit log. See
[`box/README.md`](box/README.md) for the full three-layer flow.

The only piece that needs **Linux+KVM** is running the robot task itself inside
an unbypassable Firecracker microVM as a lex-os guest agent (lex-robot#1).

## How it fits the ecosystem
- **lex-os** — runs `lex-robot` as a supervised box; the grant = physical safety
  envelope + budgets; supervisor can kill/reprovision.
- **lex-loom** — task orchestration as an evidence-gated graph:
  Perceive → Plan → Execute → Verify.
- **lex-trail** — hash-chained audit of commands + observations (also training
  provenance for LeRobotDataset episodes).
- **lex-llm** — high-level planner / skill selector.

## Known gaps (intentional / next)
- `actuate` / `sense` are **not** first-class Lex effects yet (compiler-defined
  set); skills carry `[net]` and capability is enforced at runtime via `grant.lex`
  + the lex-os grant. Promoting them to real effects is a lex-lang change (DESIGN.md §4).
- JSON is hand-built with `std.str`; could swap to `lex-schema/json_value`.
- No WebSocket streaming of sensor/state yet (HTTP request/response only).
- The robot task doesn't yet run *inside* a Firecracker microVM as a lex-os
  guest agent (needs Linux+KVM — issue #1). The static effect-wall + simulated
  runtime supervisor already work on macOS.
- `record_episode` writes frames to `.npz`; full LeRobotDataset export is a follow-up.
