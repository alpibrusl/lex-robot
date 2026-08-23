#!/usr/bin/env python3
"""Build — and VALIDATE — a CameraModel JSON for src/camera.lex.

A wrong calibration is the worst kind of wrong: project_to_plane keeps
returning confident world positions and nothing downstream can tell they are
nonsense (lex-robot#150 risk 3). So this tool refuses to emit a file that has
not been checked against a real measured point.

WHAT IS ALREADY KNOWN FOR THIS UNIT
-----------------------------------
Intrinsics are MEASURED and need no further work. scripts/measure_camera_fov.py
rotates the head camera on the tower's own pan servo and fits the image shift,
giving f = 348.4 px at 640x480 (R^2 0.9994 over 10 angles, three repeats
agreeing to 0.4 deg). camera.lex wants NORMALIZED focal lengths, and
ray_direction's algebra makes that fx = f_px / width, fy = f_px / height —
verified by reproducing camera.lex's own documented overhead projection.

Position is SOURCED from sidecar/robot_geometry.json, itself taken from
XLeRobot's URDF: the head tilt joint sits at x=-0.178, z=0.73+0.43815=1.168 in
the robot frame, and the arm bases at (-0.135, -/+0.133, 0.760).

WHAT IS NOT KNOWN, AND WHY THIS TOOL ASKS FOR IT
------------------------------------------------
1. ORIENTATION. The camera rides the tower, so its pointing is whatever the
   pan/tilt servos say — and there is no reference telling us which tick means
   "level" or "straight ahead". Both axes are 1:1 with the servo (measured:
   tilt 89.45 milli-deg/tick vs 87.89 expected, R^2 0.9988), so ticks convert
   to degrees cleanly ONCE a zero is known.

2. HANDEDNESS. camera.lex does not constrain right/down/forward to a
   right-handed set; ray_direction just adds the three scaled vectors. Its
   `overhead_camera` helper satisfies down = right x forward, whereas a
   physically-derived level camera satisfies down = forward x right. Those
   differ by a mirror. Guessing picks a coin flip between correct and
   left-right-flipped, and NOTHING in the pipeline would flag the flip — an
   object on the left would be reached for on the right.

Hence --check: give the tool one pixel whose real world position you know, and
it reports the error. Under --strict (default) it will not write a file whose
predicted position is further than --tol from the truth.

USAGE
    # emit, validated against one known point
    scripts/make_camera_calib.py --arm left --pan-ticks 1547 --tilt-ticks 3394 \\
        --pan-zero 1547 --tilt-zero 2523 \\
        --check-pixel 0.5,0.8 --check-world 0.30,0.00,0.0 \\
        --out sidecar/camera_calib_xle_head.json

    # see what it would produce, no file written
    scripts/make_camera_calib.py --arm left --pan-ticks 1547 --tilt-ticks 3394 \\
        --pan-zero 1547 --tilt-zero 2523 --dry-run
"""
import argparse
import json
import math
import pathlib
import sys

TICKS_PER_REV = 4096
DEG_PER_TICK = 360.0 / TICKS_PER_REV

# Measured: scripts/measure_camera_fov.py, three runs, 640x480.
MEASURED_F_PX = 348.4
DEFAULT_W, DEFAULT_H = 640, 480

# Sourced: sidecar/robot_geometry.json -> XLeRobot URDF.
HEAD_TILT_JOINT_ROBOT = (-0.178, 0.0, 0.73 + 0.43815)
ARM_BASE_ROBOT = {"left": (-0.135, 0.133, 0.760), "right": (-0.135, -0.133, 0.760)}


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def basis(yaw_deg, pitch_down_deg, handedness):
    """Camera axes as world vectors.

    yaw about +z (0 = facing the robot's +x), pitch measured DOWNWARD from
    level. `handedness` picks which cross-product convention builds `down`:
    'physical'  -> down = forward x right   (a real level camera)
    'overhead'  -> down = right x forward   (matches camera.lex's helper)
    They differ by a mirror; see the module docstring.
    """
    y, p = math.radians(yaw_deg), math.radians(pitch_down_deg)
    forward = (math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p))
    right = (math.sin(y), -math.cos(y), 0.0)        # +u toward the robot's right
    down = cross(forward, right) if handedness == "physical" else cross(right, forward)
    return right, down, forward


def project(cam, u, v, plane_z):
    """Mirror of camera.lex's project_to_plane, so --check tests the real maths."""
    d = tuple(cam["forward"][i]
              + cam["right"][i] * (u - cam["cx0"]) / cam["fx"]
              + cam["down"][i] * (v - cam["cy0"]) / cam["fy"] for i in range(3))
    if d[2] == 0:
        raise ValueError("pixel ray is parallel to the plane")
    t = (plane_z - cam["pos"][2]) / d[2]
    if t <= 0:
        raise ValueError("the plane is behind the camera ray")
    return tuple(cam["pos"][i] + d[i] * t for i in range(3))


def build(args):
    w, h = args.width, args.height
    fx, fy = args.focal_px / w, args.focal_px / h
    cam_r = HEAD_TILT_JOINT_ROBOT
    arm_r = ARM_BASE_ROBOT[args.arm]
    pos = [round(cam_r[i] - arm_r[i], 4) for i in range(3)]
    yaw = (args.pan_ticks - args.pan_zero) * DEG_PER_TICK
    pitch = (args.tilt_ticks - args.tilt_zero) * DEG_PER_TICK
    right, down, forward = basis(yaw, pitch, args.handedness)
    rnd = lambda v: [round(x, 6) for x in v]
    return {
        "pos": pos, "right": rnd(right), "down": rnd(down), "forward": rnd(forward),
        "fx": round(fx, 6), "fy": round(fy, 6), "cx0": args.cx0, "cy0": args.cy0,
        "_provenance": {
            "fx_fy": (f"MEASURED. f={args.focal_px}px at {w}x{h} from "
                      "scripts/measure_camera_fov.py (tower rotation + phase "
                      "correlation). Normalized as f_px/width and f_px/height, "
                      "the convention camera.lex's ray_direction implies."),
            "cx0_cy0": ("ASSUMED image centre. Not measured — a real principal "
                        "point needs a checkerboard or a multi-angle fit."),
            "pos": (f"SOURCED from sidecar/robot_geometry.json (XLeRobot URDF): "
                    f"head tilt joint {HEAD_TILT_JOINT_ROBOT} minus the "
                    f"{args.arm} arm base {arm_r}, both in the robot frame."),
            "orientation": (f"DERIVED from tower ticks: pan {args.pan_ticks} "
                            f"(zero {args.pan_zero}) -> yaw {yaw:.2f} deg, tilt "
                            f"{args.tilt_ticks} (zero {args.tilt_zero}) -> pitch "
                            f"{pitch:.2f} deg down. Both axes measured 1:1 with "
                            "the servo. THE ZEROES ARE OPERATOR-SUPPLIED — if "
                            "they are wrong, every world position is wrong."),
            "handedness": (f"'{args.handedness}'. camera.lex does not constrain "
                           "right/down/forward to a right-handed set, and its "
                           "overhead_camera helper uses the opposite convention "
                           "to a physically-derived level camera. The two differ "
                           "by a LEFT-RIGHT MIRROR that nothing downstream "
                           "detects. Settle it with --check, never by argument."),
            "validated": None,
        },
    }


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--arm", choices=["left", "right"], default="left")
    p.add_argument("--pan-ticks", type=int, required=True)
    p.add_argument("--tilt-ticks", type=int, required=True)
    p.add_argument("--pan-zero", type=int, required=True,
                   help="pan ticks at which the camera faces the robot's +x")
    p.add_argument("--tilt-zero", type=int, required=True,
                   help="tilt ticks at which the camera is LEVEL")
    p.add_argument("--focal-px", type=float, default=MEASURED_F_PX)
    p.add_argument("--width", type=int, default=DEFAULT_W)
    p.add_argument("--height", type=int, default=DEFAULT_H)
    p.add_argument("--cx0", type=float, default=0.5)
    p.add_argument("--cy0", type=float, default=0.5)
    p.add_argument("--handedness", choices=["physical", "overhead"], default="physical")
    p.add_argument("--check-pixel", help="u,v in 0..1 of a point whose world position you know")
    p.add_argument("--check-world", help="x,y,z metres of that point in the arm frame")
    p.add_argument("--tol", type=float, default=0.03, help="max allowed error, metres")
    p.add_argument("--strict", action=argparse.BooleanOptionalAction, default=True)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--out")
    a = p.parse_args()

    cam = build(a)
    print(json.dumps({k: v for k, v in cam.items() if k != "_provenance"}, indent=2))

    if a.check_pixel and a.check_world:
        u, v = (float(x) for x in a.check_pixel.split(","))
        truth = tuple(float(x) for x in a.check_world.split(","))
        best = None
        for hand in ("physical", "overhead"):
            a.handedness = hand
            c = build(a)
            try:
                got = project(c, u, v, truth[2])
            except ValueError as e:
                print(f"  {hand:9}: no intersection ({e})")
                continue
            err = math.dist(got, truth)
            print(f"  {hand:9}: predicts ({got[0]:+.3f},{got[1]:+.3f},{got[2]:+.3f})"
                  f"  error {err * 100:.1f} cm")
            if best is None or err < best[1]:
                best = (hand, err, c)
        if best is None:
            print("\n  FAILED: neither convention puts that pixel on the plane.")
            return 1
        hand, err, cam = best
        cam["_provenance"]["validated"] = (
            f"CHECKED against a known point: pixel ({u},{v}) -> {truth}, "
            f"error {err * 100:.1f} cm. Handedness '{hand}' chosen because it fit; "
            f"the other convention was worse.")
        print(f"\n  best: '{hand}', error {err * 100:.1f} cm (tolerance {a.tol * 100:.0f} cm)")
        if err > a.tol and a.strict:
            print("  REFUSING to write: error exceeds tolerance. A calibration this\n"
                  "  far out yields confidently wrong positions. Re-check the zeroes,\n"
                  "  the known point, or the camera height.")
            return 1
    elif a.strict and not a.dry_run:
        print("\n  REFUSING to write an UNVALIDATED calibration.\n"
              "  Give --check-pixel and --check-world (one point whose real position\n"
              "  you know), or pass --no-strict if you accept an unchecked file.")
        return 1

    if a.out and not a.dry_run:
        pathlib.Path(a.out).write_text(json.dumps(cam, indent=2) + "\n")
        print(f"  wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
