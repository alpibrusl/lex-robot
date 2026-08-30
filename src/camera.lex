# src/camera.lex — Tier-2 vision geometry: a normalized 2D detection box
# (sense.detect_object's output) becomes a WORLD position by intersecting
# the pixel's camera ray with a calibrated horizontal plane — the table the
# object stands on. Pure pinhole math, examples-tested, no dependencies.
#
# The CameraModel is calibration data: where the camera sits (`pos`) and its
# orientation as three world-frame basis vectors (`right`/`down`/`forward` —
# calibration supplies the vectors, so there is no trig in here), plus
# normalized focal lengths (`fx`/`fy`, in image-width/-height units), the
# principal point (`cx0`/`cy0`, normally 0.5/0.5), and the Brown-Conrady lens
# distortion (`k1`/`k2`/`k3` radial, `p1`/`p2` tangential — all zero for an
# ideal lens). Detection coordinates are the vision service's:
# (cx, cy) ∈ [0,1]², origin top-left.
#
# The distortion terms are not decoration. Measured on this project's own head
# camera they displace a pixel by a median 3.0 px and up to 8.4 px across the
# frame, which at 400 mm of reach is ~9 mm of world error — larger than the
# ~2.3 mm uncertainty of the focal length itself, and larger than the hand-eye
# residual. Ignoring them was the biggest single error in this pipeline.
# They vanish at the principal point and grow toward the edges, which is
# exactly where `project_to_plane` looks when the object is off-centre.
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
type CameraModel = { pos :: t.Vec3, right :: t.Vec3, down :: t.Vec3, forward :: t.Vec3, fx :: Float, fy :: Float, cx0 :: Float, cy0 :: Float, k1 :: Float, k2 :: Float, k3 :: Float, p1 :: Float, p2 :: Float }

# A point on the normalized image plane, before or after undistortion.
type Pt2 = { x :: Float, y :: Float }

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

# ── undistortion ─────────────────────────────────────────────────────────────
# The Brown-Conrady model maps an ideal point to the distorted one the lens
# actually produces. Projection needs the INVERSE, and that has no closed form,
# so this is the standard fixed-point iteration: assume the ideal point is the
# distorted one, compute what distortion that would produce, correct, repeat.
# It converges fast for sane coefficients — matched against OpenCV's
# `undistortPoints` on this camera's own measured values to better than 1e-8,
# well under a micrometre of world error, with the eight steps used here.
#
# Not a loop with a tolerance on purpose: a fixed step count is deterministic,
# which is what the examples below can assert.
fn undistort_iter(cam :: CameraModel, xd :: Float, yd :: Float, p :: Pt2, n :: Int) -> Pt2 {
  if n <= 0 {
    p
  } else {
    let r2 := p.x * p.x + p.y * p.y
    let radial := 1.0 + cam.k1 * r2 + cam.k2 * r2 * r2 + cam.k3 * r2 * r2 * r2
    let dx := 2.0 * cam.p1 * p.x * p.y + cam.p2 * (r2 + 2.0 * p.x * p.x)
    let dy := cam.p1 * (r2 + 2.0 * p.y * p.y) + 2.0 * cam.p2 * p.x * p.y
    undistort_iter(cam, xd, yd, { x: (xd - dx) / radial, y: (yd - dy) / radial }, n - 1)
  }
}

# Undistorted normalized image coordinates. Short-circuits to the identity for
# an ideal lens, so a calibration with no distortion terms costs nothing and
# behaves exactly as this module did before they existed.
fn undistort(cam :: CameraModel, xd :: Float, yd :: Float) -> Pt2 {
  if cam.k1 == 0.0 and cam.k2 == 0.0 and cam.k3 == 0.0 and cam.p1 == 0.0 and cam.p2 == 0.0 {
    { x: xd, y: yd }
  } else {
    undistort_iter(cam, xd, yd, { x: xd, y: yd }, 8)
  }
}

# ── the projection ───────────────────────────────────────────────────────────
# The world-frame ray direction through normalized pixel (u, v).
# Exercised through the project_to_plane_mm examples below.
fn ray_direction(cam :: CameraModel, u :: Float, v :: Float) -> t.Vec3 {
  let p := undistort(cam, (u - cam.cx0) / cam.fx, (v - cam.cy0) / cam.fy)
  add3(cam.forward, add3(scale3(cam.right, p.x), scale3(cam.down, p.y)))
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
    project_to_plane_mm({ pos: { x: 0.0, y: 0.0, z: 0.5 }, right: { x: 0.0, y: -1.0, z: 0.0 }, down: { x: 0.0, y: 0.0, z: -1.0 }, forward: { x: 1.0, y: 0.0, z: 0.0 }, fx: 1.0, fy: 1.0, cx0: 0.5, cy0: 0.5, k1: 0.0, k2: 0.0, k3: 0.0, p1: 0.0, p2: 0.0 }, 0.5, 0.5, 0.0) => Err("pixel ray is parallel to the calibrated plane"),
    project_to_plane_mm(measured_head_camera({ x: 0.25, y: 0.0, z: 0.6 }), 0.534, 0.52051, 0.0) => Ok({ x_mm: 250, y_mm: 0, z_mm: 0 }),
    project_to_plane_mm(measured_head_camera({ x: 0.25, y: 0.0, z: 0.6 }), 0.9, 0.9, 0.0) => Ok({ x_mm: 649, y_mm: 311, z_mm: 0 }),
    project_to_plane_mm(measured_head_camera({ x: 0.25, y: 0.0, z: 0.6 }), 0.1, 0.85, 0.0) => Ok({ x_mm: -222, y_mm: 270, z_mm: 0 })
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
  { pos: pos, right: { x: 1.0, y: 0.0, z: 0.0 }, down: { x: 0.0, y: 1.0, z: 0.0 }, forward: { x: 0.0, y: 0.0, z: -1.0 }, fx: 1.0, fy: 1.0, cx0: 0.5, cy0: 0.5, k1: 0.0, k2: 0.0, k3: 0.0, p1: 0.0, p2: 0.0 }
}

# This project's own head camera, as measured 2026-08-30 over 117 views at
# 640x480 (calibration/head_intrinsics_mac_640x480.pooled.json). Here so the
# examples above can pin the distortion path against real numbers rather than
# invented ones -- the numbers a running system uses come from that JSON, not
# from this function, and a different unit will have different ones.
#
# What the examples pin, and why it is worth pinning: at the principal point
# the distortion vanishes and this agrees with the pinhole model exactly, while
# at (0.9, 0.9) the two differ by 5.7 mm and at (0.1, 0.85) by 6.7 mm. That
# spread IS the error the pinhole model used to make.
fn measured_head_camera(pos :: t.Vec3) -> CameraModel {
  { pos: pos, right: { x: 1.0, y: 0.0, z: 0.0 }, down: { x: 0.0, y: 1.0, z: 0.0 }, forward: { x: 0.0, y: 0.0, z: -1.0 },
    fx: 0.54517, fy: 0.72347, cx0: 0.534, cy0: 0.52051,
    k1: 0.0919, k2: -0.1347, k3: 0.0435, p1: 0.00024, p2: -0.00114 }
}
