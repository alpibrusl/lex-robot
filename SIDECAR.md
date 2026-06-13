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
| `run_policy` | `{ "name","goal","budget_ms" }` | `{ "outcome": "...", "detail": "" }` |
| `record_episode` | `{ "task": "..." }` | `{ "episode_id": "...", "frames": N, "path": "..." }` |

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

## Defense in depth (read DESIGN.md §8)

The sidecar **must independently enforce hard limits** (joint/force/workspace)
in firmware/driver config, plus a hardware e-stop. The Lex grant is the
*logical* boundary and the legible record; it is **not** a substitute for
physical safety. If the Lex layer is bypassed, the firmware floor must still
hold.

## Reference skeleton (not included; build target)

A FastAPI app: one route per skill, each wrapping a LeRobot call, returning the
JSON above. `run_policy` runs LeRobot's policy loop until goal/timeout and
reports the outcome. Keep it dumb — all judgment and policy live on the Lex side.
