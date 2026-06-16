# lex-robot/types.lex — core robot value types.
#
# NOTE on effects: `actuate` / `sense` are first-class Lex effects today (see
# DESIGN.md §4), so the judgment/authority split is type-enforced — a
# `[sense]`-only routine cannot compile a call to an `[actuate]` skill. Physical
# capability is *also* bounded at runtime: the Grant (grant.lex) gates each
# command, the budget supervisor (budget.lex) caps action count + wall-clock,
# and the lex-os supervisor wraps the whole box. Skills carry the real `[net]`
# effect (they talk to the LeRobot sidecar).

type Vec3 = { x :: Float, y :: Float, z :: Float }

type Pose = { pos :: Vec3, rx :: Float, ry :: Float, rz :: Float }

type JointState = { names :: List[Str], positions :: List[Float], velocities :: List[Float] }

type Frame = { width :: Int, height :: Int, jpeg_b64 :: Str }

# Result of any actuating skill.
#   Denied(reason) — the *grant* refused a capability (skill/workspace/force).
#   Killed(reason) — the *supervisor* stopped the run on a budget breach
#                    (action count or wall-clock). Distinct from Denied: the
#                    command was admissible, but the run ran out of budget.
type Outcome = Reached | Stalled(Str) | Denied(Str) | Killed(Str) | Timeout

# The capability envelope checked before every command leaves the box.
# A runtime mirror of the relevant slice of the lex-os grant manifest.
#
# budget_actions / budget_wall_ms mirror the manifest's `budget.max_commands`
# and `budget.wall_clock_secs` (manifests/pick_place.capsule.json). lex-os
# enforces them around the whole box; budget.lex enforces them *inside* the
# task loop so a plain `lex run` self-limits too (no KVM required).
type Grant = {
  skills :: List[Str],
  ws_min :: Vec3,
  ws_max :: Vec3,
  max_velocity :: Float,
  max_force :: Float,
  max_grip_force :: Float,
  budget_actions :: Int,
  budget_wall_ms :: Int,
}

# Robot handle: where the sidecar lives + the active grant.
type Robot = { sidecar_url :: Str, grant :: Grant }
