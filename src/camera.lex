# src/camera.lex — Tier-2 vision geometry: a normalized 2D detection box
# (sense.detect_object's output) becomes a WORLD position by intersecting
# the pixel's camera ray with a calibrated horizontal plane — the table the
# object stands on. Pure pinhole math, examples-tested, no dependencies.
#
# The CameraModel is calibration data: where the camera sits (`pos`) and its
# orientation as three world-frame basis vectors (`right`/`down`/`forward` —
# calibration supplies the vectors, so there is no trig in here), plus
# normalized focal lengths (`fx`/`fy`, in image-width/-height units) and the
# principal point (`cx0`/`cy0`, normally 0.5/0.5). Detection coordinates are
# the vision service's: (cx, cy) ∈ [0,1]², origin top-left.
#
# The honesty deal of Tier-2: a plane intersection is only a position when
# the object actually stands on the calibrated plane. Cheap, deterministic,
# correct for tabletop objects — full per-pixel depth stays Tier-3 and open.
# Geometry is Float throughout (it is geometry, not money); the *_mm helpers
# exist so assertions and logs can compare integer millimeters instead of
# float text.

import "std.float" as flt

import "./types" as t

# Calibration: camera pose (world), orientation basis (world), intrinsics.
type CameraModel = { pos :: t.Vec3, right :: t.Vec3, down :: t.Vec3, forward :: t.Vec3, fx :: Float, fy :: Float, cx0 :: Float, cy0 :: Float }

# A world position in integer millimeters — the comparable form.
type Mm3 = { x_mm :: Int, y_mm :: Int, z_mm :: Int }

# ── vector helpers ───────────────────────────────────────────────────────────
# Trivial accessor-shape arithmetic; vectors are exercised through the
# project_to_plane_mm examples below.
fn scale3(v :: t.Vec3, k :: Float) -> t.Vec3 {
  { x: v.x * k, y: v.y * k, z: v.z * k }
}

# Trivial accessor-shape arithmetic; exercised through the examples below.
fn add3(a :: t.Vec3, b :: t.Vec3) -> t.Vec3 {
  { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z }
}

# ── the projection ───────────────────────────────────────────────────────────
# The world-frame ray direction through normalized pixel (u, v).
# Exercised through the project_to_plane_mm examples below.
fn ray_direction(cam :: CameraModel, u :: Float, v :: Float) -> t.Vec3 {
  add3(cam.forward, add3(scale3(cam.right, (u - cam.cx0) / cam.fx), scale3(cam.down, (v - cam.cy0) / cam.fy)))
}

# Intersect the (u, v) pixel ray with the horizontal plane z = plane_z.
# Refuses instead of guessing when the ray runs parallel to the plane or the
# intersection lies behind the camera. Exercised via project_to_plane_mm.
fn project_to_plane(cam :: CameraModel, u :: Float, v :: Float, plane_z :: Float) -> Result[t.Vec3, Str] {
  let d := ray_direction(cam, u, v)
  if d.z == 0.0 {
    Err("pixel ray is parallel to the calibrated plane")
  } else {
    let tt := (plane_z - cam.pos.z) / d.z
    if tt > 0.0 {
      Ok(add3(cam.pos, scale3(d, tt)))
    } else {
      Err("the calibrated plane is behind the camera ray")
    }
  }
}

# ── integer-millimeter forms (assertable, log-friendly) ──────────────────────
fn round_mm(x :: Float) -> Int
  examples {
    round_mm(0.322) => 322,
    round_mm(0.0) => 0,
    round_mm(-0.0301) => -30
  }
{
  if x >= 0.0 {
    flt.to_int(x * 1000.0 + 0.5)
  } else {
    0 - flt.to_int(0.5 - x * 1000.0)
  }
}

# Trivial per-field rounding; exercised through project_to_plane_mm.
fn vec_mm(p :: t.Vec3) -> Mm3 {
  { x_mm: round_mm(p.x), y_mm: round_mm(p.y), z_mm: round_mm(p.z) }
}

fn project_to_plane_mm(cam :: CameraModel, u :: Float, v :: Float, plane_z :: Float) -> Result[Mm3, Str]
  examples {
    project_to_plane_mm(overhead_camera({ x: 0.25, y: 0.0, z: 0.6 }), 0.62, 0.55, 0.0) => Ok({ x_mm: 322, y_mm: 30, z_mm: 0 }),
    project_to_plane_mm(overhead_camera({ x: 0.25, y: 0.0, z: 0.6 }), 0.5, 0.5, 0.0) => Ok({ x_mm: 250, y_mm: 0, z_mm: 0 }),
    project_to_plane_mm(overhead_camera({ x: 0.25, y: 0.0, z: 0.6 }), 0.5, 0.5, 1.0) => Err("the calibrated plane is behind the camera ray"),
    project_to_plane_mm({ pos: { x: 0.0, y: 0.0, z: 0.5 }, right: { x: 0.0, y: -1.0, z: 0.0 }, down: { x: 0.0, y: 0.0, z: -1.0 }, forward: { x: 1.0, y: 0.0, z: 0.0 }, fx: 1.0, fy: 1.0, cx0: 0.5, cy0: 0.5 }, 0.5, 0.5, 0.0) => Err("pixel ray is parallel to the calibrated plane")
  }
{
  match project_to_plane(cam, u, v, plane_z) {
    Err(e) => Err(e),
    Ok(p) => Ok(vec_mm(p)),
  }
}

# ── stock calibrations ───────────────────────────────────────────────────────
# A straight-down camera at `pos`: image +u is world +x, image +v is world
# +y, looking along −z. Unit normalized focals, centered principal point —
# the head-camera-over-the-table setup the vision-split demo models.
fn overhead_camera(pos :: t.Vec3) -> CameraModel {
  { pos: pos, right: { x: 1.0, y: 0.0, z: 0.0 }, down: { x: 0.0, y: 1.0, z: 0.0 }, forward: { x: 0.0, y: 0.0, z: -1.0 }, fx: 1.0, fy: 1.0, cx0: 0.5, cy0: 0.5 }
}

