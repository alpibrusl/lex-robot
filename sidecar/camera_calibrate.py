#!/usr/bin/env python3
"""Produce a real `CameraModel` from a printed chessboard — and prove it.

`sidecar/camera_calib_example.json` is an EXAMPLE: an idealised overhead camera
0.6 m above the arm origin. Running the vision self-reset against it yields
confidently wrong world positions, because `project_to_plane` refuses
geometric impossibilities (a ray parallel to the plane, a plane behind the
camera) but has no way to refuse merely WRONG numbers. That is #150's risk 3,
and it is silent: every episode is poisoned and nothing says so.

This tool replaces guessing with measuring, in three steps:

    # 1. intrinsics — wave the board around, headless, no display needed
    python sidecar/camera_calibrate.py intrinsics --camera 0 --views 15 \\
        --board 9x6 --square-mm 25 --out /tmp/intrinsics.json

    # 2. extrinsics — board flat on the table at a MEASURED spot, one frame
    python sidecar/camera_calibrate.py extrinsics --camera 0 \\
        --intrinsics /tmp/intrinsics.json --board 9x6 --square-mm 25 \\
        --board-origin 0.30 -0.10 0.0 --board-yaw-deg 0 \\
        --tower-port /dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00 \\
        --out sidecar/camera_calib.json

    # 3. verify — does it actually predict where things are?
    python sidecar/camera_calibrate.py verify --model sidecar/camera_calib.json \\
        --point 0.30 -0.10 0.0 --point 0.40 0.05 0.0

## What each step can and cannot tell you

`intrinsics` reports an RMS reprojection error in pixels. Under ~0.5 px is
good, over ~1.0 px means re-shoot. That number validates the LENS model only.

`extrinsics` reports its own reprojection error over the board corners. That
validates the solve, and it does **not** validate `--board-origin`: if you
mistype where the board is relative to the arm, the solve is internally
perfect and the answer is wrong by exactly your typo. That is why `verify`
exists, and why the origin measurement is the one number worth measuring
twice.

## The tower

The head camera rides the pan/tilt tower (servos 7, 8), and the tower ships
with `Torque_Enable=0`. A limp mount can sag or be knocked, and a
`CameraModel` calibrated at one tower pose is meaningless at another — with
nothing to signal the difference. So `extrinsics` reads the tower's ticks and
records them in a `tower` block alongside the calibration, which
`bus_preflight.py --tower-calib` then checks before any unattended run.

It also REFUSES to calibrate while the tower is limp, unless you pass
`--allow-limp-tower`. Call `python sidecar/tower.py --port ... --hold` first.
Calibrating against a mount that can drift is the kind of work you only find
out was wasted much later.

Reading the tower is read-only: two register reads, no writes, no torque.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

MODEL = "sts3215"
TOWER_PAN_ID, TOWER_TILT_ID = 7, 8

#: Corner refinement window, in pixels. cv2's usual default.
_SUBPIX_WIN = (11, 11)


# ── pure geometry (no camera, no hardware — all of this is unit-tested) ───────

def intrinsics_to_normalized(K, width: int, height: int) -> dict:
    """OpenCV pixel intrinsics -> the normalized form `CameraModel` wants.

    `camera.lex` documents fx/fy as "in image-width/-height units" and the
    principal point in 0..1, with detection coordinates normalized the same
    way. So a pixel focal length divides by the corresponding image dimension.
    """
    return {"fx": float(K[0][0]) / width, "fy": float(K[1][1]) / height,
            "cx0": float(K[0][2]) / width, "cy0": float(K[1][2]) / height}


def pose_to_camera_axes(R, tvec):
    """solvePnP's board->camera rotation/translation -> camera pose in BOARD frame.

    `R` maps board coordinates into camera coordinates (`X_cam = R X_board + t`),
    so the camera's own axes, expressed in board coordinates, are the ROWS of
    `R`, and the camera centre is `-R^T t`. OpenCV's camera frame is x-right,
    y-down, z-forward, which is exactly `CameraModel`'s right/down/forward.
    """
    right = [float(R[0][i]) for i in range(3)]
    down = [float(R[1][i]) for i in range(3)]
    forward = [float(R[2][i]) for i in range(3)]
    t = [float(tvec[i]) for i in range(3)]
    pos = [-(R[0][i] * t[0] + R[1][i] * t[1] + R[2][i] * t[2]) for i in range(3)]
    return [float(v) for v in pos], right, down, forward


def _rot_z(yaw_rad: float):
    c, s = math.cos(yaw_rad), math.sin(yaw_rad)
    return [[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]]


def _apply(M, v):
    return [sum(M[r][c] * v[c] for c in range(3)) for r in range(3)]


def board_frame_to_arm(pos, right, down, forward, origin, yaw_deg: float):
    """Re-express a camera pose from the board's frame into the arm's frame.

    The board lies flat on the table with its first inner corner at `origin`
    (arm frame, metres) and its own +x rotated `yaw_deg` about the arm's +z.
    Directions rotate; only the position also translates.
    """
    Rz = _rot_z(math.radians(yaw_deg))
    moved = _apply(Rz, pos)
    return ([moved[i] + origin[i] for i in range(3)],
            _apply(Rz, right), _apply(Rz, down), _apply(Rz, forward))


def project_world_to_pixel(model: dict, point):
    """Where does an arm-frame point land in the image? Normalized (u, v).

    The inverse of `camera.lex`'s `project_to_plane`, which this repo does not
    otherwise have. Used by `verify` to ask the only question that matters:
    does this calibration predict reality?

    Raises ValueError when the point is behind the camera, rather than
    returning a plausible-looking pixel for something that is not visible.
    """
    pos, right = model["pos"], model["right"]
    down, forward = model["down"], model["forward"]
    d = [point[i] - pos[i] for i in range(3)]
    depth = sum(d[i] * forward[i] for i in range(3))
    if depth <= 0.0:
        raise ValueError("point is behind the camera")
    ru = sum(d[i] * right[i] for i in range(3)) / depth
    dv = sum(d[i] * down[i] for i in range(3)) / depth
    return (model["cx0"] + model["fx"] * ru, model["cy0"] + model["fy"] * dv)


def board_object_points(cols: int, rows: int, square_m: float):
    """Inner-corner positions in the board's own frame, z = 0, row-major.

    Matches the order `cv2.findChessboardCorners` returns.
    """
    return [[c * square_m, r * square_m, 0.0]
            for r in range(rows) for c in range(cols)]


def parse_board(spec: str):
    """"9x6" -> (9, 6): INNER corners, not squares. A 10x7-square board has
    9x6 inner corners, which is the number OpenCV wants and the usual mistake."""
    try:
        cols, rows = (int(v) for v in spec.lower().split("x"))
    except Exception:
        raise ValueError(f"--board must look like 9x6, got {spec!r}")
    if cols < 3 or rows < 3 or cols == rows:
        raise ValueError("--board needs at least 3x3 inner corners and must NOT "
                         "be square — a symmetric board has an ambiguous "
                         "orientation and will silently flip")
    return cols, rows


# ── hardware edges (thin, so the geometry above stays testable) ───────────────

def read_tower(port: str):
    """Read the tower's pan/tilt ticks and torque state. READ-ONLY."""
    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    ids = [TOWER_PAN_ID, TOWER_TILT_ID]
    bus = FeetechMotorsBus(
        port=port, motors={f"m{i}": Motor(i, MODEL, MotorNormMode.DEGREES)
                           for i in ids})
    bus.connect(handshake=False)
    try:
        out = {}
        for motor_id, axis in ((TOWER_PAN_ID, "pan"), (TOWER_TILT_ID, "tilt")):
            out[f"{axis}_ticks"] = int(
                bus.read("Present_Position", f"m{motor_id}", normalize=False))
            out[f"{axis}_torque"] = int(
                bus.read("Torque_Enable", f"m{motor_id}", normalize=False))
        return out
    finally:
        bus.disconnect()


def _open_camera(index: int, width: int, height: int):
    import cv2
    cap = cv2.VideoCapture(index, cv2.CAP_V4L2)
    if not cap.isOpened():
        raise RuntimeError(f"could not open camera {index}")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    return cap


def _find_corners(gray, cols: int, rows: int):
    import cv2
    flags = (cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE |
             cv2.CALIB_CB_FAST_CHECK)
    ok, corners = cv2.findChessboardCorners(gray, (cols, rows), flags)
    if not ok:
        return None
    term = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)
    return cv2.cornerSubPix(gray, corners, _SUBPIX_WIN, (-1, -1), term)


# ── subcommands ──────────────────────────────────────────────────────────────

def cmd_intrinsics(a) -> int:
    import cv2
    import numpy as np

    cols, rows = parse_board(a.board)
    square_m = a.square_mm / 1000.0
    cap = _open_camera(a.camera, a.width, a.height)
    objp = np.array(board_object_points(cols, rows, square_m), dtype=np.float32)

    obj_points, img_points, size = [], [], None
    print(f"Collecting {a.views} views of a {cols}x{rows} board. Move it around "
          f"— vary angle, distance and position, and fill the corners of the "
          f"frame. Ctrl-C to stop early.")
    deadline = time.monotonic() + a.timeout_s
    try:
        while len(obj_points) < a.views and time.monotonic() < deadline:
            ok, frame = cap.read()
            if not ok:
                continue
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            size = gray.shape[::-1]
            corners = _find_corners(gray, cols, rows)
            if corners is None:
                continue
            obj_points.append(objp)
            img_points.append(corners)
            print(f"  captured {len(obj_points)}/{a.views}")
            time.sleep(a.settle_s)     # so consecutive views are not duplicates
    except KeyboardInterrupt:
        print("\n  stopped early")
    finally:
        cap.release()

    if len(obj_points) < 5:
        print(f"Only {len(obj_points)} views — need at least 5, ideally "
              f"{a.views}. Is the board fully visible and well lit?",
              file=sys.stderr)
        return 1

    rms, K, dist, _, _ = cv2.calibrateCamera(obj_points, img_points, size,
                                             None, None)
    print(f"\nRMS reprojection error: {rms:.3f} px over {len(obj_points)} views")
    if rms > 1.0:
        print("  WARNING: over 1.0 px. Re-shoot with more varied poses and "
              "better light before trusting this.", file=sys.stderr)
    payload = {"rms_px": float(rms), "width": size[0], "height": size[1],
               "K": [[float(v) for v in row] for row in K],
               "dist": [float(v) for v in dist.ravel()],
               "views": len(obj_points), "board": f"{cols}x{rows}",
               "square_mm": a.square_mm}
    Path(a.out).write_text(json.dumps(payload, indent=2))
    print(f"wrote {a.out}")
    return 0


def cmd_extrinsics(a) -> int:
    import cv2
    import numpy as np

    cols, rows = parse_board(a.board)
    square_m = a.square_mm / 1000.0
    intr = json.loads(Path(a.intrinsics).read_text())
    K = np.array(intr["K"], dtype=np.float64)
    dist = np.array(intr["dist"], dtype=np.float64)

    tower = None
    if a.tower_port:
        tower = read_tower(a.tower_port)
        limp = [ax for ax in ("pan", "tilt") if not tower[f"{ax}_torque"]]
        print(f"tower: pan {tower['pan_ticks']} ticks, "
              f"tilt {tower['tilt_ticks']} ticks")
        if limp and not a.allow_limp_tower:
            print(f"\nREFUSING: tower {'/'.join(limp)} torque is OFF. The head "
                  f"camera rides this mount; calibrating against a mount that "
                  f"can sag or be knocked produces a CameraModel that silently "
                  f"stops being true.\n  Fix: python sidecar/tower.py --port "
                  f"{a.tower_port} --hold\n  Override: --allow-limp-tower",
                  file=sys.stderr)
            return 1
        if limp:
            print("  WARNING: calibrating against a LIMP tower (--allow-limp-"
                  "tower). This calibration can be invalidated by a knock.",
                  file=sys.stderr)
    else:
        print("WARNING: no --tower-port, so the tower pose is NOT recorded and "
              "bus_preflight.py cannot check it later.", file=sys.stderr)

    cap = _open_camera(a.camera, a.width, a.height)
    objp = np.array(board_object_points(cols, rows, square_m), dtype=np.float32)
    corners, size = None, None
    deadline = time.monotonic() + a.timeout_s
    try:
        while corners is None and time.monotonic() < deadline:
            ok, frame = cap.read()
            if not ok:
                continue
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            size = gray.shape[::-1]
            corners = _find_corners(gray, cols, rows)
    finally:
        cap.release()

    if corners is None:
        print("Never saw the board. It must lie flat, fully visible, at the "
              "measured spot.", file=sys.stderr)
        return 1

    ok, rvec, tvec = cv2.solvePnP(objp, corners, K, dist,
                                  flags=cv2.SOLVEPNP_ITERATIVE)
    if not ok:
        print("solvePnP failed to converge.", file=sys.stderr)
        return 1

    reproj, _ = cv2.projectPoints(objp, rvec, tvec, K, dist)
    err = float(np.sqrt(np.mean(np.sum(
        (reproj.reshape(-1, 2) - corners.reshape(-1, 2)) ** 2, axis=1))))
    print(f"extrinsic reprojection error: {err:.3f} px over "
          f"{cols * rows} corners")
    if err > 1.5:
        print("  WARNING: over 1.5 px — the board may be bent, or the "
              "intrinsics may not match this camera.", file=sys.stderr)

    R, _ = cv2.Rodrigues(rvec)
    pos, right, down, forward = pose_to_camera_axes(R.tolist(),
                                                    tvec.ravel().tolist())
    pos, right, down, forward = board_frame_to_arm(
        pos, right, down, forward, a.board_origin, a.board_yaw_deg)

    model = {
        "_comment": [
            "Measured CameraModel — produced by sidecar/camera_calibrate.py.",
            f"intrinsics RMS {intr['rms_px']:.3f} px over {intr['views']} views;",
            f"extrinsic reprojection {err:.3f} px.",
            "'tower' records the pan/tilt pose this was calibrated at: the head",
            "camera rides that mount and it ships limp, so bus_preflight.py",
            "--tower-calib checks it before an unattended run.",
        ],
        "pos": pos, "right": right, "down": down, "forward": forward,
        **intrinsics_to_normalized(intr["K"], intr["width"], intr["height"]),
        "calibration": {
            "intrinsics_rms_px": intr["rms_px"],
            "extrinsic_reprojection_px": err,
            "board": f"{cols}x{rows}", "square_mm": a.square_mm,
            "board_origin_m": list(a.board_origin),
            "board_yaw_deg": a.board_yaw_deg,
            "image_size": [intr["width"], intr["height"]],
        },
    }
    if tower:
        model["tower"] = {"pan_id": TOWER_PAN_ID, "tilt_id": TOWER_TILT_ID,
                          "pan_ticks": tower["pan_ticks"],
                          "tilt_ticks": tower["tilt_ticks"]}
    Path(a.out).write_text(json.dumps(model, indent=2))
    print(f"wrote {a.out}")
    print(f"  camera at ({pos[0]:.3f}, {pos[1]:.3f}, {pos[2]:.3f}) m in the arm frame")
    print("\nNow VERIFY it — the reprojection error above does NOT check "
          "--board-origin:\n  python sidecar/camera_calibrate.py verify "
          f"--model {a.out} --point X Y Z")
    return 0


def cmd_verify(a) -> int:
    model = json.loads(Path(a.model).read_text())
    if not a.point:
        print("verify needs at least one --point X Y Z (a spot you can measure "
              "in the arm frame and see in the image)", file=sys.stderr)
        return 2
    print(f"{'arm-frame point':>28}  ->  normalized (u, v)")
    for p in a.point:
        try:
            u, v = project_world_to_pixel(model, p)
        except ValueError as exc:
            print(f"  ({p[0]:.3f}, {p[1]:.3f}, {p[2]:.3f})  ->  REFUSED: {exc}")
            continue
        inside = 0.0 <= u <= 1.0 and 0.0 <= v <= 1.0
        note = "" if inside else "   <-- OUTSIDE the image; calibration suspect"
        print(f"  ({p[0]:>7.3f}, {p[1]:>7.3f}, {p[2]:>7.3f})  ->  "
              f"({u:.4f}, {v:.4f}){note}")
    print("\nOpen the camera view and check each (u, v) lands on the real spot. "
          "u=0.5, v=0.5 is frame centre. If they are off, --board-origin is "
          "the first thing to re-measure.")
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def board_args(p):
        p.add_argument("--board", default="9x6",
                       help="INNER corners, e.g. 9x6 for a 10x7-square board")
        p.add_argument("--square-mm", type=float, default=25.0)
        p.add_argument("--camera", type=int, default=0)
        p.add_argument("--width", type=int, default=640)
        p.add_argument("--height", type=int, default=480)
        p.add_argument("--timeout-s", type=float, default=120.0)

    p = sub.add_parser("intrinsics", help="solve the lens model from N views")
    board_args(p)
    p.add_argument("--views", type=int, default=15)
    p.add_argument("--settle-s", type=float, default=1.0)
    p.add_argument("--out", default="/tmp/intrinsics.json")
    p.set_defaults(fn=cmd_intrinsics)

    p = sub.add_parser("extrinsics", help="solve where the camera is, and write "
                                          "the CameraModel")
    board_args(p)
    p.add_argument("--intrinsics", required=True)
    p.add_argument("--board-origin", nargs=3, type=float, required=True,
                   metavar=("X", "Y", "Z"),
                   help="arm-frame position (metres) of the board's FIRST inner "
                        "corner — measure this twice")
    p.add_argument("--board-yaw-deg", type=float, default=0.0,
                   help="rotation of the board's +x about the arm's +z")
    p.add_argument("--tower-port", default=None,
                   help="left-arm bus, to record the tower pose (read-only)")
    p.add_argument("--allow-limp-tower", action="store_true")
    p.add_argument("--out", default="sidecar/camera_calib.json")
    p.set_defaults(fn=cmd_extrinsics)

    p = sub.add_parser("verify", help="does this calibration predict reality?")
    p.add_argument("--model", required=True)
    p.add_argument("--point", nargs=3, type=float, action="append",
                   metavar=("X", "Y", "Z"))
    p.set_defaults(fn=cmd_verify)
    return ap


def main(argv=None) -> int:
    a = build_parser().parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
