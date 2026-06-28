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

## Next tiers

- **#67** Tier 3: a contact-rich task on a real URDF (Unitree G1) digital twin.
- **#68** hardware-gated sim-to-real + certification (the only piece needing a robot).
