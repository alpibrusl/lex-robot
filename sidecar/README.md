# lex-robot sidecars

Three interchangeable backends behind the same [SIDECAR.md](../SIDECAR.md)
protocol. The Lex side never changes — you swap the backend as you move from
logic tests → physics sim → real hardware.

| backend | file | deps | what it tests |
|---|---|---|---|
| **stub** | `sim_sidecar.py` | none (stdlib) | grant/effect/orchestration logic; instant canned outcomes |
| **gym** | `gym_sidecar.py` | `gymnasium gym-pusht pillow numpy` (+ `lerobot` for `run_policy`) | real 2D physics (PushT), closed-loop behaviour, episode capture |
| **hardware** | _build target_ | `lerobot` + drivers | a real SO-101 / Koch / ALOHA via LeRobot |

All listen on `127.0.0.1:8900` (override `LEX_ROBOT_SIDECAR_PORT`).

## Stub (no install)

```sh
python3 sidecar/sim_sidecar.py &
lex run --allow-effects net,io examples/demo.lex run
```

## Gym (PushT — light real physics, no MuJoCo)

```sh
pip install -r sidecar/requirements.txt      # gymnasium gym-pusht pillow numpy
python3 sidecar/gym_sidecar.py &
lex run --allow-effects net,io examples/demo.lex run
```

PushT is a 2D point-pusher, so the mapping is lossy and documented per skill in
`gym_sidecar.py`:
- `move_to` uses x,y only (z/rotation ignored); steps the env toward the target.
- `grasp` → `stalled` (no gripper in PushT).
- `read_joints` → the 2D agent position.
- `read_camera` → the rendered frame as base64 JPEG.
- `run_policy` → loads a pretrained LeRobot policy; **the rollout loop is the one
  TODO** (version-specific — see the `# TODO` in the file).
- `record_episode` → captures frames to a `.npz` (full LeRobotDataset export is a
  follow-up).

> **Not run in CI.** `gym_sidecar.py` follows the documented gym-pusht /
> gymnasium API but hasn't been executed here. The env id and the LeRobot policy
> import path can shift between releases — verify against your install.

## Going to real hardware
Copy `gym_sidecar.py`, replace the `Sim` env calls with LeRobot robot/policy
calls (the `# REAL:` markers in `sim_sidecar.py` show the shape), and enforce
**firmware joint/force limits + a hardware e-stop** independently — the Lex grant
is the logical boundary, not physical safety (see DESIGN.md §8).
