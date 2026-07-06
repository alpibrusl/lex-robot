# lex-robot

[![CI](https://github.com/alpibrusl/lex-robot/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/lex-robot/actions/workflows/ci.yml)

**Part of the [Lex](https://lexlang.org) project** — Robotics · [Manifesto](https://lexlang.org/manifesto) · [All packages](https://lexlang.org)

Effect-typed, capability-bounded, auditable control layer for robots — sitting
**above** [LeRobot](https://github.com/huggingface/lerobot). LeRobot stays the
ML + hardware engine; `lex-robot` is the safety envelope and the
"judgment vs. authority" boundary (the [lex-os](https://github.com/alpibrusl/lex-os)
thesis, applied to a physical body).

> **Status: working prototype (verified on macOS / Apple MPS).** End-to-end:
> bounded skills → real gym-pusht physics → a learned LeRobot policy that solves
> the task (best-case ~0.9 coverage, high variance) → an evidence-gated task graph → a hash-chained
> lex-trail audit → a lex-os grant (static effect-wall + runtime supervised box).
> **Still not safe near a real arm** — software grant ≠ physical safety; you need
> firmware limits + a hardware e-stop (DESIGN.md §8). The Firecracker microVM box
> and (optional) GPU training are the only Linux-only pieces (see issues #1, #2).

## Quickstart (5 minutes, no ML dependencies)

The four **governance** demos need only the `lex` toolchain + `python3` — no pip
installs. They are the point of the project (the brain is LeRobot's job).

**1. Install the `lex` toolchain** — prebuilt binaries for Linux/macOS/Windows on
[lex-lang releases](https://github.com/alpibrusl/lex-lang/releases). Pick your
platform's tarball (`aarch64-apple-darwin`, `x86_64-apple-darwin`,
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`), e.g. macOS Apple Silicon:

```sh
V=v0.10.0; T=aarch64-apple-darwin
curl -fsSL "https://github.com/alpibrusl/lex-lang/releases/download/$V/lex-$V-$T.tar.gz" | tar -xz
sudo mv "lex-$V-$T/lex" /usr/local/bin/ && lex version
```

Or skip the install entirely and run everything in Docker (no `lex`/python needed):

```sh
docker build -t lex-robot . && docker run --rm lex-robot        # type-check + all 4 demos
```

**2. Run a demo** — each target starts a stdlib-only stub sidecar, runs the
program, and stops the sidecar:

```sh
make demo      # ← start here: untrusted LLM planner, Lex on the rails
make grant     # grant gate: in-bounds allowed, out-of-bounds denied, force clamped
make task      # evidence-gated Perceive → Plan → Execute → Verify
make budget    # budget supervisor: a zero-action grant kills the run before any command
make depot     # OCPP-gated depot connect
make smoke     # type-check everything + run all five, asserting the output (CI-ready)
```

(No `make`? Use `bash scripts/demo.sh llm`.) The only Lex dependency, `lex-trail`,
is public and fetched automatically on first run.

### Dependency matrix

| demo | command | needs |
|---|---|---|
| LLM planner / grant / task / budget / depot | `make demo` / `grant` / `task` / `budget` / `depot` | **`lex` + `python3` only** (stdlib sidecars) |
| XLeRobot dual-arm + base governance | `make xlerobot` | **`lex` + `python3` only** (stub sidecar) |
| XLeRobot in MuJoCo physics (+ gym env) | `make xlerobot-sim` | + `pip install mujoco numpy` (`gymnasium` for the env) |
| keep-out (learned policy vs. grant) | `make keepout` | + `pip install -r sidecar/requirements.txt` (gym-pusht, lerobot) |
| MuJoCo depot (Tier-2 / Tier-3 G1) | `python3 sidecar/depot_mujoco_sidecar.py` · `depot_g1_sidecar.py` | + `mujoco` (+ G1 model via `LEX_G1_DIR`) |
| learned reach policy (behaviour cloning) | `python3 sidecar/g1_bc_reach.py` | + `torch` (+ G1 model) |

Everything is public: the toolchain ([lex-lang](https://github.com/alpibrusl/lex-lang)),
the one Lex package dep ([lex-trail](https://github.com/alpibrusl/lex-trail)), and
all Python deps (PyPI). No private packages are required to build or run.

## Layout

```
DESIGN.md        full design note (layering, reuse, milestones, constraints)
SIDECAR.md       the Python sidecar HTTP protocol
lex.toml         package manifest (depends on lex-trail)
src/
  types.lex      Pose, JointState, Frame, Outcome, Grant, Robot
  grant.lex      pure capability checks (workspace, force/velocity clamps)
  budget.lex     pure budget supervisor (action + wall-clock caps; Killed on breach)
  client.lex     HTTP bridge to the LeRobot sidecar (localhost)
  skills.lex     bounded skill API (move_to, grasp, read_*, record_episode)
  policy.lex     run_policy + async polling (kept off the core surface; needs [time])
  task.lex       evidence-gated Perceive→Plan→Execute→Verify graph + lex-trail audit
  charge.lex     OCPP client for the depot Verify gate (real lex-charge / CSMS)
  a2a_*.lex      A2A protocol: bootstrap blob, Ed25519 cards, handshake, consent, sessions, server
  human_goal.lex human-in-the-loop goal (ask a person at run time, don't hardcode it)
  bazaar*.lex    bazaar shopper + LLM seller logic
  (the games framework now lives in the lex-games package — a git dependency)
examples/
  demo / task / budget / depot / safe_rollout / llm_planner   the robot governance demos
  policy_eval                                                 live policy-eval leaderboard (real rollouts → lex-games robot_task referee → ranked; forged over-grant run is disqualified)
  peer_meet / ev_fleet / logistics /
  trading / station / triage / heist                          agentic interaction demos (+ *_web.html, *_run.sh)
  arena_demo                                                  robot control-authority arbitration (unrelated in name to lex-arena)
  (games, the Magentic Bazaar, tinder, auto_bazaar, haggle*, seller_pricing_demo
   now live in the lex-arena repo — a git dependency)
sidecar/
  sim_sidecar.lex   pure-Lex dashboard + A2A peer + skill host (agentic demos & games)
  sim_sidecar.py    stdlib stub for the robot governance demos
  gym_sidecar.py    real gym-pusht physics + a LeRobot policy
  depot_*.py        depot backends: stub → MuJoCo → Unitree G1 → hardware seam
  xlerobot_*.py     XLeRobot 0.4.0 (dual SO-101 + diff-wheel base): stub → MuJoCo room → hardware seam
manifests/       lex-os grant for the task (pick_place.capsule.json)
box/             lex-os agent programs + the three-layer enforcement guide
```

## Try the grant gate (no robot needed)

```bash
LEX=/path/to/lex
$LEX check src/skills.lex
$LEX run --allow-effects net,sense,actuate,io examples/demo.lex run
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
lex run --allow-effects net,sense,actuate,io examples/demo.lex run
```

## Why Lex, not vanilla LeRobot? (a demo where Lex does real work)

PushT-solving is 100% LeRobot — Lex adds nothing there. Lex's value is
**governance**: bounding what a policy is allowed to do. This demo proves it.

A **keep-out zone** (a "bystander" region — the top half of the workspace) is
declared. The *same* learned policy runs two ways against real physics:

```sh
.venv312/bin/python sidecar/gym_sidecar.py &
lex run --allow-effects net,sense,actuate,io examples/safe_rollout.lex run
# UNGOVERNED (raw policy):  57/80 unsafe commands EXECUTED into the keep-out zone
# GOVERNED   (Lex grant):   60 unsafe commands BLOCKED, 0 executed
# → same policy; the Lex grant is the only difference
```

Lex sits **in the per-step loop**: it fetches each command the policy wants,
checks it against the grant's keep-out box, and blocks/clamps the unsafe ones.
Vanilla LeRobot has no such boundary — it executes whatever the policy emits.
That is the property Lex adds: a learned policy you don't fully trust, kept
inside an enforced envelope.

## Untrusted LLM planner, Lex on the rails (lex-robot#5)

The same boundary, one level up: when an **LLM** does the planning, the grant is
what stands between its *judgment* and the robot's *authority*. The LLM is asked
to "tidy the cup into the bin" and — as LLMs do — emits a mix of sensible steps, a
hallucinated shortcut, an over-grip, an out-of-bounds reach, and a prompt-injected
"sweep everything off the table". Lex checks every proposed action against the
grant **before** it can reach the actuators:

```sh
python3 sidecar/sim_sidecar.py &
lex run --allow-effects fs_write,io,net,sense,actuate,sql,time examples/llm_planner_demo.lex run
#   [ALLOW] move_to (0.5,0.1,0.2) — task: approach the cup
#   [CLAMP] grasp 250N -> 20N — llm: grip it hard so it won't slip
#   [BLOCK] move_to (0.45,0.5,0.2) — hallucination — enters keep-out (bystander) zone; NOT SENT
#   [BLOCK] move_to (0.5,1.5,0.2) — llm: reach behind the wall — outside workspace; NOT SENT
#   [BLOCK] sweep_all — INJECTED — skill not in grant; NOT SENT
#   executed: 5   clamped: 1   BLOCKED (never sent): 3
#   task SUCCESS — cup placed in the bin (Verify gate passed)
#   audit: 9 events, 9 valid → chain intact (tamper-evident)
```

Three unsafe actions are blocked and never reach the wire, the over-grip is clamped
to the grant ceiling, the task is "done" only when the **goal action actually
completes** (Verify), and every proposed-vs-executed decision is a hash-chained
lex-trail event that `event.is_valid` re-checks (tamper-evident). The canned plan
stands in for the LLM so it runs offline; swap `propose_plan()` for a real lex-llm
call returning structured tool calls and the governance is unchanged. This is the
answer to "LLM-driven robots are unsafe": the LLM proposes, the grant disposes.

## EV-depot demo: physical action gated by a real protocol (lex-robot#4)

Where the safety rules aren't synthetic. A (stationary) humanoid arm connects a
charging connector to a truck, and the charging **session** is the Verify gate:

```sh
python3 sidecar/depot_sidecar.py &
lex run --allow-effects env,net,sense,actuate,io examples/depot_demo.lex run
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

### Against the real ev-fleet lex-charge/lex-csms

The same demo runs against the **real** charging stack — no Lex changes, just
env vars. `src/charge.lex` uses the header-capable `http.send` + `http.with_auth`
(Bearer JWT), so it talks to the authenticated lex-charge directly:

```sh
python3 sidecar/depot_sidecar.py &                          # physical depot (:8900)
# (ev-fleet stack up; lex-charge published to host on :18000; JWT minted for JWT_SECRET)
LEX_CHARGE_URL=http://127.0.0.1:18000 LEX_CHARGE_TOKEN=<jwt> LEX_DEPOT_CP=CP-RTM-01 \
  lex run --allow-effects env,net,sense,actuate,io examples/depot_demo.lex run
#   [ok ] verify.start   — lex-charge accepted (sent)            ← real remote_start → CSMS
#   [ok ] verify.confirm — active OCPP session for CP-RTM-01     ← real /v1/sessions/active
#   task SUCCESS — truck charging
```

Notes: `127.0.0.1` (not `localhost`) avoids an IPv6 hang through the docker
proxy; a `Connection: close` header avoids a keep-alive hang against the lex-web
server. The Tier-1 `depot_sidecar` stand-in mirrors the same routes for offline
runs. lex-os grant: `manifests/depot.capsule.json`.

### Tier 2: real MuJoCo physics scene

`sidecar/depot_mujoco_sidecar.py` is a real MuJoCo scene (truck + charge-inlet
site + a mocap-teleoperated connector) behind the same protocol — the same
`depot_demo.lex` runs against it unchanged (`perceive` reads `site_xpos`, `move`
runs `mj_step`, `connect` checks site alignment).

```sh
pip install mujoco
python3 sidecar/depot_mujoco_sidecar.py &
lex run --allow-effects env,net,sense,actuate,io examples/depot_demo.lex run
```

![MuJoCo depot: connector approaching the truck inlet](media/depot_mujoco.gif)

### Tier 3: real Unitree G1 humanoid + contact-rich insertion + rigid weld

`sidecar/depot_g1_sidecar.py` loads the real **Unitree G1** humanoid (MuJoCo
Menagerie) and drives its right arm to do the connect — same depot protocol, so
`depot_demo.lex` runs against it unchanged. The fidelity jumps from Tier 2:

- **Real humanoid arm**, not a floating capsule. The connector is mounted on the
  G1 hand; the arm is moved by a mocap weld (Cartesian teleop, no IK), pelvis
  pinned to the world (a stationary depot humanoid), gravity off so there's no
  whole-body balancing.
- **Contact-rich insertion** — the connector geom and the inlet pad are
  collidable, so the plug physically contacts the truck during approach.
- **Rigid weld on seat** — once the tip is aligned within tolerance, a stiff
  weld equality (plug→truck) locks in place: a real mechanical join, not just an
  alignment flag. `disconnect_charger` releases it.

The G1 lives in its natural frame (right hand at −y), so the sidecar maps the
grant's `[0,1]` workspace onto the real reachable box — the grant and demo stay
unchanged. The model isn't vendored (heavy STL meshes); point `LEX_G1_DIR` at a
Menagerie checkout:

```sh
pip install mujoco numpy
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/google-deepmind/mujoco_menagerie.git /tmp/menagerie
git -C /tmp/menagerie sparse-checkout set unitree_g1
export LEX_G1_DIR=/tmp/menagerie/unitree_g1
python3 sidecar/depot_g1_sidecar.py &
lex run --allow-effects env,net,sense,actuate,io examples/depot_demo.lex run
#   [ok ] execute.move — reached            ← the G1 right arm reaches the inlet
#   [ok ] execute.connect (req 99N->clamped 15N) — reached   ← grant clamps + weld seats
#   [ok ] verify.confirm — active OCPP session
#   task SUCCESS — truck charging
```

![Unitree G1 reaching across to seat the charge connector in the truck inlet](media/depot_g1.gif)

Connection uses real contact + a rigid weld. By default the pelvis is pinned and
gravity is off (a rock-solid stationary depot arm). `LEX_G1_BALANCE=1` switches to
**whole-body balance**: gravity on, no pin — the G1 stands on its own two legs (a
PD hold of the home pose) while only the right arm reaches; it parks the truck a
little closer so the reach stays inside the balance envelope (CoM over the feet).

```sh
LEX_G1_BALANCE=1 python3 sidecar/depot_g1_sidecar.py &
lex run --allow-effects env,net,sense,actuate,io examples/depot_demo.lex run   # same demo, unchanged
```

![Unitree G1 balancing on its own legs while plugging in the charge connector](media/depot_g1_balance.gif)

### Is the grant *physically* meaningful? (measured in physics)

The tiers above show the grant clamping force and bounding the workspace. But a
clamp only matters if less force actually reaches the world, and a keep-out bound
only matters if the end-effector actually stays out. `examples/physics/` measures
exactly that: it runs the *same* policy intent twice in MuJoCo rigid-body physics —
once raw, once through the Lex grant gate — and compares.

| property                 | ungoverned | governed |
|--------------------------|-----------:|---------:|
| keep-out penetration (m) |       0.50 |     0.00 |
| contact force (N)        |        250 |       20 |

Lex governs, MuJoCo simulates: the harness hands the raw command to
`examples/govern_commands.lex` (same semantics as `src/grant.lex`), which returns
the governed command *and* a `robot_task` trail that replays to a clean verdict —
so the loop is policy intent → grant gate → physics → trail → verify.

```sh
examples/grant_physics_run.sh    # creates a venv (mujoco+numpy), runs, verifies
```

Out-of-band (needs `mujoco`+`numpy`, not a CI dep). See `examples/physics/README.md`.

The same governed loop runs on the **real Unitree G1** kinematics, too
(`examples/physics/g1_validate.py`, reusing `sidecar/depot_g1_sidecar.py`): the
arm seats the connector at a clamped 20 N and welds it, while the ungoverned 99 N
stalls on the firmware floor — and the governed episode's `robot_task` trail
verifies. Governance survives contact with a real robot model.

```sh
examples/g1_physics_run.sh       # venv + sparse-checks-out the G1 model, runs, verifies
```

### Going to real hardware (the transfer seam)

The sim drives the arm with a mocap-weld teleop shortcut — fine for a demo, not a
real controller. The part that **does** transfer is the Lex governance layer
(grant force/workspace clamps, the Perceive→Plan→Execute→Verify graph, real OCPP).
`sidecar/depot_hw_sidecar.py` is the seam: the same depot protocol with `# REAL:`
markers for a LeRobot-driven arm and an independent firmware force floor (defense
in depth behind the grant clamp). It runs as a stub by default so the whole
governance path exercises offline; `LEX_ROBOT_HW=1` switches to a real arm — and
the Lex side doesn't change a line.

```sh
python3 sidecar/depot_hw_sidecar.py &                            # stub (no hardware)
lex run --allow-effects env,net,sense,actuate,io examples/depot_demo.lex run   # same demo, unchanged
```

### A *learned* controller (not the scripted servo)

The reach in the gifs is a hand-written servo — scripted by us, not decided by the
robot. `sidecar/g1_bc_reach.py` replaces it with a learned policy: it uses the
servo as an **expert** to reach random goals, trains a small MLP by **behaviour
cloning** (proprioception + goal → joint targets), then drives the arm with the
*learned* network in closed loop — no servo, no weld. Generalisation to goals it
never saw (including the real charge inlet) is the test.

```sh
pip install torch
python3 sidecar/g1_bc_reach.py
#   trained on ~4k samples, BC loss 0.019
#   learned-policy rollout (closed loop, no servo):
#     held-out goals: 11/20 within 0.06 m
#     REAL charge inlet: 0.050 m  (reached)
```

![Learned BC policy driving the G1 arm to the charge port (no scripted servo)](media/depot_g1_policy.gif)

It's a deliberately tiny experiment: the network genuinely decides the joint
motion (autonomous *control*), but it's proprioception+goal only (no vision), a
fraction of held-out goals still miss, and the un-actuated free base throws
transient "unstable" warnings (it's hard-pinned each step; the run stays finite).
A real autonomous version would swap this MLP for a vision-based LeRobot policy
trained on teleop episodes — which is exactly what `depot_hw_sidecar.py` plugs in.

## XLeRobot: govern your own dual-arm mobile robot

The [XLeRobot 0.4.0](https://github.com/Vector-Wangel/XLeRobot) (WowRobo kit:
two 5-DOF SO-101 arms — optionally with 0.4.0's soft finray TPU fingers — on
a dual-wheel differential base, head RGB cam, LeRobot-native) is the first
*owned-hardware* target. A mobile dual-arm robot has **two capability
envelopes**, so the demo carries **two grants** against one sidecar — the
arms' ~40 cm reach box + grip cap, and the base's permitted floor area +
speed cap. Same primitives, per actuator group; no new grant machinery.

```sh
make xlerobot          # stub sidecar — lex + python3 only, CI-gated
#   base → staging (1.0,0.85)      → reached          ← the diff base approaches nose-first
#   base → counter (2.55,0.85)     → reached
#   left arm → cup (0.35,0,0.45)   → reached
#   left grasp 99N (clamped→15N)   → reached          ← grant ceiling, then a 25N firmware floor
#   base → kitchen (4.5,1.5)       → denied: base target outside granted floor area
#   right arm → behind (0.90,0.0)  → denied: right arm target outside granted workspace
#   move_base under ARM grant      → denied: skill move_base not in grant   ← cross-envelope refusal
#   base → table, 2 m/s (clamped)  → reached          ← speed clamped to the 0.5 m/s grant
```

Three tiers behind one protocol, like the depot:

- **Tier 1 — stub** (`sidecar/xlerobot_sidecar.py`, stdlib only): kinematic
  base + arm state, independent firmware floors (grip `LEX_XLE_HARD_GRIP_N`,
  speed `LEX_XLE_HARD_SPEED_MPS`). The `== xlerobot ==` smoke checks run
  against this in CI.
- **Tier 2 — MuJoCo** (`sidecar/xlerobot_mujoco_sidecar.py`, `pip install
  mujoco numpy`): a real physics room (velocity-actuated cart — 0.4.0's
  differential drive by default, `LEX_XLE_BASE=omni` for the older holonomic
  base — counter, a 200 g cup) — `make xlerobot-sim` runs the *same demo unchanged*;
  every `reached` is physical. The grasp is a weld that only takes if the EE
  is actually at the cup, and the carry drags real mass across the room.
- **Tier 3 — hardware** (`LEX_ROBOT_HW=1`, fill the `# REAL:` seams): the
  stub's handler bodies are shaped for LeRobot's SO-101 buses + base drive;
  the Lex side doesn't change a line. Before trusting it near the real kit:
  firmware joint/torque limits + the e-stop are the safety floor, not the
  grant (DESIGN.md §8).

**The gym** (`gym_env/xlerobot_env.py`, Gymnasium `LexXLeRobotFetch-v0`)
wraps the *same* MuJoCo scene as Tier 2: obs = base/EE/cup state, action =
base velocity + left-EE displacement, reward = approach + a lift bonus. Train
or script a policy here, then roll it out through the grant gate step-wise
(the `safe_rollout` pattern) and submit the episode trail to the lex-games
`robot_task` referee — a scripted expert solves it in ~340 steps, so the
task is verified learnable. lex-os grant: `manifests/xlerobot.capsule.json` —
the supervisor mediates the XLeRobot skills too (lex-robot#77 / lex-os#49):
`move_arm`/`grasp_arm` against the arm/gripper caps, `move_base` against the
capsule's `base` block (floor area + speed), and a granted skill with no
mediation rule is refused, never admitted by fallthrough. See
[`box/README.md`](box/README.md) §5 for the XLeRobot-in-the-box run.

**Camera + microphone — sensors as granted capabilities** (`make
xlerobot-voice`): the 0.4.0's head camera and mic are governed like actuation.
`read_camera` and the new `listen` skill live in `src/sense.lex` — a
`[net, sense]`-only module, so a sensing program never inherits `[actuate]`
surface — and the mic is explicitly grant-gated ("can this program hear the
room?" is a typed, refusable question). The demo closes the human_goal loop by
voice: the spoken transcript becomes the run's goal (the sidecar transcribes
locally — raw audio never crosses into Lex or the trail), the head camera
returns a frame under the same grant, and a mic-less grant is refused at the
capability layer before any request is sent. The MuJoCo tier renders the head
camera offscreen (real pixels on hosts with a GL backend; an explicit error,
never fake imagery, on headless boxes). On hardware, the `# REAL:` seams are
a LeRobot camera grab and mic capture + local Whisper.

```sh
make xlerobot-voice
#   voice goal: fetch the cup to the table        ← the human goal, spoken
#   head camera frame: {"width": 640, ...}
#   muted robot → denied: skill listen not in grant   ← NEVER SENT
```

**The first game — Fetch the Cup, verified** (`make xlerobot-task`): the
mission runs as a competition entry. Every actuation is recorded to a
hash-chained trail as a structured SkillOutcome — a base drive is a
`move_base` under the BASE grant (the floor area), an arm reach a `move_to`
under the ARM grant (the reach box), the grasp checked against `max_grip` —
and the trail is the submission (the shared encoders live in `src/wire.lex`). The lex-games `robot_task` referee replays it live, next to a
forged entry that shows why that matters:

```sh
make xlerobot-task
#   #1  governed_fetch   verified=yes legal=yes goal=yes score=140
#   #2  forged_sprint    verified=no  legal=no  goal=yes score=148   <- DISQUALIFIED
#   submission written: /tmp/xlerobot_fetch.jsonl
```

The forged run's raw score (148) *beats* the honest one — and the referee
disqualifies it anyway, because its out-of-floor-area drive claims `reached`
and legality is **re-derived from the recorded grant, never trusted**
(`legal_checked:5` on the honest entry — base drives as `move_base`, arm
reaches as `move_to`, the grasp against `max_grip`, per the referee's strict
vocabulary). The JSONL file verifies anywhere:
`lex-games/cli/games verify robot_task /tmp/xlerobot_fetch.jsonl`. The same
program against the MuJoCo sidecar produces a physically-earned trail with
the identical verdict, and the smoke checks gate all of this in CI.

**The safe-RL/eval loop, closed** (`examples/xlerobot_policy_run.sh`): the
mission above is a fixed, hand-written script. This closes the loop the gym
env (`gym_env/xlerobot_env.py`, `LexXLeRobotFetch-v0`) was built for — **train,
roll out through the grant gate, verify, earn reputation**:

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
geometric controller today, but state-in/action-out exactly like a trained one
would be — against the same physics core the gym wraps: it *observes* the
cup's position and the base's actual post-drive pose (a differential-drive
base doesn't land on a fixed heading), then *computes* the arm-reach target
from that observation, rather than replaying memorized waypoints. Its rollout
— the skill calls it chose, in the same units/frame the governed skills expect
— is then **replayed through the actual grant gate**
(`examples/xlerobot_policy_rollout.lex`, reusing `skills.move_base` /
`move_arm` / `grasp_arm`): the policy doesn't get a bypass — an out-of-grant
arm target in the rollout is denied at the capability layer exactly as it
would be for the fixed mission. The resulting trail is verified by the same
`robot_task` referee, and a verified run is **signed and folded into the
durable `did:lex` reputation registry** (`examples/agent_registry.lex`,
the identity + control-plane kernel — see below). Any future policy, hand-coded
or trained, earns reputation the same way: by producing a rollout that
survives the grant gate and replays clean.

## Evidence-gated task graph (the lex-loom pattern)

`src/task.lex` runs **Perceive → Plan → Execute → Verify** with a hard gate at
Verify (a task is "done" only when a real outcome confirms it) and bounded
retries — the lex-loom pipeline, self-contained (no DB/orchestrator) so it runs
against any sidecar.

```sh
.venv312/bin/python sidecar/gym_sidecar.py &     # real PushT physics
lex run --allow-effects net,sense,actuate,io,sql,fs_write,time examples/task_demo.lex run
# attempt 1:
#   [ok ] perceive — agent_pos [...]   (real sensor read)
#   [ok ] plan — target (...)
#   [ok ] execute — reached            (move_to in physics)
#   [ok ] verify — outcome reached     (the gate)
# task SUCCESS after 1 attempt(s)
```

Set `use_policy=true` in `task_demo.lex` to gate Verify on a real LeRobot policy.
Two honest caveats (measured on MPS, lerobot 0.5.1 + `lerobot/diffusion_pusht`):

- **Policy is near-spec but not reliable.** Over 10 episodes, peak coverage ranged
  0.0–0.88 (best 0.88, mean ~0.48); it rarely clears the 0.90 solve threshold. So
  Verify will often legitimately report FAILED. Normalization is mostly working
  (a broken-norm policy scores ~0 every episode — we see 0.7+), but the
  `normalize_inputs.buffer_*` warning suggests the last ~0.1 is recoverable.
- **`run_policy` runs asynchronously** to dodge a real toolchain limit: `std.http`
  enforces a hard ~10s client timeout (lex 0.9.8/0.9.10) that `with_timeout_ms`
  does not raise, but a full rollout takes ≈15–40s. So the sidecar runs the
  rollout in the background and `skills.run_policy` polls `policy_status` to
  completion (each poll sub-10s) — returning a real `Reached`/`Timeout` the Verify
  gate acts on (verified end-to-end on MPS: three full rollouts, ~42s each, gated
  correctly). The step-wise path (`examples/safe_rollout.lex`, one grant-checked
  command at a time) is the other real-policy route — verified live, 64/80 unsafe
  commands blocked, 0 executed. Both need the gym sidecar + `lerobot`.

## The effect wall: `actuate` / `sense` are types

The judgment-vs-authority split isn't a runtime convention here — it's in the
type system. Every skill declares what it does to the world (DESIGN.md §4):

| effect | skills | meaning |
|---|---|---|
| `[sense]` | `read_joints`, `read_camera`, `policy_action`, `read_inlet` | reads a sensor — no physical output |
| `[actuate]` | `move_to`, `grasp`, `run_policy`, `connect_charger`, `apply_action` | drives a physical output — gated by the grant |
| `[net]` | all of the above | the transport (a localhost call to the sidecar) |

Because Lex effects **propagate**, this buys two enforcement layers for free:

**Compile time** — a "look but don't touch" routine that secretly actuates does
not type-check. `lex check` rejects it before it ever runs:

```sh
# a calibration fn typed [net, sense] that calls move_to ([actuate]):
lex check calibrate.lex
#   effect `actuate` not declared   (effect-not-declared)   ← REFUSED
```

**Run time** — `--allow-effects` is the grant's authority. Withhold `actuate`
and the *same* program becomes unreachable before a single command leaves the box:

```sh
lex run --allow-effects net,sense,io examples/demo.lex run
#   effect `actuate` not in --allow-effects   ← BLOCKED at the call site
```

`scripts/smoke.sh` asserts both (the `== effect wall ==` checks), so a skill that
quietly actuates under a `[sense]` signature fails CI. This is the property the
whole project rests on, made mechanical rather than aspirational.

## The budget wall: the grant caps how much a run may do

The effect wall says *whether* a skill may actuate. The budget says *how much*:
the grant carries `budget_actions` (max actuating commands) and `budget_wall_ms`
(max wall-clock), mirroring the lex-os manifest's `budget.max_commands` /
`budget.wall_clock_secs`. The in-box supervisor ([`src/budget.lex`](src/budget.lex),
pure) opens a ledger from the grant, charges one action per actuating step, and
is checked **before** each command leaves the box. On breach the run is `Killed`
(distinct from a grant `Denied`) and the breach is recorded in the trail.

`examples/budget_demo.lex` runs the same task as `make task` but with a
zero-action grant, so it is killed before a single command is sent:

```sh
make budget
#   [KILL] supervisor — action budget exhausted: 0/0 actions used
#   task KILLED after 0 attempt(s)
```

The trail then chains `task_started → killed` (with the breach reason), so the
kill is auditable, not just logged. `scripts/smoke.sh` asserts this (the
`== budget kill ==` checks). This is the runtime twin of the effect wall: the
effect wall stops actuation that was never granted; the budget stops actuation
that has run out of allowance — without lex-os or KVM in the loop.

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

The robot task also runs inside an unbypassable **Firecracker microVM** as a
lex-os guest agent (lex-robot#1, done): `sudo ./box/run_in_vm.sh` on a
Linux+KVM host — in-grant run completes with a verified audit chain, an
out-of-grant move is `command_denied` at the perimeter, and the kernel egress
wall drops non-allowlisted hosts. See [`box/README.md`](box/README.md) §4b.

## Agentic interactions: agents that meet, negotiate, and consent

The same judgment-vs-authority boundary, applied to **agent-to-agent** interaction
instead of a single robot arm. A pure-Lex sidecar (`sidecar/sim_sidecar.lex`)
serves a retro web dashboard, acts as an A2A peer, and hosts skills; the demos
below run on it. Each ships a `*_run.sh` launcher and a browser dashboard — open
http://localhost:8900 after starting.

What Lex enforces across them:
- **A2A between strangers** — two agents that never met exchange Ed25519-signed
  cards, verify them, consent, and open a session. `peer_meet` bootstraps the
  whole thing from a **QR code** (the proof they had no prior knowledge of each
  other) before buying battery charge.
- **lex-guard budget capability** — every payment is gated by a signed budget
  token; an over-budget or expired spend is refused before it leaves the agent
  (`peer_meet`, `ev_fleet`).
- **lex-trail provenance** — `logistics` writes each supplier delivery as a
  hash-chained, tamper-evident log.
- **Human-defined goals** — the goal is provided by a person at run time, not
  hardcoded (`src/human_goal.lex`): the fleet budget and the triage evacuation
  order both wait on a human answer.
- **LLM on the rails** — `trading`, `station`, `triage`, and `heist` let an LLM
  drive the decisions while the A2A grant layer gates every interaction.

| demo | run | the interaction |
|---|---|---|
| Peer meet | `examples/peer_meet_run.sh` | two robots that never met handshake via a QR bootstrap, then buy charge — payment gated by lex-guard |
| EV fleet | `examples/ev_fleet_run.sh` | vehicles charge under a shared fleet budget token |
| Logistics | `examples/logistics_run.sh` | supplier agents restock the bazaar with a hash-chained provenance trail |
| Trading floor | `examples/trading_run.sh` | LLM traders quote / bid / sell across commodity exchanges, tier-gated |
| Space station | `examples/station_run.sh` | module robots answer a hull-breach emergency over A2A sessions |
| Disaster triage | `examples/triage_run.sh` | sensor robots report casualties; evacuation needs human approval |
| Heist | `examples/heist_run.sh` | specialist robots infiltrate; A2A access + trail + a budget supervisor that kills on breach |

These pull the repo's Lex deps (lex-guard, lex-llm, lex-schema, lex-web, lex-jobs);
the LLM-driven ones additionally need a lex-llm provider configured.

> The bazaar-shopping and matchmaking-style A2A demos (an autonomous shopper,
> consent-based matchmaking) moved to
> **[lex-arena](https://github.com/alpibrusl/lex-arena)** along with the games
> and the Magentic Bazaar — see below.

## Games and commerce moved to lex-arena

The capability-gated turn games (tic-tac-toe, Bazaar Draft, Consent Match,
Charger Duel, Co-op Infiltration, Strategy Football, N-player Bazaar, Stamp of
Destiny, The Wedding Broker), the BYO-key AI-agent arena, and the **Magentic Bazaar** (governed agent commerce —
`gate.spend` + x402, LLM buyers/sellers, concurrent + live WS contention,
seller reputation, the lobby) all now live in
**[lex-arena](https://github.com/alpibrusl/lex-arena)** — see
[lex-robot#75](https://github.com/alpibrusl/lex-robot/issues/75) for why. The
A2A core, the bazaar/haggle/seller-LLM mechanics, and the Lex-native play host
(`sidecar/sim_sidecar.lex`) stay here — they're shared with this repo's own
robot-flavored A2A demos above — so lex-arena depends on this repo for them.

### The Robot Arena

The still-here robot demo is unrelated in name only to the moved games above:
`gate()` here is **control-authority arbitration** (which controller may drive
the arm right now — teleop handoff / lockout), and `record()` is a
**replayable, tamper-evident episode**. `examples/arena_demo.lex` shows it: one
arm shared by a human TELEoperator and an LLM PLANner, each with a signed
match-bound control token.

```sh
lex run --allow-effects crypto,fs_write,io,sql,time examples/arena_demo.lex run
#   PLAN  move to approach pose        ✓ control ok → EXECUTED move (0.5,0.1,0.2)
#   PLAN  rogue: act as PLAN ...        ⛔ REFUSED (control): controls TELE, cannot act as PLAN
#   PLAN  reach behind the wall         ✓ control ok → BLOCKED by grant — outside workspace
#   TELE  grip it hard                  ✓ control ok → CLAMPED grasp 99N → 15N
#   episode: 4 accepted commands, chain VALID — tamper-evident
```

The control gate refuses a rogue controller *before* the robot grant is ever
consulted; commands that pass are then bounded by the existing grant (workspace
block + force clamp, `src/grant.lex`); and the whole episode is a verifiable
lex-trail chain. `gate` = who may act · `grant` = physical envelope · `record` =
auditable episode.

> **Stepping back:** games, robots, and commerce are three apps on one
> substrate, now split across three repos: this one (robots + the shared A2A/
> commerce mechanics + the kernel), **[lex-arena](https://github.com/alpibrusl/lex-arena)**
> (where games and the Magentic Bazaar are played and hosted), and
> **[lex-games](https://github.com/alpibrusl/lex-games)** (the lean, trusted
> verifier both depend on). See **[docs/PLATFORM.md](docs/PLATFORM.md)** for
> the full substrate story.

## Portable identity: reputation an agent owns across apps ([#73](https://github.com/alpibrusl/lex-robot/issues/73))

The reputation above is DID-keyed, but so far attribution is only *claimed* — a
submission names a `did:lex` and is trusted to be it. The kernel's identity slice
makes it **owned**: an agent is an ed25519 keypair (`src/identity.lex`), so a
reputation submission is **signed**, not claimed — as a real
[lex-jose](https://github.com/alpibrusl/lex-jose) **JWT** (EdDSA), not a
hand-rolled detached signature: `{"alg":"EdDSA","typ":"JWT"}` over a JSON claims
document, decodable by any JOSE-aware tool. The registry
(`examples/agent_registry.lex`) binds a DID to its key on first sight and, from
then on, refuses any submission signed by a different key — and each submission
signs a claim over the *hash of the exact trail*, so a swapped or tampered trail
breaks the signature (JWT decode also re-checks the header's `alg`, closing off
algorithm-substitution attacks as part of the standard). Verified-only is
preserved by reusing the lex-games verifiers: reputation accrues **iff the
signature verifies AND the trail replays clean**.

Because one profile records the distinct **apps** a DID earned in, reputation is
**portable** — a single identity accumulates across apps, the whole point of a
kernel:

```sh
examples/portable_reputation_run.sh
#   board: did:lex:agent:atlas  reputation=150  sessions=2  apps=robot,agent-ops  rejected=1
#   portable reputation: atlas earned in 2 apps under one identity
#   attribution proven: impersonation rejected=1 (earns nothing)
#   tamper-evident: tampered submission credited=0 (earns nothing)
```

One agent earns a verified trail in the **robot** domain (`robot_task`) *and* in
**agent-ops** (`ops`), signs each, and its one profile carries the sum — while an
impersonator (same DID, different key) and a tampered trail both earn nothing.
That's the roadmap's exit criterion — *an agent carries identity + reputation
between two different apps* — together with the control plane below
(issue/scope/revoke grants).

## The control plane: issue, scope, and revoke grants ([#73](https://github.com/alpibrusl/lex-robot/issues/73))

Every Grant so far has been a **literal hardcoded** into whichever demo
constructs it — no record of who authorized it, for how long, or how to take it
back. The control plane (`src/control_plane.lex`) adds that missing verb set: an
**issuer** (a `did:lex`, holding a signing key) issues a scoped, time-boxed,
**revocable token** to a **subject** `did:lex`, as a real lex-jose JWT (the same
signing path as identity above). The token carries the actual Grant unchanged —
nothing about capability *checking* changes; the control plane governs how a
Grant came to exist, not what it permits:

```sh
lex run --allow-effects io,sql,time,fs_write,crypto examples/control_plane_demo.lex run
#   [1. valid, right subject] ADMITTED — in-workspace move: permitted; out-of-workspace
#       move: denied — control plane doesn't bypass the physical layer; 99N grasp clamped to 20N
#   [3. wrong subject presents it] REFUSED — token not issued to this subject
#   [4. revoked]                   REFUSED — token revoked
#   [5. expired]                   REFUSED — token expired
#   [6. forged (attacker's key)]   REFUSED — signature invalid
#   review trail: 1 issued, 1 admitted, 4 refused, 1 revoked — every decision is on the record
```

A validly-issued token still composes with every existing physical check —
`grant.in_workspace`/`clamp_grip` still refuse an out-of-bounds command under an
admitted token, the same as any hardcoded Grant. What's new is that possessing
the token's bytes isn't possessing the authority: a token presented by the wrong
subject, a revoked token id, an expired token, and a token forged by a different
signing key are all refused — and every issue/admit/refuse/revoke decision is
written to a lex-trail log, so the control plane is **reviewable**, not just
enforced.

## How it fits the ecosystem
- **[lex-arena](https://github.com/alpibrusl/lex-arena)** — where games are
  played and hosted, and the Magentic Bazaar; depends on this repo for the
  shared A2A/bazaar core and the play host (`sidecar/sim_sidecar.lex`).
- **[lex-games](https://github.com/alpibrusl/lex-games)** — the lean, trusted
  verifier both this repo and lex-arena depend on to replay-verify a trail.
- **lex-os** — runs `lex-robot` as a supervised box; the grant = physical safety
  envelope + budgets; supervisor can kill/reprovision.
- **lex-loom** — task orchestration as an evidence-gated graph:
  Perceive → Plan → Execute → Verify.
- **lex-trail** — hash-chained audit of commands + observations (also training
  provenance for LeRobotDataset episodes), and the per-move record in lex-games.
- **lex-guard** — capability-gated budget tokens: the signed allowance an agent
  spends against in the A2A commerce demos.
- **lex-llm** — high-level planner / skill selector.

## Known gaps (intentional / next)
- JSON is hand-built with `std.str`; could swap to `lex-schema/json_value`.
- No WebSocket streaming of sensor/state yet (HTTP request/response only).
- The Firecracker microVM run (issue #1, done — `box/README.md` §4b) needs a
  Linux+KVM host and is exercised manually, not in CI. CI-gating it (GitHub's
  Linux runners expose `/dev/kvm`) is the next hardening step.
- `record_episode` writes frames to `.npz`; full LeRobotDataset export is a follow-up.
