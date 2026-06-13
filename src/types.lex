# lex-robot/types.lex — core robot value types.
#
# NOTE on effects: Lex effect kinds (net, io, fs_*, …) are defined by the
# compiler, so a package cannot declare `actuate` / `sense` as first-class
# effects today. Until that lands in lex-lang, physical capability is bounded
# at *runtime* via the Grant (see grant.lex) and the lex-os supervisor. Skills
# carry the real `[net]` effect (they talk to the LeRobot sidecar). See
# DESIGN.md §4 for the effect-promotion plan.

type Vec3 = { x :: Float, y :: Float, z :: Float }

type Pose = { pos :: Vec3, rx :: Float, ry :: Float, rz :: Float }

type JointState = { names :: List[Str], positions :: List[Float], velocities :: List[Float] }

type Frame = { width :: Int, height :: Int, jpeg_b64 :: Str }

# Result of any actuating skill.
type Outcome = Reached | Stalled(Str) | Denied(Str) | Timeout

# The capability envelope checked before every command leaves the box.
# A runtime mirror of the relevant slice of the lex-os grant manifest.
type Grant = {
  skills :: List[Str],
  ws_min :: Vec3,
  ws_max :: Vec3,
  max_velocity :: Float,
  max_force :: Float,
  max_grip_force :: Float,
}

# Robot handle: where the sidecar lives + the active grant.
type Robot = { sidecar_url :: Str, grant :: Grant }
