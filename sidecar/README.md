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
- `run_policy` → loads a pretrained LeRobot policy and runs it closed-loop,
  **with correct normalization** (verified: lerobot 0.5.1 + `lerobot/diffusion_pusht`
  on Apple MPS, ~0.9 peak coverage on good seeds). Needs `pip install lerobot`.
  `budget_ms` maps to a step cap (~10ms/step, capped at the 300-step episode);
  outcome is `reached` when peak coverage ≥ `LEX_ROBOT_SOLVE_REWARD` (default
  0.90, matching the policy's reported mean) or the env terminates.
  - Normalization fix: lerobot 0.5.x moved normalization into *processor
    pipelines*, and the old checkpoint has no `policy_preprocessor.json`. We
    build the processors from the dataset stats
    (`make_pre_post_processors(cfg, dataset_stats=LeRobotDatasetMetadata("lerobot/pusht").stats)`)
    and run preprocess → `select_action` → postprocess. Without this the policy
    runs unnormalized and scores ~0 (the "Unexpected key(s) normalize_inputs.*"
    warning is benign once the processors are in place).
  - Thread-safety: the env/policy are single-instance and not thread-safe;
    skill calls are serialized with a lock (ThreadingHTTPServer is concurrent).
- `record_episode` → captures frames to a `.npz` (full LeRobotDataset export is a
  follow-up).

> **Verified locally** on macOS / Python 3.14, gym-pusht 0.1.6 — `read_joints`,
> `read_camera`, `move_to`, `record_episode` work end-to-end. **Pin `pymunk<7`**
> (in `requirements.txt`): gym-pusht 0.1.6 uses the pymunk 6.x collision-handler
> API and pymunk 7 breaks the env with `'Space' object has no attribute
> 'add_collision_handler'`. `run_policy`'s rollout loop is the remaining TODO.

## Going to real hardware
Copy `gym_sidecar.py`, replace the `Sim` env calls with LeRobot robot/policy
calls (the `# REAL:` markers in `sim_sidecar.py` show the shape), and enforce
**firmware joint/force limits + a hardware e-stop** independently — the Lex grant
is the logical boundary, not physical safety (see DESIGN.md §8).
