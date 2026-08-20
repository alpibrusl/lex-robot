# lex-robot sidecar protocol

The sidecar is a small **Python process** that owns the LeRobot stack (drivers,
cameras, learned policies, the high-rate control loop) and exposes a few
**discrete skills** over a localhost HTTP API. `lex-robot` (the Lex side) is the
only caller; it adds effect typing, grant enforcement, and the audit trail.

- Transport: HTTP on `127.0.0.1:8900` (default). Localhost only ⇒ no auth.
- Request: `POST /skill/<name>` with a JSON body.
- Response: JSON. Actuating skills return `{ "outcome": "...", "detail": "..." }`.
- Streaming: `GET /stream` upgrades to a WebSocket pushing joint + base
  state as JSON text frames at `LEX_STREAM_HZ` (default 10; served by the
  xlerobot sidecar via `sidecar_lib.maybe_stream`). Consumed in Lex via
  `net.dial_ws` — see `examples/stream_demo.lex`. A dial_ws handler's
  `WsAction` cannot hang up, so a bounded stream ends server-side
  (`LEX_STREAM_MAX_FRAMES`; 0 = unbounded).

## Skills

| `POST /skill/...` | body | response |
|---|---|---|
| `read_joints` | `{}` | `{ "names": [...], "positions": [...], "velocities": [...] }` |
| `read_arm_pose` | `{ "arm": "left\|right" }` | `{ "ok": bool, "x","y","z", "detail"? }` |
| `read_grant` | `{}` | `{ "ok": bool, "arms": {...}, "grippers": {...} }` — the loaded grant's workspace/force limits, see "Grant enforcement" below |
| `read_camera` | `{ "name": "head\|left\|right" }` | `{ "width": N, "height": N, "jpeg_b64": "..." }` |
| `move_to` | `{ "x","y","z","rx","ry","rz" }` | `{ "outcome": "reached\|stalled\|timeout", "detail": "" }` |
| `grasp` | `{ "force": 12.0 }` | `{ "outcome": "...", "detail": "" }` |
| `run_policy` | `{ "name","goal","budget_ms" }` | `{ "status": "started" }` (async — see below) |
| `policy_status` | `{}` | `{ "status": "running" }` or `{ "status": "done", "outcome": "...", "detail": "" }` |
| `record_episode` | `{ "task": "..." }` | `{ "episode_id": "...", "frames": N, "path": "..." }` |
| `listen` | `{ "seconds": N }` | `{ "transcript": "...", "confidence": 0.9 }` — mic capture + LOCAL transcription; raw audio never leaves the sidecar |
| `show_prompt` | `{ "question", "options": ["...", ...] }` | outcome — a question with large tap targets on the kiosk display (`GET /display`), its one interactive kind |
| `read_touch` | `{}` | `{ "option": "...", "detail"? }` — the one unread tap answering the prompt currently showing; `""` when nothing was tapped (or no prompt is up). The tap itself arrives via `POST /display/touch` from the kiosk page, never through `/skill/` — a human's tap is input at the sidecar, and the governed program only sees it through this grant-gated read |
| `detect_object` | `{ "name": "..." }` | `{ "found": bool, "cx","cy","w","h", "confidence", "detail" }` — 2D normalized bounding box (deliberately not a world pose). The sidecar captures a head-camera frame locally and ships the JPEG to the split-compute vision service named by `LEX_XLE_VISION_URL` (`sidecar/vision_service.py` — a Mac Studio, Jetson, or any box serving an OpenAI-compatible VLM; see `deploy/VISION_SPLIT.md`). Without the URL, Tier-3 says so honestly; the Tier-1 stub answers with an explicitly-labeled canned detection |

### `run_policy` is asynchronous
A full closed-loop rollout runs tens of seconds — longer than the Lex `std.http`
client's hard ~10s timeout. So `run_policy` **starts the rollout in the
background and returns immediately** with `{ "status": "started" }`; the Lex side
(`skills.run_policy`) then polls `policy_status` — each call sub-10s — until it
reports `{ "status": "done", ... }`. `policy_status` is handled *without* the
sidecar's per-skill lock, so it stays responsive while the rollout holds it.
A simpler synchronous sidecar (the stdlib stub) may instead return an `outcome`
inline from `run_policy`; the Lex side accepts either shape.

### Outcome vocabulary
`reached` → goal met · `stalled` → could not progress (detail explains) ·
`timeout` → budget exhausted · `denied` → refused by a loaded grant, never
sent to hardware (see "Grant enforcement" below). The Lex side maps these to
the `Outcome` ADT (`parse_outcome` in `skills.lex`), which already has a
`Denied` variant; anything unrecognised becomes `Stalled(raw)`.

### Grant enforcement (workspace box + grip-force ceiling)
Normally the *Lex* layer is what checks a command against a grant, before
the request ever reaches the sidecar (`grant.lex`, see "Division of
responsibility" below) — the sidecar itself has historically trusted its
caller. Any caller that talks to the sidecar directly instead of through Lex
(the `GET /control` browser page, a raw `curl`, anything hitting this HTTP
API on its own) bypasses that check entirely, so the sidecar now *also*
loads the same grant and applies the two checks that matter most for a
directly-actuated arm:
- **`move_arm`**: the target is checked against that arm's `workspace_m` box.
  Outside it → `{"outcome": "denied", ...}`, **nothing is sent to
  hardware** — a position can't be safely "clamped" into an envelope the way
  a scalar can, so this is a refusal, not an adjustment (same philosophy as
  `examples/xlerobot_demo.lex`'s inline grant).
- **`grasp_arm`**: the requested force is **clamped** (never amplified) to
  that arm's granted `max_grip_force_n` — a second, independent layer above
  the existing `HARD_GRIP_N` firmware floor.

The grant is loaded from `manifests/xlerobot.capsule.json` by default
(override with `LEX_XLE_GRANT_PATH`); if it can't be read, these checks are
simply skipped — best-effort, same degrade-gracefully pattern as every other
optional piece of hardware in this file, not a hard requirement to run. This
applies at every tier (stub included), not just real hardware. `GET
/control` reads the same limits via `read_grant` and greys out jog buttons
that would leave the box, so an operator gets instant feedback instead of a
round-trip "denied".

## Division of responsibility

| Concern | Owner |
|---|---|
| Motor bus, cameras, drivers (SO-101/Koch/ALOHA) | sidecar (LeRobot) |
| Learned policy inference + the 30–1000 Hz loop | sidecar (LeRobot) |
| LeRobotDataset recording | sidecar, triggered by `record_episode` |
| **Capability/grant enforcement** | **Lex (`grant.lex`)** + lex-os supervisor, primarily — the sidecar also applies the workspace-box/grip-force part of the same grant as a second layer for callers that bypass Lex (see "Grant enforcement" above); it does not replace effect typing, budget, or the audit trail |
| **Effect typing of skills** | **Lex (`skills.lex`)** |
| **Audit trail** | **Lex (lex-trail), later** |
| Budget / liveness / kill / reprovision | lex-os supervisor (outside the box) |

## Real hardware — XLeRobot Tier 3

`sidecar/xlerobot_sidecar.py` drives a physical XLeRobot 0.4.0 when
`LEX_ROBOT_HW=1` is set, through LeRobot's own SO-101 (`SOFollower`) and
motor-bus (`FeetechMotorsBus`) APIs. **Both SO-101 arms, both left/right
cameras, the head camera, and the dual-wheel base have been bench-tested
against this code** (`lerobot` 0.6.1, low torque, hand on the e-stop): serial
connect, calibration, joint-space moves, Cartesian `move_to` via
`RobotKinematics`/`placo`, `read_arm_pose`, multi-camera capture, the base
sharing a bus port with an arm (see "Base" below), and `move_base` actually
driving the base forward — confirmed by eye, multiple times — plus the `GET
/control` browser page (jog + gripper, live joint/pose/camera view, head
camera + base telemetry) all confirmed working end-to-end, including a live
browser session. **Not yet exercised against real hardware**: force-based
grasp (still position-based, see "Grasp" below) and turning the base
(`move_base` has only been driven straight forward so far — turn-in-place
and the `omega` branch of `drive()` are untested). Community XLeRobot
software — especially the 0.4.0 dual-wheel differential base — moves fast
and isn't merged upstream into `lerobot`, so if your installed version's API
doesn't match, the sidecar fails loudly at connect time (`SystemExit` naming
the mismatch) rather than silently running with the wrong assumptions.

What it does and doesn't do:
- **Arms** — each SO-101 is brought up as a real `lerobot.robots.so_follower`
  `SO101Follower`; `move_arm`'s Cartesian target goes through LeRobot's own
  `robot_kinematic_processor` IK/FK, polled in a bounded closed loop until
  the end-effector is within tolerance or a timeout. IK/FK needs a
  `RobotKinematics` model built from an on-disk URDF (`LEX_XLE_URDF_PATH`)
  plus the `placo` solver (`pip install "lerobot[kinematics]"`) — lerobot
  no longer builds this into the robot object for you, and no URDF ships
  with `lerobot`/`placo`; the one bench-tested here came from
  [TheRobotStudio/SO-ARM100](https://github.com/TheRobotStudio/SO-ARM100)'s
  `Simulation/SO101/so101_new_calib.urdf` (sparse-clone it the same way as
  the G1 assets below). If the URDF isn't configured, `placo` isn't
  installed, or your `lerobot` install doesn't expose that kinematics
  module, `move_arm` fails loudly per call rather than pretending to
  reach. lerobot 0.6.1's `InverseKinematicsEEToJoints` is a pipeline
  processor step, not a plain function — it must be invoked as
  `step(lerobot.processor.create_transition(observation=obs, action=target))`
  and read back via `TransitionKey.ACTION`, with the target keyed
  `ee.x`/`ee.y`/`ee.z`/`ee.wx`/`ee.wy`/`ee.wz`/`ee.gripper_pos` (all six
  required, including a passthrough `gripper_pos` even when not moving the
  gripper); calling its `.action()` directly raises `Transition is not
  set`. `compute_forward_kinematics_joints_to_ee` also mutates its input
  joints dict in place (pops the `*.pos` keys, writes `ee.*` keys into the
  same object) and returns `ee.x`/`ee.y`/`ee.z`, not bare `x`/`y`/`z` — the
  sidecar passes it a defensive copy. A browser jog/monitor interface is
  served at `GET /control`, showing live joint state, end-effector pose
  (via `read_arm_pose`), camera views, and buttons for manual jog and gripper
  control — same pattern as `GET /display`. Below the two arm panels, a
  read-only third row shows the head camera feed and base/wheels telemetry
  (dead-reckoned pose, and `wheel_temps_c` once a base is wired up) — no
  drive controls, since `move_base` isn't exercised from this page. The
  "Enable control" toggle is explicitly not a safety mechanism; it is UI
  convenience only.
- **Grasp** — position-based (gripper closed to a fraction of full-close
  scaled by the requested/firmware-capped force), *not* current/force
  closed-loop. `Present_Load` is read best-effort for the audit trail only
  — it is never the pass/fail signal. A real force-feedback grasp is a
  known gap, not a hidden one.
  
  **Gripper direction troubleshooting:** If `grasp_arm`/`release_arm` seem to
  do the opposite of what they say, the gripper motor's `drive_mode` field in
  the arm's LeRobot calibration file (`~/.cache/huggingface/lerobot/calibration/robots/so_follower/<id>.json`)
  may be inverted relative to the firmware. This is a per-arm calibration-data
  quirk — lerobot's `lerobot-calibrate` sweep sets `drive_mode` based on
  whichever physical direction the gripper happened to move, not a fixed "open"
  convention. Fix by flipping the motor's `drive_mode` (0→1 or 1→0) in the
  calibration JSON and restarting the sidecar.
- **Base** — 0.4.0's dual-wheel differential base has no canonical
  `lerobot` Robot class yet, so this drives it directly over a
  `FeetechMotorsBus` in velocity mode (`LEX_XLE_BASE=diff`, the default).
  The 0.3.0-era 3-omni-wheel kit *is* canonical (`lerobot.robots.lekiwi`)
  and is driven through that class instead (`LEX_XLE_BASE=omni`). Either
  way, position is **dead-reckoned** (integrated from commanded velocity),
  not sensor-verified — no encoder feedback or localization is wired in,
  so `reached` on the base is an estimate, not a guarantee. Wheel slip on
  a real floor will drift it; a future encoder/AprilTag localization pass
  is the fix.

  **This unit's physical servo bus layout** (bench-verified, not yet wired
  into any code — the base/tower aren't driven by this sidecar yet, this is
  a hardware-configuration reference for whoever writes that next): each
  arm's own 6 servos keep the standard IDs 1-6, but the wheels and the
  central-tower (camera pan/tilt) servos are wired onto the *same* physical
  bus as one arm apiece — a fresh Feetech servo defaults to ID 1 out of the
  box, which collides with that arm's own `shoulder_pan`, so each was
  reassigned via `FeetechMotorsBus.setup_motor()` (isolate the one new
  servo alone on the bus, since the exact-match ID scan can't disambiguate
  multiple unconfigured devices, then reprogram it) to a non-colliding ID:
  **wheels = 9, 10; tower = 7, 8**. Confirmed via `scan_port` with
  everything reconnected in its final layout: one bus reports
  `[1,2,3,4,5,6,7,8]` (that arm + the tower), the other
  `[1,2,3,4,5,6,9,10]` (the other arm + both wheels) — no ID conflicts
  anywhere. `LEX_XLE_BASE_LEFT_ID`/`LEX_XLE_BASE_RIGHT_ID`'s code defaults
  (1/2) do **not** match this unit's actual wheel IDs (9/10) — driving the
  base for real will need those env vars set explicitly, and the tower's
  pan/tilt servos (7/8) have no code path at all yet (the camera here is
  still a plain fixed `OpenCVCamera`, no pan/tilt control).

  **Bus-sharing (bench-verified against real hardware):** on this unit the
  wheels share the *same* physical bus/port as one arm's own 6 servos (see
  the layout above), not a dedicated port. `_HwDiffBase` accepts either
  `LEX_XLE_BASE_PORT` (a genuinely dedicated port) or
  `LEX_XLE_BASE_SHARED_ARM=left|right` (reuse that arm's already-connected
  bus — mutually exclusive with `LEX_XLE_BASE_PORT`). The first attempt at
  sharing a bus registered `wheel_left`/`wheel_right` directly into the
  arm's `FeetechMotorsBus.motors` dict — that looked like it worked (wheels
  spun up into velocity mode, `wheel_temps_c` read back fine) but silently
  broke the arm: `SO101Follower.get_observation()` reads `Present_Position`
  for *every* motor in `.motors` with no explicit list, and that register is
  calibration-normalized, so it `KeyError`'d on the wheels' missing
  calibration the moment anything polled arm pose (`read_arm_pose`, the
  `/control` page). The fix: `_HwDiffBase` now drives the wheels through the
  bus's private, ID-based primitives (`_write`/`_sync_write`/`_sync_read`,
  register addresses looked up once via `get_address`, sign-magnitude
  encoding done by hand for the signed `Goal_Velocity` register) — these
  touch only the raw serial protocol and never consult `.motors` or
  `.calibration`, so they can't collide with the owning `_HwArm`'s own
  bookkeeping. Confirmed live: `wheel_temps_c` reads real values (~38-40°C)
  and `read_arm_pose`/`read_joints` on the sharing arm keep working
  correctly, polled repeatedly, while the base is attached. `move_base`
  (actually spinning the wheels) has not yet been exercised — the velocity
  math and sign-magnitude encoding are implemented per the STS3215
  convention (matching lekiwi's `_degps_to_raw`) but not bench-verified.
  `read_base`/`move_base` also fail honestly now instead of crashing when no
  base is configured at all (`_hw_base_missing()`, same pattern as
  `_hw_arm_missing()`).
- **Camera** — three independent, best-effort slots ("head", "left", "right")
  via `lerobot.cameras.opencv.OpenCVCamera`. Each slot is opened only if its
  corresponding env var is set (`LEX_XLE_CAMERA_HEAD_INDEX`, `LEX_XLE_CAMERA_LEFT_INDEX`,
  or `LEX_XLE_CAMERA_RIGHT_INDEX`); a slot that fails to open (missing device, wrong
  index, etc.) stays unavailable rather than crashing the sidecar. JPEG-encoded via
  Pillow if installed (falls back to an empty `jpeg_b64` if not — the frame is still
  captured, just not encoded). The `/control` page displays each available camera
  view live.
- **Mic (`listen`)** — records locally with `sounddevice` and transcribes
  locally with `faster-whisper`; raw audio never leaves the process, same
  as the stub's documented contract.

Environment variables (see the module docstring in `xlerobot_sidecar.py`
for the full, current list): `LEX_XLE_LEFT_PORT` / `LEX_XLE_RIGHT_PORT`
(serial port per arm — at least one required; a missing arm's skills answer
with an honest error, so a half-assembled build runs during bring-up),
`LEX_XLE_BASE_PORT` (optional), `LEX_XLE_LEFT_ID` /
`LEX_XLE_RIGHT_ID` (LeRobot calibration ids), `LEX_XLE_WHEEL_RADIUS_M` /
`LEX_XLE_TRACK_WIDTH_M` (diff-base geometry), `LEX_XLE_MAX_REL_TARGET`
(optional per-step joint clamp, defense in depth alongside the grant),
`LEX_XLE_URDF_PATH` / `LEX_XLE_URDF_TARGET_FRAME` (Cartesian IK/FK — see
"Arms" above).

```sh
pip install "lerobot[feetech,kinematics]" sounddevice faster-whisper pillow

# URDF isn't bundled with lerobot/placo -- sparse-clone just the Simulation
# folder from the SO-ARM100 hardware repo (same pattern as the G1 assets
# above):
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/TheRobotStudio/SO-ARM100.git /tmp/so-arm100
git -C /tmp/so-arm100 sparse-checkout set Simulation

LEX_XLE_LEFT_PORT=/dev/ttyACM0 LEX_XLE_RIGHT_PORT=/dev/ttyACM1 \
  LEX_XLE_BASE_PORT=/dev/ttyACM2 \
  LEX_XLE_URDF_PATH=/tmp/so-arm100/Simulation/SO101/so101_new_calib.urdf \
  LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py
```

The pure kinematics helpers (`diff_drive_wheel_speeds`, `bearing_and_turn`,
`clamp`) that back the base's control loop are unit-tested without any
hardware or `lerobot` install: `pip install pytest && cd sidecar && python3
-m pytest test_xlerobot_hw.py`.

## Defense in depth (read DESIGN.md §8)

The sidecar **must independently enforce hard limits** (joint/force/workspace)
in firmware/driver config, plus a hardware e-stop. The Lex grant is the
*logical* boundary and the legible record; it is **not** a substitute for
physical safety. If the Lex layer is bypassed, the firmware floor must still
hold.

## Reference skeleton (not included; build target)

A FastAPI app: one route per skill, each wrapping a LeRobot call, returning the
JSON above. `run_policy` kicks off LeRobot's policy loop on a background worker
and returns at once; `policy_status` reports progress until the worker finishes.
Keep it dumb — all judgment and policy live on the Lex side.
