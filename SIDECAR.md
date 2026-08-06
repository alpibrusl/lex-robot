# lex-robot sidecar protocol

The sidecar is a small **Python process** that owns the LeRobot stack (drivers,
cameras, learned policies, the high-rate control loop) and exposes a few
**discrete skills** over a localhost HTTP API. `lex-robot` (the Lex side) is the
only caller; it adds effect typing, grant enforcement, and the audit trail.

- Transport: HTTP on `127.0.0.1:8900` (default). Localhost only ⇒ no auth.
- Request: `POST /skill/<name>` with a JSON body.
- Response: JSON. Actuating skills return `{ "outcome": "...", "detail": "..." }`.
- A future streaming channel (joint/camera at rate) is a WebSocket add-on
  (`/stream`), consumed in Lex via `net.dial_ws`. Not in v1.

## Skills

| `POST /skill/...` | body | response |
|---|---|---|
| `read_joints` | `{}` | `{ "names": [...], "positions": [...], "velocities": [...] }` |
| `read_camera` | `{ "name": "wrist" }` | `{ "width": N, "height": N, "jpeg_b64": "..." }` |
| `move_to` | `{ "x","y","z","rx","ry","rz" }` | `{ "outcome": "reached\|stalled\|timeout", "detail": "" }` |
| `grasp` | `{ "force": 12.0 }` | `{ "outcome": "...", "detail": "" }` |
| `run_policy` | `{ "name","goal","budget_ms" }` | `{ "status": "started" }` (async — see below) |
| `policy_status` | `{}` | `{ "status": "running" }` or `{ "status": "done", "outcome": "...", "detail": "" }` |
| `record_episode` | `{ "task": "..." }` | `{ "episode_id": "...", "frames": N, "path": "..." }` |
| `listen` | `{ "seconds": N }` | `{ "transcript": "...", "confidence": 0.9 }` — mic capture + LOCAL transcription; raw audio never leaves the sidecar |

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
`timeout` → budget exhausted. The Lex side maps these to the `Outcome` ADT
(`parse_outcome` in `skills.lex`); anything unrecognised becomes `Stalled(raw)`.

## Division of responsibility

| Concern | Owner |
|---|---|
| Motor bus, cameras, drivers (SO-101/Koch/ALOHA) | sidecar (LeRobot) |
| Learned policy inference + the 30–1000 Hz loop | sidecar (LeRobot) |
| LeRobotDataset recording | sidecar, triggered by `record_episode` |
| **Capability/grant enforcement** | **Lex (`grant.lex`)** + lex-os supervisor |
| **Effect typing of skills** | **Lex (`skills.lex`)** |
| **Audit trail** | **Lex (lex-trail), later** |
| Budget / liveness / kill / reprovision | lex-os supervisor (outside the box) |

## Real hardware — XLeRobot Tier 3

`sidecar/xlerobot_sidecar.py` drives a physical XLeRobot 0.4.0 when
`LEX_ROBOT_HW=1` is set, through LeRobot's own SO-101 (`SOFollower`) and
motor-bus (`FeetechMotorsBus`) APIs. **This has not been run against
physical hardware in this repo's CI or by its authors** — there is no
XLeRobot in this loop to validate against, so treat it as a bench-test
starting point (low torque, no load, hand on the e-stop) rather than a
plug-and-drive certainty. Community XLeRobot software — especially the
0.4.0 dual-wheel differential base — moves fast and isn't merged upstream
into `lerobot`, so if your installed version's API doesn't match, the
sidecar fails loudly at connect time (`SystemExit` naming the mismatch)
rather than silently running with the wrong assumptions.

What it does and doesn't do:
- **Arms** — each SO-101 is brought up as a real `lerobot.robots.so_follower`
  `SO101Follower`; `move_arm`'s Cartesian target goes through LeRobot's own
  `robot_kinematic_processor` IK/FK, polled in a bounded closed loop until
  the end-effector is within tolerance or a timeout. If your `lerobot`
  install doesn't expose that kinematics module, `move_arm` fails loudly
  per call rather than pretending to reach.
- **Grasp** — position-based (gripper closed to a fraction of full-close
  scaled by the requested/firmware-capped force), *not* current/force
  closed-loop. `Present_Load` is read best-effort for the audit trail only
  — it is never the pass/fail signal. A real force-feedback grasp is a
  known gap, not a hidden one.
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
- **Camera** — `lerobot.cameras.opencv.OpenCVCamera`, JPEG-encoded via
  Pillow if installed (falls back to an empty `jpeg_b64` if not — the frame
  is still captured, just not encoded).
- **Mic (`listen`)** — records locally with `sounddevice` and transcribes
  locally with `faster-whisper`; raw audio never leaves the process, same
  as the stub's documented contract.

Environment variables (see the module docstring in `xlerobot_sidecar.py`
for the full, current list): `LEX_XLE_LEFT_PORT` / `LEX_XLE_RIGHT_PORT` /
`LEX_XLE_BASE_PORT` (serial ports, required), `LEX_XLE_LEFT_ID` /
`LEX_XLE_RIGHT_ID` (LeRobot calibration ids), `LEX_XLE_WHEEL_RADIUS_M` /
`LEX_XLE_TRACK_WIDTH_M` (diff-base geometry), `LEX_XLE_MAX_REL_TARGET`
(optional per-step joint clamp, defense in depth alongside the grant).

```sh
pip install "lerobot[feetech]" sounddevice faster-whisper pillow
LEX_XLE_LEFT_PORT=/dev/ttyACM0 LEX_XLE_RIGHT_PORT=/dev/ttyACM1 \
  LEX_XLE_BASE_PORT=/dev/ttyACM2 LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py
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
