#!/usr/bin/env python3
"""Generate a printable ArUco sheet for hand-eye calibration.

WHY A FIDUCIAL AND NOT THE VISION MODEL

Measured on this unit: asking the VLM to locate the gripper in the SAME image
five times returned positions spanning 38 px in y (stdev 17 px). Camera
calibration needs 1-2 px. The VLM is the right tool for "bookshelf at 0
degrees, floor unclear" and the wrong tool for geometry — it answers
semantically, not metrically.

cv2.aruco finds marker corners to sub-pixel accuracy, and one marker yields
FOUR correspondences per pose plus a full 6-DoF pose estimate, so three or
four poses beat the five VLM poses that failed to solve.

PRINT SCALE IS PART OF THE MEASUREMENT

Marker side length feeds directly into the pose estimate, so a printer that
silently scales to 96% puts a 4% error into every distance. Print at 100% /
"actual size" with no fit-to-page, then MEASURE the printed marker with a
ruler and pass the real number to the solver — do not assume it came out at
the nominal size. The sheet prints its own size legend and a 100 mm ruler so
the check takes seconds.

    scripts/make_aruco_sheet.py --out aruco_sheet.png
"""
import argparse
import pathlib

import cv2
import numpy as np

DPI = 300
MM = DPI / 25.4                      # pixels per millimetre


def mm(x):
    return int(round(x * MM))


def marker(dictionary, ident, side_mm, quiet_mm=6):
    """One marker with its mandatory quiet zone and a printed legend."""
    d = cv2.aruco.getPredefinedDictionary(dictionary)
    img = cv2.aruco.generateImageMarker(d, ident, mm(side_mm))
    pad = mm(quiet_mm)
    # The white border is not decoration: aruco needs it to find the marker.
    tile = np.full((img.shape[0] + 2 * pad, img.shape[1] + 2 * pad), 255, np.uint8)
    tile[pad:pad + img.shape[0], pad:pad + img.shape[1]] = img
    label = np.full((mm(9), tile.shape[1]), 255, np.uint8)
    cv2.putText(label, f"DICT_4X4_50  id={ident}  {side_mm} mm", (mm(1), mm(6)),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, 0, 2)
    return np.vstack([tile, label])


RULER_MM = 100
RULER_NEEDS_MM = RULER_MM + 15          # 5 mm lead-in + end label room


def ruler(width_px):
    """A 100 mm ruler so print scaling can be checked against reality.

    The sheet must be wide enough to hold this WHOLE ruler — a truncated one
    is worse than none, because it still looks measurable.
    """
    h = mm(14)
    r = np.full((h, width_px), 255, np.uint8)
    y = mm(9)
    cv2.line(r, (mm(5), y), (mm(105), y), 0, 3)
    for i in range(0, 101, 10):
        x = mm(5 + i)
        cv2.line(r, (x, y - mm(3 if i % 50 else 5)), (x, y), 0, 3)
        cv2.putText(r, str(i), (x - mm(2), y - mm(6)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45, 0, 1)
    cv2.putText(r, "100 mm - measure this. If it is not 100 mm, the sheet printed scaled.",
                (mm(5), y + mm(4)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, 0, 1)
    return r


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--gripper-mm", type=float, default=40,
                   help="marker for the GRIPPER, seen by the head camera")
    p.add_argument("--landmark-mm", type=float, default=60,
                   help="marker for the WORKSPACE, seen by the wrist camera")
    p.add_argument("--out", default="aruco_sheet.png")
    a = p.parse_args()

    d = cv2.aruco.DICT_4X4_50
    g = marker(d, 0, a.gripper_mm)
    l = marker(d, 1, a.landmark_mm)
    # wide enough for the ruler too, or the scale check gets cut off
    w = max(g.shape[1], l.shape[1], mm(RULER_NEEDS_MM)) + mm(10)

    def center(t):
        row = np.full((t.shape[0], w), 255, np.uint8)
        x = (w - t.shape[1]) // 2
        row[:, x:x + t.shape[1]] = t
        return row

    def text(lines, size=0.5, pad=3):
        block = np.full((mm(pad + 4 * len(lines)), w), 255, np.uint8)
        for i, s in enumerate(lines):
            cv2.putText(block, s, (mm(5), mm(pad + 4 * i)),
                        cv2.FONT_HERSHEY_SIMPLEX, size, 0, 1)
        return block

    sheet = np.vstack([
        text(["lex-robot hand-eye calibration markers", ""], 0.7, 6),
        text(["PRINT AT 100% / ACTUAL SIZE - no 'fit to page', no scaling.",
              "Then measure the ruler and each marker, and use the MEASURED",
              "size in the solver. Print scale is part of the measurement."]),
        center(g),
        text([f"id=0  ->  TAPE TO THE GRIPPER, flat, facing out.",
              "   Seen by the HEAD camera. Keep it flat: a curled marker",
              "   bends its corners and the pose estimate bends with it."]),
        center(l),
        text([f"id=1  ->  LAY IN THE WORKSPACE, flat on the surface.",
              "   Seen by the WRIST camera. Bigger because the wrist camera",
              "   views it from further away and at sharper angles."]),
        ruler(w),
    ])
    pathlib.Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(a.out, sheet)
    print(f"  wrote {a.out}  ({sheet.shape[1]}x{sheet.shape[0]} px at {DPI} dpi "
          f"= {sheet.shape[1] / MM:.0f}x{sheet.shape[0] / MM:.0f} mm)")
    print(f"  id=0 {a.gripper_mm:.0f} mm -> gripper (head camera)")
    print(f"  id=1 {a.landmark_mm:.0f} mm -> workspace (wrist camera)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
