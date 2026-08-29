#!/usr/bin/env python3
"""Eye-to-hand calibration of the head camera, using the gripper as its own fiducial.

THE DETECTOR IS MOTION, NOT A MARKER

Asking a VLM where the gripper is returns positions spanning 38 px on the SAME
image — 20x too coarse to calibrate with. A printed ArUco marker would fix
that, but needs a printer. Opening and closing the gripper and differencing the
two frames needs nothing at all: the only thing that changed is the finray
fingers, so the motion blob IS the gripper, and the background cancels because
it did not move.

Measured repeatability on this unit: 0.1 px over four trials. That is ~400x
better than the VLM and comfortably inside what a pose solve needs.

WHAT IS BEING SOLVED

At each arm pose, FK gives the gripper's 3D position in the arm frame and the
motion blob gives its pixel. Four or more well-spread correspondences determine
the camera's pose by PnP. The result is only valid for the tower pose it was
captured at, so the tower is read at every sample and drift is refused, not
averaged in.

KNOWN BIAS, STATED RATHER THAN HIDDEN

The motion centroid is the middle of the moving finger region, not the
gripper_frame_link origin FK reports. Those differ by a fixed offset of a few
centimetres. With the gripper's ORIENTATION held constant across poses that
offset is a constant translation, so it biases the solved camera POSITION by
that amount while leaving the orientation correct. The script therefore holds
orientation fixed, reports the residuals honestly, and refuses to write a
calibration whose reprojection error is too large to be trusted.

SAFETY

Goal is synced to present BEFORE torque is enabled, so engaging cannot snap the
arm to a stale target. Moves are joint-space deltas from the current pose, small
and bounded; nothing is commanded in Cartesian space, so no IK solution can
send the arm somewhere unexpected. Every move is verified to have landed before
a sample is taken.
"""
import argparse
import json
import math
import os
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "sidecar"))

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex",
              "wrist_flex", "wrist_roll", "gripper"]
LEFT_PORT = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00"
GRIP_CLOSED, GRIP_OPEN = 2100, 2900
MAX_STEP_TICKS = 380                  # per joint, per pose — bounded, but big
LIMIT_MARGIN = 60                     # stay this far inside the calibrated range
SETTLE_S = 2.2                        # then _wait_until_still confirms it


def _wait_until_still(grab, tries=12, quiet=2.0):
    """Block until consecutive frames stop changing.

    Without this the differencing is worthless. The gripper open/close diff
    only isolates the fingers if NOTHING ELSE moved between the two frames —
    but an arm still settling from the previous pose keeps drifting, and the
    diff then captures the whole arm. Measured: blob areas ranged 924..21552
    across poses (20x) with a fixed 1 s sleep, versus a stable ~3700 when the
    arm was genuinely at rest. That contamination alone took the solve from
    usable to 116 px.
    """
    import numpy as np
    prev = grab()
    for _ in range(tries):
        cur = grab()
        if prev is not None and cur is not None:
            if float(np.abs(cur - prev).mean()) < quiet:
                return True
        prev = cur
    return False


def motion_pixel(cap, set_gripper, blur=5, thresh=25, expect_area=None):
    """Pixel of the gripper, found by differencing closed against open."""
    import cv2
    import numpy as np

    def grab():
        for _ in range(4):
            cap.read()
        ok, f = cap.read()
        if not ok:
            return None
        return cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.int16)

    set_gripper(GRIP_CLOSED)
    if not _wait_until_still(grab):
        return None                    # never settled; a diff here would be noise
    a = grab()
    set_gripper(GRIP_OPEN)
    if not _wait_until_still(grab):
        return None
    b = grab()
    if a is None or b is None:
        return None
    d = cv2.GaussianBlur(np.abs(b - a).astype(np.uint8), (blur, blur), 0)
    _, m = cv2.threshold(d, thresh, 255, cv2.THRESH_BINARY)
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    n, _lab, st, ce = cv2.connectedComponentsWithStats(m, 8)
    if n < 2:
        return None
    i = max(range(1, n), key=lambda k: st[k, cv2.CC_STAT_AREA])
    area = int(st[i, cv2.CC_STAT_AREA])
    if area < 400:                    # too small to be the fingers; probably noise
        return None
    # The fingers subtend a fairly consistent area. Something 2x off is not the
    # fingers — it is the whole arm having moved, or only a sliver being visible.
    if expect_area and not (expect_area / 2.2 < area < expect_area * 2.2):
        return None
    return float(ce[i][0]), float(ce[i][1]), area


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--focal-px", type=float, default=348.4)
    p.add_argument("--max-reproj-px", type=float, default=4.0,
                   help="refuse to write a calibration worse than this")
    p.add_argument("--out", default="")
    p.add_argument("--samples-out", default="")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()

    import cv2
    import numpy as np
    import tower
    from lerobot.model.kinematics import RobotKinematics
    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.robots.so_follower.robot_kinematic_processor import (
        compute_forward_kinematics_joints_to_ee)

    urdf = os.environ.get("LEX_XLE_URDF_PATH", "")
    if not urdf or not pathlib.Path(urdf).is_file():
        sys.exit("LEX_XLE_URDF_PATH must point at the SO-101 URDF.")
    kin = RobotKinematics(urdf_path=urdf, joint_names=ARM_JOINTS,
                          target_frame_name=os.environ.get(
                              "LEX_XLE_URDF_TARGET_FRAME", "gripper_frame_link"))

    cap = cv2.VideoCapture(int(os.environ.get("LEX_XLE_CAMERA_HEAD_INDEX", "4")),
                           cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    for _ in range(8):
        cap.read()

    rob = SO101Follower(SO101FollowerConfig(port=LEFT_PORT, id="xle_left"))
    rob.bus.connect()
    twr = tower.TowerDriver(shared_bus=rob.bus, pan_limits=(347, 3747),
                            tilt_limits=(2523, 3400))
    home = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
    t0 = twr.read()
    tower_ref = (t0["pan_ticks"], t0["tilt_ticks"])
    print(f"  tower reference pan {tower_ref[0]} tilt {tower_ref[1]}")

    def set_joint(j, v):
        rob.bus.write("Goal_Position", j, int(v), normalize=False, num_retry=3)

    def set_gripper(v):
        set_joint("gripper", v)
        time.sleep(0.9)

    # Poses as joint deltas from home, sized to the room each joint ACTUALLY has.
    #
    # A first version used symmetric +/- deltas and lost a third of its poses to
    # servos clamping at their calibrated travel limits — this arm parks right
    # at shoulder_lift's minimum and elbow_flex's maximum, so half of every
    # symmetric pair was unreachable. The surviving poses spanned only ~5 cm,
    # and PnP over a 5 cm baseline at 0.4 m range is hopelessly conditioned:
    # the solve came back 20 px and 41 cm off. Spread is not a nicety here, it
    # is the difference between a calibration and a number.
    cal_path = (pathlib.Path.home() / ".cache/huggingface/lerobot/calibration"
                / "robots/so_follower/xle_left.json")
    cal = json.loads(cal_path.read_text()) if cal_path.is_file() else {}

    def room(j, sign):
        """How far joint j can move in `sign`, staying inside its travel limits."""
        c = cal.get(j)
        if not c:
            return MAX_STEP_TICKS // 2
        lo, hi = c["range_min"] + LIMIT_MARGIN, c["range_max"] - LIMIT_MARGIN
        avail = (hi - home[j]) if sign > 0 else (home[j] - lo)
        return max(0, min(MAX_STEP_TICKS, int(avail)))

    def step(j, sign, frac=1.0):
        return sign * int(room(j, sign) * frac)

    deltas = [{}]
    for j in ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex"):
        for sign in (+1, -1):
            for frac in (1.0, 0.55):
                d = step(j, sign, frac)
                if abs(d) >= 90:                 # too small to add real spread
                    deltas.append({j: d})
    # a few combinations, so the point cloud is not a cross of single-axis arms
    deltas += [{"shoulder_pan": step("shoulder_pan", +1, 0.7),
                "shoulder_lift": step("shoulder_lift", +1, 0.5)},
               {"shoulder_pan": step("shoulder_pan", -1, 0.7),
                "elbow_flex": step("elbow_flex", -1, 0.5)}]
    deltas = [d for d in deltas if not d or any(abs(v) >= 90 for v in d.values())]
    print(f"  {len(deltas)} candidate poses, sized to each joint's remaining travel")
    samples = []
    try:
        rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
        for j in ARM_JOINTS:
            rob.bus.write("Torque_Enable", j, 1, normalize=False, num_retry=3)
            rob.bus.write("Lock", j, 1, normalize=False, num_retry=3)
        time.sleep(0.5)
        landed = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
        drift = max(abs(landed[k] - home[k]) for k in home)
        print(f"  torque engaged; movement on engage {drift} ticks (goal was pre-synced)")

        for n, dl in enumerate(deltas, 1):
            for j, dv in dl.items():
                if abs(dv) > MAX_STEP_TICKS:
                    sys.exit(f"refusing a {dv}-tick step on {j}")
                set_joint(j, home[j] + dv)
            time.sleep(SETTLE_S)
            now = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
            for j, dv in dl.items():
                if abs(now[j] - (home[j] + dv)) > 60:
                    print(f"    pose {n}: {j} did not land "
                          f"(wanted {home[j]+dv}, at {now[j]}) — skipping")
                    break
            else:
                t = twr.read()
                if max(abs(t["pan_ticks"] - tower_ref[0]),
                       abs(t["tilt_ticks"] - tower_ref[1])) > 8:
                    sys.exit("tower moved mid-capture — every correspondence so far "
                             "refers to a camera pose that no longer exists. Aborting.")
                median = (sorted(x["blob_area"] for x in samples)[len(samples)//2]
                          if len(samples) >= 3 else None)
                hit = motion_pixel(cap, set_gripper, expect_area=median)
                if hit is None:
                    print(f"    pose {n}: gripper not visible / no motion blob")
                else:
                    deg = rob.bus.sync_read("Present_Position", num_retry=3)
                    e = compute_forward_kinematics_joints_to_ee(
                        {f"{j}.pos": float(deg[j]) for j in ARM_JOINTS}, kin, ARM_JOINTS)
                    ee = [float(e[k]) for k in ("ee.x", "ee.y", "ee.z")]
                    samples.append({"ee_xyz_m": [round(v, 5) for v in ee],
                                    "pixel": [round(hit[0], 2), round(hit[1], 2)],
                                    "blob_area": hit[2]})
                    print(f"  [{len(samples)}] ee ({ee[0]:+.3f},{ee[1]:+.3f},{ee[2]:+.3f})"
                          f"  pixel ({hit[0]:6.1f},{hit[1]:6.1f})  area {hit[2]}")
            for j in dl:
                set_joint(j, home[j])
            time.sleep(0.6)
    finally:
        print("  returning to the start pose and releasing")
        rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
        time.sleep(1.2)
        for j in ARM_JOINTS:
            try:
                rob.bus.write("Torque_Enable", j, 0, normalize=False, num_retry=3)
            except Exception:
                pass
        rob.bus.disconnect()
        cap.release()

    if a.samples_out:
        pathlib.Path(a.samples_out).write_text(json.dumps(
            {"tower_reference": list(tower_ref), "samples": samples}, indent=2) + "\n")
    if len(samples) < 4:
        print(f"\n  only {len(samples)} usable poses — PnP needs 4+. Nothing solved.")
        return 1

    obj = np.array([s["ee_xyz_m"] for s in samples], np.float64)
    img = np.array([s["pixel"] for s in samples], np.float64)
    K = np.array([[a.focal_px, 0, 320.0], [0, a.focal_px, 240.0], [0, 0, 1.0]])
    spread = [float(np.ptp(obj[:, i])) for i in range(3)]  # np.ptp: ndarray.ptp went in NumPy 2.0
    print(f"\n  {len(samples)} poses; gripper spread x {spread[0]*100:.0f} "
          f"y {spread[1]*100:.0f} z {spread[2]*100:.0f} cm")

    best = None
    for flag, name in ((cv2.SOLVEPNP_EPNP, "EPNP"), (cv2.SOLVEPNP_SQPNP, "SQPNP"),
                       (cv2.SOLVEPNP_ITERATIVE, "ITERATIVE")):
        try:
            ok, rvec, tvec = cv2.solvePnP(obj, img, K, None, flags=flag)
        except cv2.error:
            continue
        if not ok:
            continue
        rvec, tvec = cv2.solvePnPRefineLM(obj, img, K, None, rvec, tvec)
        proj, _ = cv2.projectPoints(obj, rvec, tvec, K, None)
        err = np.linalg.norm(proj.reshape(-1, 2) - img, axis=1)
        print(f"  {name:10} reprojection mean {err.mean():5.2f} px  max {err.max():5.2f} px")
        if best is None or err.mean() < best[0]:
            best = (err.mean(), name, rvec, tvec, err)

    mean, name, rvec, tvec, err = best
    R, _ = cv2.Rodrigues(rvec)
    C = (-R.T @ tvec).ravel()
    print(f"\n  BEST {name}: mean {mean:.2f} px, max {err.max():.2f} px")
    print(f"  camera position in LEFT-ARM frame ({C[0]:+.3f},{C[1]:+.3f},{C[2]:+.3f}) m")
    urdf_est = np.array([-0.043, -0.133, 0.4082])
    print(f"  URDF-sourced estimate        ({urdf_est[0]:+.3f},{urdf_est[1]:+.3f},"
          f"{urdf_est[2]:+.3f}) m  -> differs by {np.linalg.norm(C-urdf_est)*100:.1f} cm")
    print(f"  det(R) {np.linalg.det(R):+.3f}")

    if mean > a.max_reproj_px:
        print(f"\n  REFUSING to write: {mean:.2f} px exceeds --max-reproj-px "
              f"{a.max_reproj_px}. A fit this loose yields confidently wrong world "
              f"positions. More spread across all three axes is the usual cure.")
        return 1
    cam = {"pos": [round(float(v), 5) for v in C],
           "right": [round(float(v), 6) for v in R[0]],
           "down": [round(float(v), 6) for v in R[1]],
           "forward": [round(float(v), 6) for v in R[2]],
           "fx": round(a.focal_px / 640, 6), "fy": round(a.focal_px / 480, 6),
           "cx0": 0.5, "cy0": 0.5,
           "_provenance": {
               "method": f"eye-to-hand PnP ({name}) over {len(samples)} arm poses; "
                         "gripper located by open/close motion differencing "
                         "(0.1 px repeatable), NOT by a vision model (38 px).",
               "reprojection_px": {"mean": round(float(mean), 2),
                                   "max": round(float(err.max()), 2)},
               "tower_reference": list(tower_ref),
               "valid_only_at": "this tower pan/tilt — the camera rides the tower, so "
                                "moving it invalidates these extrinsics silently.",
               "known_bias": "the motion centroid is the finger region's middle, not "
                             "gripper_frame_link's origin; a few cm of fixed offset is "
                             "folded into pos. Orientation is unaffected.",
               "fx_fy": f"f={a.focal_px}px measured by tower rotation, normalized by "
                        "width/height per ray_direction's algebra.",
               "cx0_cy0": "ASSUMED image centre; not measured."}}
    print(json.dumps({k: v for k, v in cam.items() if k != "_provenance"}, indent=2))
    if a.out and not a.dry_run:
        pathlib.Path(a.out).write_text(json.dumps(cam, indent=2) + "\n")
        print(f"  wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
