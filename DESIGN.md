# lex-robot — design note

> Effect-typed, capability-bounded, auditable control layer for robots,
> sitting *above* [LeRobot](https://github.com/huggingface/lerobot). LeRobot
> stays the ML + hardware engine; `lex-robot` is the safety envelope and the
> "judgment vs. authority" boundary — the lex-os thesis applied to a body.

Status: implemented working prototype (see README). This note records the design;
where it says "sketch", the code in `src/` is the ground truth.

---

## 1. Principle

Borrowed straight from lex-os:

> Agents bring judgment. Commands hold authority. The owner sets policy via the
> grant. The runtime's only job is to make the boundary unbypassable and the
> history legible.

For a robot:
- **Judgment** = the planner (lex-llm / a lex-loom task graph) decides *which*
  skill to invoke next.
- **Authority** = each skill is a Lex function with a narrow effect row; it
  cannot touch an actuator the grant didn't authorize.
- **Policy** = the grant (a lex-os manifest): allowed skills, kinematic/force
  caps, workspace bounds, budgets, reversibility tags.
- **Legibility** = a hash-chained lex-trail of every command + sensor reading.

What this buys over plain LeRobot-in-Python: a policy that *can't* command an
actuator outside its grant, and a verifiable record of everything it did.

---

## 2. Layering (and where the real-time boundary is)

```
 Task / planner        lex-loom sprint OR lex-llm agent
   1–10 Hz decisions   "tidy the desk" → bounded skills, gated by evidence
        │
 lex-robot (Lex)       effect-typed skills + safety grant + audit trail
        │  localhost JSON / WebSocket  (net.dial_ws)
 LeRobot sidecar (Py)  discrete skill API: reset, move_to, grasp,
        │              run_policy, record_episode, read_state
 LeRobot core (Py/C++) learned policies (ACT/Diffusion/TDMPC/VQ-BeT),
   30–1000 Hz loop     motor bus, cameras, SO-101/Koch/ALOHA drivers
```

**Hard rule:** the servo loop and neural-policy inference stay in Python/C++.
Lex's bytecode VM is not real-time; it operates at the *skill/decision* rate,
never inside the control loop.

---

## 3. Reuse vs. new

**Reuse (already exist):**
- **lex-os** — the execution envelope. Grant = physical safety policy + allowed
  skills + budgets (time, energy, action count); supervisor enforces, kills,
  reprovisions.
- **lex-trail** — hash-chained audit of commands + observations; doubles as
  provenance-tagged training data.
- **lex-loom** — task orchestration. A manipulation task maps onto loom's
  evidence-gated pipeline: **Perceive → Plan → Execute → Verify**, each gate a
  real sensor check before proceeding.
- **lex-llm** — the high-level planner / skill selector.
- **lex-schema** — typed messages across the sidecar boundary.

**New:**
- **`lex-robot`** — types, the effect-typed skill API, and the LeRobot bridge
  client (`net.dial_ws` to the sidecar).
- **`lex-vision`** (later) — perception types.
- a thin **Python sidecar** exposing LeRobot skills over a localhost socket.

---

## 4. Effects

Two new effect kinds, declared per skill so the type checker + the grant can
both reason about them:

| effect | operation examples | meaning |
|---|---|---|
| `actuate` | `move_to`, `grasp`, `run_policy`, `connect_charger` | drives a physical output |
| `sense`   | `read_camera`, `read_joints`, `policy_action`, `read_inlet` | reads a sensor (no physical effect) |

A pure planner that only *reasons* has neither. A "look but don't touch"
calibration routine is `[sense]` only. Anything that can move the robot is
`[actuate]` and is gated by the grant.

**Implemented.** Lex supports user-defined effect kinds, so `sense`/`actuate` are
first-class effects today — no lex-lang change was needed. They sit alongside
`[net]` (the actual sidecar transport) on each skill in `src/skills.lex`. Two
properties make them load-bearing:

- **Propagation** — a caller that invokes an `[actuate]` skill must declare
  `[actuate]` itself, or `lex check` fails (`effect-not-declared`). A `[sense]`-only
  routine therefore *cannot compile* if it calls `move_to`.
- **Runtime authority** — `lex run --allow-effects <set>` is the grant's
  execution-level gate. Withholding `actuate` makes every actuating skill
  unreachable before it runs (`effect not in --allow-effects`).

`scripts/smoke.sh` asserts both as negative checks (`== effect wall ==`), so the
boundary is enforced in CI, not just documented.

---

## 5. Skill API sketch (illustrative Lex)

```lex
# lex-robot/src/types.lex
type Pose       = { x :: Float, y :: Float, z :: Float, rx :: Float, ry :: Float, rz :: Float }
type JointState = { names :: List[Str], positions :: List[Float], velocities :: List[Float] }
type Frame      = { width :: Int, height :: Int, jpeg_b64 :: Str }   # from a camera
type Outcome    = Reached | Stalled(Str) | Denied(Str) | Timeout

# lex-robot/src/skills.lex — each skill is bounded + effect-typed.
# The grant is checked *inside* each call before any command leaves the box.

fn read_joints(r :: Robot) -> [sense] Result[JointState, Str]
fn read_camera(r :: Robot, name :: Str) -> [sense] Result[Frame, Str]

fn move_to(r :: Robot, target :: Pose) -> [sense, actuate] Outcome
  # rejects (Denied) if target is outside grant.workspace or would exceed
  # grant.max_velocity / max_force; otherwise streams to the sidecar.

fn grasp(r :: Robot, force :: Float) -> [sense, actuate] Outcome
  # force clamped to grant.max_grip_force; Denied if gripper not granted.

fn run_policy(r :: Robot, name :: Str, goal :: Str, budget_ms :: Int)
  -> [sense, actuate] Outcome
  # hands the high-rate loop to LeRobot; supervisor enforces budget + e-stop.

fn record_episode(r :: Robot, task :: Str) -> [sense, fs_write] Result[Episode, Str]
  # captures a LeRobotDataset-format episode via the sidecar.
```

Every `Outcome` and sensor read is written to lex-trail with a hash, so the
episode is replayable and the decision history is auditable.

---

## 6. The grant (lex-os manifest)

```jsonc
{
  "goal": "Pick the red block and place it in the bin",
  "skills": ["read_joints", "read_camera", "move_to", "grasp", "run_policy"],
  "actuate": {
    "arm":     { "workspace_m": [[0.1,0.5],[-0.3,0.3],[0.0,0.4]],
                 "max_velocity_mps": 0.25, "max_force_n": 15 },
    "gripper": { "max_grip_force_n": 20 }
  },
  "budgets": { "wall_ms": 120000, "actions": 200 },
  "reversibility": { "move_to": "reversible", "grasp": "reversible",
                     "run_policy": "supervised" }
}
```

The supervisor (lex-os, outside the box) holds this. A skill call that violates
it returns `Denied(...)` and is logged; the supervisor can also hard-kill on
budget/liveness breach.

---

## 7. LeRobot integration points
- **Policies** — `run_policy(name, goal, budget)` → Python runs the loop, returns
  `Outcome` + trajectory. lex-robot never sees individual servo ticks.
- **Datasets** — `record_episode` emits **LeRobotDataset** format; the lex-trail
  hash chain gives each episode tamper-evident provenance for training.
- **Hardware** — drive SO-101 / Koch / ALOHA *through* LeRobot; no driver
  reimplementation.

---

## 8. Honest constraints (read before trusting this near a real arm)
1. **Not real-time.** Decisions only; servoing stays in Python/C++.
2. **Software perimeters are not physical safety.** A grant can make commands
   *mediated, bounded, and legible*, but software cannot physically stop a
   motor. The real safety floor is **firmware joint limits + a hardware e-stop**.
   lex-os/lex-robot give command-level mediation and an unbypassable *logical*
   boundary, not a physical guarantee.
3. **Bridge cost.** A localhost sidecar is the pragmatic v1; a native lex-lang
   robotics binding is a later optimization if skill-boundary latency matters.

---

## 9. Minimal first milestone (proof of concept)
1. Python sidecar wrapping a LeRobot SO-101 (or the sim env) with 4 skills:
   `read_joints`, `read_camera`, `move_to`, `grasp`, over a localhost WebSocket.
2. `lex-robot` types + skill client (`net.dial_ws`) with `actuate`/`sense`
   effects and in-skill grant checks.
3. A lex-loom task graph: Perceive → Plan → Execute → Verify for a single
   pick-and-place, with each gate checking a camera/joint observation.
4. lex-trail recording the full episode; export one LeRobotDataset episode.
5. Run it as a lex-os box with the §6 grant; demonstrate a `Denied` on an
   out-of-workspace target and a supervisor budget kill.
```
