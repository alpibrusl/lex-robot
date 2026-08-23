#!/usr/bin/env python3
"""Measure the head camera's horizontal FOV using the robot's own tower.

Run with the sidecar STOPPED (it owns the bus and the cameras):
    pkill -TERM -f "python.*xlerobot_sidecar\\.py"
    .venv/bin/python scripts/measure_camera_fov.py

The head camera rides the tower's pan servo, so the robot can rotate its own
eye by a precisely known angle. For a pure rotation of theta about the
vertical axis, a scene feature shifts by

    dx = f * tan(theta)      (f = focal length in pixels)

Sweep several angles, fit dx against tan(theta) through the origin, and the
slope IS f. Then

    FOV = 2 * atan(width / (2f))

No tape measure, no reference object, and the angle comes from an encoder
rather than a human estimate.

Only the tower pan servo (id 7) moves, by at most ~10 degrees, and it is
returned to its start position with torque released in a finally block.
"""
import math
import os
import pathlib
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "sidecar"))
import tower  # noqa: E402

# This unit's left bus (tower servos share it). Override with LEX_XLE_LEFT_PORT.
LEFT = os.environ.get("LEX_XLE_LEFT_PORT",
                      "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00")
HEAD_INDEX = int(os.environ.get("LEX_XLE_CAMERA_HEAD_INDEX", "4"))
OFFSETS = [-150, -120, -90, -60, -30, 30, 60, 90, 120, 150]   # ticks; 4096 ticks = 360 deg


def open_head():
    c = cv2.VideoCapture(HEAD_INDEX, cv2.CAP_V4L2)
    c.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    c.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    c.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    for _ in range(8):
        c.read()
    return c


def grab(cap):
    for _ in range(4):          # drain: a stale frame would read as zero shift
        cap.read()
    ok, f = cap.read()
    if not ok:
        raise SystemExit("head camera gave no frame")
    return cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.float32)


def shift_px(ref, img):
    """Horizontal shift and correlation confidence, via phase correlation."""
    win = cv2.createHanningWindow((ref.shape[1], ref.shape[0]), cv2.CV_32F)
    (dx, _dy), resp = cv2.phaseCorrelate(ref * win, img * win)
    return dx, resp


def main():
    cap = open_head()
    drv = tower.TowerDriver(port=LEFT)
    start = drv.read()["pan_ticks"]
    print(f"  tower pan start: {start} ticks   pan limits {drv.pan_limits}")
    rows = []
    try:
        drv.hold()                       # goal synced to present before torque
        drv.move_to(pan_ticks=start)
        time.sleep(0.5)
        ref = grab(cap)
        for off in OFFSETS:
            target = start + off
            if not (drv.pan_limits[0] <= target <= drv.pan_limits[1]):
                print(f"    skip {off:+5d}: outside pan limits")
                continue
            drv.move_to(pan_ticks=target)
            time.sleep(0.9)              # settle before looking
            actual = drv.read()["pan_ticks"]
            dx, resp = shift_px(ref, grab(cap))
            theta = math.radians(tower.ticks_to_deg(actual - start))
            rows.append((actual - start, theta, dx, resp))
            print(f"    {off:+5d} ticks -> actual {actual - start:+5d} "
                  f"({math.degrees(theta):+6.2f} deg)  dx {dx:+8.2f} px  conf {resp:.3f}")
    finally:
        try:
            drv.move_to(pan_ticks=start)
            time.sleep(0.4)
            drv.release()
            print(f"  tower restored to {drv.read()["pan_ticks"]}, torque released")
        finally:
            drv.close()
            cap.release()

    good = [r for r in rows if r[3] > 0.05]
    if len(good) < 3:
        print(f"\n  ONLY {len(good)} usable points (confidence > 0.05) — not enough.")
        print("  The scene is probably too dark/featureless. Turn a light on and re-run.")
        return 1

    # Least squares through the origin: dx = f * tan(theta)
    xs = np.array([math.tan(t) for _, t, _, _ in good])
    ys = np.array([dx for _, _, dx, _ in good])
    f = float((xs * ys).sum() / (xs * xs).sum())
    pred = f * xs
    ss_res = float(((ys - pred) ** 2).sum())
    ss_tot = float(((ys - ys.mean()) ** 2).sum())
    r2 = 1 - ss_res / ss_tot if ss_tot else 0.0
    fov = 2 * math.degrees(math.atan(640 / (2 * abs(f))))

    print(f"\n  fit over {len(good)} points:  f = {abs(f):.1f} px   R^2 = {r2:.4f}")
    print(f"  max residual: {float(np.abs(ys - pred).max()):.1f} px")
    print(f"\n  HORIZONTAL FOV = {fov:.1f} degrees  (frame width 640)")
    print(f"  vertical FOV   = {2 * math.degrees(math.atan(480 / (2 * abs(f)))):.1f} degrees")
    if r2 < 0.95:
        print("\n  WARNING: R^2 below 0.95 — treat this as indicative, not final.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
