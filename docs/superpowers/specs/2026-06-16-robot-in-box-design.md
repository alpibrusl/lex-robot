# Robot-in-box: run the pick-place task as a supervised lex-os Firecracker guest

Date: 2026-06-16
Issue: [lex-robot#1](https://github.com/alpibrusl/lex-robot/issues/1)
Status: design approved, ready for implementation plan

## Problem

The static effect-wall is verified on macOS (`lex-os check`/`resolve` admit the
in-grant program, refuse the `proc`/exec one). The remaining piece — a
**hardware-enforced** execution of the robot task inside a real lex-os box —
needs Linux+KVM (Firecracker). The goal is to run the lex-robot pick-place task
as a supervised lex-os guest: unbypassable perimeter, budget/liveness kill,
reprovision, tamper-proof hash-chained audit, with
`manifests/pick_place.capsule.json` as the grant.

### Why this is real work, not a small bridge

Investigation of both repos established the gap precisely:

- **lex-os's supervisor `mediate()` is a decision-and-audit model, not an
  executor.** On `Decision::Allowed` it appends audit events and pushes the
  command *name* to `completed` (`lex-os-supervisor/src/lib.rs:311-315,
  437-440`). It never performs the effect. Commands are abstract entries in a
  `CommandRegistry` (name → dimension/level/reversibility/cost).
- **The guest agent proposes abstract command names**
  (`AgentActionMsg::Run { command: String }`) and is still **host-side**;
  `lex-os/src/agent.rs` flags in-guest placement as "a follow-up design change
  that requires redesigning the supervisor↔guest interface."
- **lex-robot's actual robot skills live in different layers**: Lex code
  (`src/skills.lex`, effect-typed, gated by lex-lang's `--allow-effects`)
  calling the Python gym sidecar over `net.dial_ws`.

So "wire a guest agent that issues robot skills as supervisor-mediated commands"
requires deciding *where the robot task executes inside the microVM* and *how a
mediation decision becomes a real sidecar call* — neither exists today.

## Scope

In scope (this milestone, runnable on the current KVM-but-GPU-less host):

- The full boxed wiring: guest proposes skills → supervisor mediates → guest
  executes the effect against the host sidecar through the egress wall →
  outcome recorded to the audit log.
- Grant-aware skill mediation (workspace/force/skill-allowlist).
- A deterministic scripted robot agent (in-grant + violation modes) for
  CI-able, GPU-free verification.

Deferred:

- **Policy solve quality (Issue #2).** `run_policy` is plumbed end-to-end, but
  the diffusion-policy normalization fix and a real PushT solve are demonstrated
  on a CUDA box, not here. The demo here proves mediation + execution + audit,
  not task success gated on a learned solve.
- **Full lex-trail integration.** `lex-trail` is not in this workspace (no
  sibling checkout). See §6.
- LLM / lex-loom-graph planners (the deterministic script is the milestone
  planner; smarter planners are a later enhancement).

## Approach (chosen: "guest executes after approval")

Two other options were weighed and rejected for this milestone:

- **Supervisor executes on host** — simplest, but the consequential network
  call originates on the host, *outside* the sealed VM, so the kernel egress
  wall no longer constrains the effect. That weakens the central
  "unbypassable perimeter" thesis the hardware run exists to prove.
- **lex-lang VM in-guest** — highest fidelity to lex-robot's "Lex skills =
  authority" design, but by far the heaviest: a musl lex-lang runtime in the
  rootfs plus a new Lex-effect → supervisor mediation hook. Too much for a
  first boxed run.

"Guest executes after approval" is the only option where the robot's outbound
effect is sealed behind the kernel egress wall — the reason for doing this on
hardware at all.

## Architecture

Two control planes, cleanly separated:

- **Control plane (vsock):** guest agent ↔ host supervisor. Not subject to the
  egress wall. Carries the mediation handshake.
- **Effect plane (egress-walled TCP):** guest → **host** gym sidecar at the
  tap-side host IP (`10.0.2.2:<port>`), exactly like the existing Ollama path.
  The kernel egress wall is the real boundary — the guest can reach *only* the
  allowlisted sidecar address.

The gym sidecar (Python + torch + gym-pusht) stays on the **host** (too heavy
for the microVM rootfs).

```
 Host                                              Guest (Firecracker microVM)
 ────                                              ───────────────────────────
 lex-os supervisor  ── vsock (control) ──────────  robot agent (scripted)
   grant-aware mediation                             proposes RunSkill{skill,args}
   budget + audit (hash chain)                       on Allowed, executes effect
        │                                                   │
        │                                          egress-walled TCP (10.0.2.2)
        ▼                                                   ▼
 gym_sidecar.py (host) ◄───────── HTTP/JSON skill endpoint ─┘
   gym-pusht env, run_policy
   emits episode log (hash-chained)
```

## Components & changes

### Per-step protocol (`lex-os-proto`)

Today: one line each direction per step (`AgentView` → `Run{command}`). Extend
to a 2-round-trip step **only for skill actions**; existing
`Run`/`Done`/`Destroy`/`ProposeChild` variants are unchanged so the LLM and
reprovision demos keep working (backward compatible).

```
Host→Guest:  AgentView { goal, step, last_outcome, ... }        # unchanged
Guest→Host:  RunSkill { skill, args }                           # NEW: move_to{pose}, grasp{force_n}, run_policy{name,goal,budget_ms}
Host→Guest:  Decision { allowed, reason }                       # NEW: mediated + charged + audited BEFORE effect
   (if allowed) Guest → sidecar over egress wall: execute, get Outcome + observation
Guest→Host:  SkillOutcome { outcome, observation }              # NEW: recorded to audit; becomes next step's last_outcome
```

Budget is charged on `Allowed`, *before* the effect (preserving the existing
"charge computed before the effect" invariant at `lib.rs:416-429`). A
subsequent sidecar failure surfaces as a `SkillOutcome` (Stalled/Timeout),
logged but already charged.

### Manifest schema (`lex-os-manifest`)

Add an **optional `actuation` block** (matching DESIGN.md §6): `skills`
allowlist, per-actuator `workspace_m` / `max_velocity_mps` / `max_force_n` /
`max_grip_force_n`, and per-skill `reversibility`. When present, the supervisor
builds a robot-aware validator; when absent, lex-os behaves exactly as today
(stays generic).

### Grant-aware mediation (`lex-os-supervisor`)

Mediation order for a `RunSkill`:

1. skill ∈ `actuation.skills`? else `Denied("skill not granted")`.
2. arg bounds: `move_to.target` ∈ `workspace_m` and velocity ≤
   `max_velocity_mps`; `grasp.force_n` ≤ `max_grip_force_n`. else `Denied`.
3. reversibility gate (`run_policy` = supervised; existing
   irreversible-consequential refusal still applies).
4. existing perimeter (net level) + budget gates.

Out-of-bounds → `Denied` at **run time inside the box loop** (not `lex check`
time). Per DESIGN.md §8 this is the supervisor-level *logical* block; the kernel
cannot reason about workspace geometry. The kernel wall's real contribution is
restricting *where* the guest can connect. The supervisor also records the
observed `SkillOutcome` to the audit chain.

### Guest robot agent (`lex-os-guest`)

A new agent mode driven by `LEX_OS_GUEST_SCRIPT` (mirrors the existing
`reprovision-demo` script and the `box/agent_ok.lex` vs `agent_violation.lex`
pair), in two variants:

- `robot-demo` — in-grant happy path: reset → read → in-bounds `move_to` →
  `grasp` → `run_policy`.
- `robot-violation` — issues an out-of-workspace `move_to` → demonstrates
  `Denied`.

On `Decision::Allowed`, the guest calls the host sidecar's HTTP/JSON endpoint
via `ureq` (already a guest dep — no WebSocket/musl client needed in the
rootfs) at `10.0.2.2:<port>`.

### CLI (`lex-os/src/main.rs`)

`--agent robot` wiring; pass sidecar host/port; egress derived from the
manifest.

### Sidecar (`lex-robot/sidecar/gym_sidecar.py`)

- Add a minimal **HTTP/JSON skill endpoint** (alongside the existing WebSocket
  interface) so the Rust guest uses `ureq`.
- Emit an **episode log** (command + observation, hash-chained) for
  reconciliation (§6).

### Grant (`lex-robot/manifests/pick_place.capsule.json`)

- Add the `actuation` block (skills, workspace bounds, velocity/force caps,
  per-skill reversibility) per DESIGN.md §6.
- Reconcile the `egress` allowlist (currently `127.0.0.1`/`localhost`) to the
  guest-visible sidecar address (`10.0.2.2:<port>`), kept to exactly that one
  host:port.

### box/ docs + scripts (`lex-robot/box/`)

- A run script (`box/run_in_vm.sh`) for the boxed run on the KVM host.
- Update `box/README.md` §4 (currently points at issue #1 as "remaining").
- A **reconcile script** asserting the lex-os audit log and the sidecar episode
  log corroborate (same command sequence + outcomes).

## Audit & the lex-trail caveat

The lex-os hash-chained `AuditLog` (already exists, already verified by
`audit_verified: true`) is the source of truth for mediation, now also recording
observed `SkillOutcome`s. **`lex-trail` has been cloned into the workspace**
(`alpibrusl/lex-trail`, a Lex library) — its event format is
`Event = { id, kind, parent, payload_json, ts_ms }` with
`id = sha256(join([kind, parent, payload_json, ts_ms], " "))`, chained via
`parent`. The standard kinds `cap.invoked` / `cap.completed` map directly onto
robot skills. The sidecar emits a genuine lex-trail chain (a small Python mirror
of `lex-trail/src/event.lex`, so no Lex runtime is needed in-line), and a
reconcile check asserts the lex-os audit chain and the lex-trail episode chain
corroborate on skill sequence + outcomes. (lex-trail is Lex, lex-os audit is
Rust — reconciliation is intentionally cross-language at the data level.)

## Verification (maps 1:1 to issue #1's checklist)

- **(a)** in-grant run (`robot-demo`) completes + `audit_verified: true`.
- **(b)** low `max_commands` budget → `BudgetExhausted` + supervisor kill +
  reprovision (`reprovisions >= 1`).
- **(c)** `robot-violation` → run-time `Denied` (not `lex check`); plus a
  non-allowlisted host attempt → kernel egress drop (the existing `wall2`
  pattern), showing both the logical and kernel walls.

## Host / ops prerequisites (runbook, not code)

- `/dev/kvm` present (confirmed on the current host) + `vmx`.
- Root / passwordless sudo (Firecracker jailer).
- `rustup target add x86_64-unknown-linux-musl` (in-VM guest build).
- `demo/setup-assets.sh` (firecracker + jailer + kernel + rootfs) in lex-os.
- Gym sidecar deps (`sidecar/requirements.txt`) installed on the host.

## Open implementation details (resolve during planning)

- Exact JSON shape of `RunSkill.args` per skill and the sidecar HTTP contract.
- Whether the `actuation` block lives in `lex-os-manifest` proper or a
  robot-specific extension the supervisor loads alongside the manifest
  (leaning: in `lex-os-manifest` as an optional field, to keep the grant
  single-source).
- Episode-log hash format chosen to be trivially reconcilable with the lex-os
  audit chain.
