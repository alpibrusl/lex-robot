"""Draw a bearing scale onto a camera frame so a language model can point.

WHY THIS EXISTS

A vision model asked "is the way clear?" answers in prose: "there is a chair
on the left". A robot cannot act on "left" — it needs "turn -20 degrees".
Asking the model to estimate angles from a bare photo does not work; spatial
estimation is exactly what these models are worst at (see Butter-Bench,
arXiv:2510.21860, on LLMs as robot controllers).

The trick, borrowed from RoboCrew (github.com/Grigorij-Dudnik/RoboCrew), is to
stop asking the model to do geometry and let it do what it is good at instead:
read labels. Burn a labelled angle scale into the image, and "the chair is at
about -20" becomes character recognition against a ruler that is right there
in the frame.

    ...  -30    -15     0     15     30  ...
    ─────┴──────┴───────┴──────┴──────┴─────
              <=LEFT          RIGHT=>

ACCURACY WARNING

The labels are only as true as LEX_XLE_CAMERA_FOV. Get the field of view wrong
and every number is confidently wrong — worse than no scale at all, because
the model will trust it and so will the planner. Measure it on the real
camera (see measure_fov_hint) before relying on the numbers to steer.

Pure functions over numpy arrays: no camera, no sidecar, no model. Tested in
test_camera_overlay.py.
"""
import math
import os

# Default horizontal field of view, degrees. A guess for a generic USB webcam
# and the single most likely thing to be wrong here — see the warning above.
DEFAULT_FOV_DEG = float(os.environ.get("LEX_XLE_CAMERA_FOV", "90"))

# Where marks are drawn, in degrees from centre. Every 15 deg matches the
# granularity a differential base can usefully act on; finer just crowds the
# scale and invites the model to over-read it.
DEFAULT_MARKS_DEG = (-60, -45, -30, -15, 0, 15, 30, 45, 60)

_YELLOW = (0, 255, 255)
_ORANGE = (0, 100, 255)
_GREEN = (0, 255, 0)


def focal_px(width_px, fov_deg):
    """Pinhole focal length in pixels for a given width and horizontal FOV."""
    return (width_px / 2.0) / math.tan(math.radians(fov_deg) / 2.0)


def angle_to_x(angle_deg, width_px, fov_deg):
    """Pixel column for a bearing, using the rectilinear (tangent) mapping.

    NOT the linear `x = cx + angle/half_fov * cx` shortcut. On a 90 deg lens
    the linear version misplaces a 30 deg mark by ~7% of the half-width, and
    the error grows toward the edges — which is precisely where obstacle
    bearings matter for steering around something.
    """
    cx = width_px / 2.0
    return cx + focal_px(width_px, fov_deg) * math.tan(math.radians(angle_deg))


def x_to_angle(x_px, width_px, fov_deg):
    """Inverse of angle_to_x: what bearing does this pixel column sit at.

    The planner needs this to turn a model's "the box is at x=430" (or a
    detector's bounding-box centre) into a heading it can command.
    """
    cx = width_px / 2.0
    return math.degrees(math.atan((x_px - cx) / focal_px(width_px, fov_deg)))


def visible_marks(width_px, fov_deg, marks_deg=DEFAULT_MARKS_DEG):
    """[(x_px, angle_deg)] for the marks that actually land inside the frame.

    A 90 deg lens cannot show a 60 deg mark near the edge without it being
    cropped or misleading, so marks outside the frame are dropped rather than
    clamped to the border — a clamped mark would stack several angles on the
    same pixel and read as a scale that is simply wrong.
    """
    out = []
    for a in marks_deg:
        if abs(a) >= fov_deg / 2.0:
            continue
        x = angle_to_x(a, width_px, fov_deg)
        if 0 <= x < width_px:
            out.append((int(round(x)), a))
    return out


def draw_bearing_scale(frame, fov_deg=None, marks_deg=DEFAULT_MARKS_DEG,
                       show_arm_range=False):
    """Draw the scale onto `frame` (BGR uint8) IN PLACE and return it.

    `show_arm_range` adds a coarse indication of where the arms can reach —
    useful when the task is "pick that up" rather than "drive there".
    """
    import cv2  # local: the pure maths above must import without OpenCV

    fov = DEFAULT_FOV_DEG if fov_deg is None else fov_deg
    h, w = frame.shape[:2]
    y = max(18, int(h * 0.05))

    cv2.line(frame, (0, y), (w, y), _YELLOW, 2)
    for x, a in visible_marks(w, fov, marks_deg):
        tall = (a == 0)
        cv2.line(frame, (x, y - (14 if tall else 9)), (x, y + (14 if tall else 9)),
                 _ORANGE, 2 if not tall else 3)
        label = "0" if a == 0 else f"{a:+d}"
        (tw, _), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 2)
        cv2.putText(frame, label, (x - tw // 2, y + 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, _ORANGE, 2)

    cv2.putText(frame, "<=LEFT", (8, h - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.6, _ORANGE, 2)
    (tw, _), _ = cv2.getTextSize("RIGHT=>", cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
    cv2.putText(frame, "RIGHT=>", (w - tw - 8, h - 10),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, _YELLOW, 2)

    if show_arm_range:
        y0, y1 = int(h * 0.42), int(h * 0.30)
        cv2.line(frame, (int(w * 0.16), y0), (int(w * 0.31), y1), _GREEN, 3)
        cv2.line(frame, (int(w * 0.31), y1), (int(w * 0.69), y1), _GREEN, 3)
        cv2.line(frame, (int(w * 0.69), y1), (int(w * 0.84), y0), _GREEN, 3)
        cv2.putText(frame, "arm range", (int(w * 0.62), y1 - 8),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, _GREEN, 1)
    return frame


def measure_fov_hint():
    """How to establish the real FOV, since the default is a guess.

    Returned as text rather than done automatically: it needs a tape measure,
    and a wrong answer here poisons every bearing the planner acts on.
    """
    return (
        "Place a narrow object so it sits exactly at the left edge of the frame. "
        "Measure d = its perpendicular distance from the lens, and o = its offset "
        "from the camera's centre line, in the same units. Then "
        "FOV = 2 * degrees(atan(o / d)). Set LEX_XLE_CAMERA_FOV to that."
    )
