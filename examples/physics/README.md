# Tier 2 — the grant, validated in physics (epic #63, issue #66)

Tiers 0/1 prove the robot grant *symbolically*: `src/grant.lex` clamps a grasp
force and blocks an out-of-workspace move, and the `robot_task` verifier replays
the trail to a clean verdict. That shows the **authority layer** is correct. It
does not yet show the authority is **physically meaningful** — that a clamp means
less force actually reaches the world, and a keep-out bound means the end-effector
actually stays out.

This tier closes that gap in real rigid-body physics (MuJoCo). It runs the *same*
policy intent twice and measures the difference:

| property                  | ungoverned | governed |
|---------------------------|-----------:|---------:|
| keep-out penetration (m)  |       0.50 |     0.00 |
| contact force (N)         |        250 |       20 |

**Lex governs, MuJoCo simulates.** The Python harness never decides what is
allowed. It hands the raw command to [`../govern_commands.lex`](../govern_commands.lex),
which applies the grant (same semantics as `src/grant.lex`: `clamp_grip` +
`in_workspace`) and returns the governed command *plus* a `robot_task` trail.
Python only executes whichever command it is given and reads the resulting
physics; the trail then replays through the same verifier used everywhere else in
the kernel.

## Run

```sh
examples/grant_physics_run.sh        # creates a venv (mujoco+numpy), runs, verifies
```

Out-of-band — like `gym_env/`, this needs `mujoco` + `numpy` and is **not** a CI
dependency. `govern_commands.lex` itself is plain Lex and is type-checked in CI.

## Files

- `mujoco_validate.py` — two minimal scenes (position-servo keep-out; force-into-wall
  grasp), ungoverned vs governed, with pass/fail safety assertions.
- `../govern_commands.lex` — the grant gate that decides what reaches the sim and
  emits the episode trail.
- `../grant_physics_run.sh` — venv setup → physics → trail verification.

## Tier 3 — the same loop on the real Unitree G1 (#67)

`g1_validate.py` runs the identical governed loop against the **real Unitree G1
humanoid** (MuJoCo Menagerie URDF), reusing the production G1 sidecar
(`../../sidecar/depot_g1_sidecar.py`) for the physics. The G1's right arm reaches
a truck charge port and seats a connector — a contact-rich insertion ending in a
rigid weld — under the Lex grant. The same policy intent (seat at 99 N) is run
twice:

| episode            | force (N) | outcome | seated |
|--------------------|----------:|---------|:------:|
| ungoverned (99 N)  |        99 | stalled |   no   |
| governed (clamped) |        20 | reached |  yes   |

99 N reaches the actuator and trips the arm's firmware force floor (an unsafe
slam on hardware); the grant clamps it to the grip ceiling *before* it is sent,
so the connector seats cleanly and the governed episode's `robot_task` trail
replays to a clean verdict. Governance survives contact with a real robot model.

```sh
examples/g1_physics_run.sh           # venv + sparse-checks-out the G1 model, runs, verifies
```

Needs the G1 model (`LEX_G1_DIR` → a `mujoco_menagerie/unitree_g1` checkout); the
run script fetches it. Still out-of-band — not a CI dependency.

- `g1_validate.py` — the Tier 3 validator (reuses `DepotG1` for real kinematics).
- `../g1_physics_run.sh` — venv + G1 model checkout → physics → trail verification.

## Next tier

- **#68** hardware-gated sim-to-real + certification (the only piece needing a robot).
