# leLab and lex-robot

[huggingface/leLab](https://github.com/huggingface/leLab) is LeRobot's web UI:
calibrate, teleoperate, record into a `LeRobotDataset`, launch training with live
logs, run inference, replay, upload to the Hub — a Vite frontend on `:8080` and a
FastAPI/uvicorn backend on `:8000`. It started at the 2025 LeRobot Worldwide
Hackathon and is maintained by the LeRobot team.

lex-robot sits **above** LeRobot and does not build a brain. So the question
"does leLab overlap us?" has a boring answer and an interesting one.

## The boring answer: almost no overlap

| leLab workflow | lex-robot today | verdict |
|---|---|---|
| calibrate | none — `capture_waypoints.py` defers to `lerobot-calibrate` | no overlap |
| teleoperate (leader→follower) | `GET /control` Cartesian jog, `scripted_teleop.py` | different modality |
| record → `LeRobotDataset` | `GET /teach` + `teach_to_dataset.py` | **real overlap** |
| train + live logs | none (`lerobot-train`, `xlerobot_rl_train.py`) | no overlap |
| inference / replay / Hub upload | `teach_replay` only | mostly no overlap |
| **what the grant did** | `GET /governance` (this change) | leLab has no equivalent |

The one duplicated strip is record-a-demonstration → dataset, and even there the
modality differs: leLab records leader–follower teleoperation, `teach` records
hand-guided motion with the torque off. Neither is a reimplementation of the
other, and the conversion into a real `LeRobotDataset` is done by *lerobot's own
API* in both cases (`sidecar/teach_to_dataset.py`).

Nothing here is a reason to build calibration, training or Hub upload UI. Use
leLab for those.

## The interesting answer: two authority paths is the actual problem

leLab's backend drives LeRobot's `Robot` classes directly. lex-robot's pages
drive `POST /skill/*`, which is where `_grant_workspace_violation` refuses an
out-of-box target, `_grant_max_grip_force` clamps grip force, the per-bus locks
serialise the serial traffic, and (now) the ledger records what happened.

Run both against the same arms and you have **two independent paths to the same
servos, one of which the grant does not cover**. That is the arrangement lex-os
exists to prevent — "do not add a second, independent source of authority" is the
one invariant in that repo's CLAUDE.md. So the useful thing to build was never a
rival record UI. It was these two:

---

## 1. `GET /governance` — the page leLab structurally can't have

Served by `xlerobot_sidecar.py` alongside `/control`, `/teach` and `/display`:
same inline-HTML, no-build-step, works-at-every-tier pattern.

![the governance view](../media/governance.png)

It shows three things:

**The grant, and which of its bounds this sidecar actually checks.** A dashboard
that lists a declared bound as if it were enforced manufactures confidence the
code doesn't back, so each row says which function does the checking, or that
nothing here does. Today that surfaces a real gap: `bases.*.floor_area_m` and
`bases.*.max_speed_mps` are in `manifests/xlerobot.capsule.json`, but `move_base`
only clamps against the `LEX_XLE_HARD_SPEED_MPS` firmware floor and never checks
the floor box at all. Same for `arms.*.max_velocity_mps` and `arms.*.max_force_n`.
The page lists them as **declared, not enforced** rather than quietly implying a
box that isn't there.

**Every authority-exercising call, with the verdict the sidecar already reached**
— `allowed` / `denied` / `clamped` / `failed` / `unknown`. Read-only polling is
skipped by default (`/control` alone polls four times a second, which would bury
every real decision); `LEX_XLE_LEDGER_READS=1` includes it.

**A hash chain over the sequence.** Each decision emits `cap.invoked` /
`cap.completed` using lex-trail's own event-id formula
(`sha256(kind \x00 parent \x00 payload \x00 ts_ms)`), so `GET /governance/trail`
replays under `lex-trail` and reconciles against a lex-os audit log via
`scripts/reconcile_audit.py`. The in-memory window is bounded; evicted events
leave a checkpoint the retained window still verifies against, and
`LEX_XLE_TRAIL_PATH` keeps the full chain on disk.

**It observes; it never decides.** `sidecar/governance.py` has no enforcement
branch, and `classify()` never returns a verdict the sidecar didn't already
reach — when the reply doesn't say, the answer is `unknown`, not a guess.
Adding a second opinion here would be the exact mistake this layer is about.

## 2. `sidecar/lelab_adapter.py` — leLab's frontend over the skill API

```sh
python3 sidecar/xlerobot_sidecar.py &     # the governed robot, :8900
python3 sidecar/lelab_adapter.py          # leLab's routes, :8000
curl -s localhost:8000/lex/routes | python3 -m json.tool
```

Speaks leLab's HTTP routes on leLab's own port, and executes nothing itself:
every request that touches the robot becomes a `POST /skill/*`, inheriting the
grant gate, the firmware floors, the bus locks and the ledger. Point leLab's
Vite frontend at it and the *same UI* is driving a bounded arm:

```console
$ curl -s -X POST localhost:8000/move-arm -d '{"arm":"left","x":9.0,"y":0.1,"z":0.2}'
{"success": false, "governed": true,
 "request": {"arm": "left", "x": 9.0, "y": 0.1, "z": 0.2},
 "result": {"outcome": "denied",
            "detail": "x=9.000 outside granted workspace [0.05,0.45] for left arm"}}
```

…and that refusal appears in `/governance` a second later, in the chain.

### What it serves

| leLab route | becomes |
|---|---|
| `GET /health` | sidecar `/health` + `read_grant` |
| `GET /joint-positions` | `read_joints` on both arms, translated to leLab's URDF joint names |
| `POST /move-arm` | `move_arm` — absolute Cartesian target, grant-gated |
| `POST /stop-teleoperation`, `GET /teleoperation-status` | adapter session state (no robot call) |
| `GET /available-cameras`, `GET /camera-feed/{cam}` | `read_camera`, restreamed as MJPEG |
| `POST /start-recording` | `teach_start` |
| `POST /stop-recording`, `POST /recording-exit-early` | `teach_stop` |
| `GET /recording-status` | `teach_status` |
| `GET /datasets` | `teach_list` |
| `GET /lex/routes`, `GET /lex/governance` | this table; a link to the governance view |

### What it refuses, and why that's the point

leLab's surface is much wider than the skill API. The honest answer to a route
the skill API cannot express is a `501` naming the reason — not a
plausible-looking implementation that quietly reaches around the grant.

**Not expressible through the skill API** (implementing it here would mean a
second path to the servos):

- `/move-arm` in its leader–follower form — a continuous mirroring loop between
  two arms, with no target in it and no leader on this side to read.
- `/start-calibration` and friends — no calibration skill exists, and
  calibration drives the servos through their full range.
- `/start-inference` — this sidecar exposes no policy-execution skill
  (`gym_sidecar.py`'s `run_policy` is the governed shape, in a different sidecar).
- `/available-ports`, `/start-port-detection` — serial-bus enumeration, below
  the skill API.
- `/ws/joint-data` — the sidecar's own `GET /stream` is the governed equivalent
  and speaks a different shape.
- `/recording-rerecord-episode` — teach has one demonstration per start/stop and
  no episode index to re-take.

**Not lex-robot's layer** (never touches the arm, so there is nothing to govern —
run leLab against LeRobot directly): `/jobs/*` (training), `/upload-dataset`,
`/hf-auth/*`, `/system/*`, `/get-configs`, `/robots*`, dataset management.

Two smaller refusals in the same spirit: a `RecordingRequest` with
`num_episodes > 1` is refused rather than silently recording one and reporting
success, and a `/move-arm` body missing an axis is refused rather than defaulting
`z` to 0 and driving the arm at the floor.

### Two deliberate differences from leLab's backend

- **CORS is not `*`.** leLab sets `allow_origins=["*"]`; this port can move an
  arm, and a wildcard lets any page the operator happens to open drive it.
  Default is `http://localhost:8080` (leLab's Vite dev server), override with
  `LEX_LELAB_ORIGIN`.
- **It refuses to start without a sidecar.** An adapter that came up anyway
  would answer leLab's polls with invented state and the operator would have no
  way to tell. Refuse, don't downgrade.

### Status

Prototype, verified end-to-end against the Tier-1 stub sidecar (the route
translation, the grant refusal round-trip, the teach recording flow, the ledger
entries). It has **not** been driven by leLab's actual frontend build, and the
frontend will certainly want routes this doesn't serve — `GET /lex/routes` is
there so that's a five-second question rather than a debugging session. The
translation layer is pure functions with unit tests
(`sidecar/test_lelab_adapter.py`); nothing about it needs a robot to test.

## Where this leaves the two projects

leLab is the front door to LeRobot's lifecycle. lex-robot is the envelope around
whatever policy comes out of it. The overlap is one strip of recording UI, and
the complement — "leLab's UX, but the arm physically cannot leave the granted
workspace, and every command is in a hash chain" — is a better demo than either
alone. That is also exactly the Switzerland-layer position in `POSITIONING.md`:
run above LeRobot, don't compete with it.
