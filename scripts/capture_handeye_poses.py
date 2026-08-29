#!/usr/bin/env python3
"""Collect calibration samples from ALL the cameras at once, by hand-guiding.

Two calibrations need the same thing — one arm moved through several poses —
so there is no reason to collect them twice:

  HEAD camera (eye-TO-hand). Fixed on the tower, watching the gripper move.
  Each pose gives "this 3D point in the arm frame appeared at this pixel",
  which is what solves the camera's pose. This is the one src/camera.lex's
  static CameraModel actually wants, and it is only valid while the tower
  stays put — hence the drift check below.

  WRIST camera (eye-IN-hand). Rides the gripper, so it has no fixed pose in
  the arm frame; what is constant is its transform in the GRIPPER frame.
  Solving that needs one landmark seen from several gripper poses, which the
  same session provides for free.

WHY HAND-GUIDED. Driving the arm to poses is circular — it would use the
calibration we are trying to produce to reach the places that produce it. The
arm is backdrivable, so a human placing it needs nothing and risks nothing.
This tool NEVER commands a joint: it connects the bus and never calls
configure(), so torque stays off throughout.

WHAT IT KEEPS. Joint angles, the FK gripper position, and each camera's
detection as a normalized pixel. NOT the frames. These cameras photograph a
home, and nothing downstream needs the pixels once the detections are out.

TOWER DRIFT. Every sample records the tower's pan/tilt. If the head moves
mid-session, the eye-to-hand correspondences silently stop referring to the
same camera and the solve is quietly wrong — so a moved tower is reported and
those samples are marked, not averaged in.

USAGE
    # sidecar stopped (it owns the bus and cameras), vision service running
    scripts/capture_handeye_poses.py --samples 6 --landmark "beer can"
"""
import argparse
import base64
import json
import math
import os
import pathlib
import sys
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "sidecar"))

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex",
              "wrist_flex", "wrist_roll", "gripper"]
PORTS = {"left": "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00",
         "right": "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B61033220-if00"}
WRIST_INDEX = {"left": 2, "right": 0}       # verified on hardware; see the Pi env file
HEAD_INDEX = int(os.environ.get("LEX_XLE_CAMERA_HEAD_INDEX", "4"))
GRIPPER_NAME = "robot gripper with white finger pads"

STILL_DEG, STILL_FOR_S, MOVED_DEG = 0.8, 2.0, 4.0
TOWER_DRIFT_TICKS = 8


def detect(vision_url, b64, name, timeout_s=150):
    req = urllib.request.Request(
        f"{vision_url}/vision/detect",
        data=json.dumps({"image_b64": b64, "name": name}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s) as r:
        return json.loads(r.read())


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--arm", choices=["left", "right"], default="left")
    p.add_argument("--samples", type=int, default=6)
    p.add_argument("--landmark", default="beer can",
                   help="what the WRIST camera should look for (eye-in-hand)")
    p.add_argument("--vision-url",
                   default=os.environ.get("LEX_XLE_VISION_URL", "http://127.0.0.1:8901"))
    p.add_argument("--min-confidence", type=float, default=0.3)
    p.add_argument("--out", default="handeye_samples.json")
    a = p.parse_args()

    import cv2
    import tower
    from lerobot.model.kinematics import RobotKinematics
    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.robots.so_follower.robot_kinematic_processor import (
        compute_forward_kinematics_joints_to_ee)

    urdf = os.environ.get("LEX_XLE_URDF_PATH", "")
    if not urdf or not pathlib.Path(urdf).is_file():
        sys.exit("LEX_XLE_URDF_PATH must point at the SO-101 URDF — FK is how the "
                 "gripper's 3D position is known. See deploy/pi/xlerobot.env.example.")
    kin = RobotKinematics(urdf_path=urdf, joint_names=ARM_JOINTS,
                          target_frame_name=os.environ.get(
                              "LEX_XLE_URDF_TARGET_FRAME", "gripper_frame_link"))

    follower = SO101Follower(SO101FollowerConfig(port=PORTS[a.arm], id=f"xle_{a.arm}"))
    follower.bus.connect()            # bus only — never configure(), torque stays OFF
    twr = tower.TowerDriver(shared_bus=follower.bus,
                            pan_limits=(347, 3747), tilt_limits=(2523, 3400))
    cams = {}
    for name, idx in (("head", HEAD_INDEX), ("wrist", WRIST_INDEX[a.arm])):
        c = cv2.VideoCapture(idx, cv2.CAP_V4L2)
        c.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        c.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        c.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        for _ in range(6):
            c.read()
        cams[name] = c

    def joints():
        o = follower.bus.sync_read("Present_Position")
        return [float(o[j]) for j in ARM_JOINTS]

    def grab(which):
        for _ in range(4):
            cams[which].read()
        ok, f = cams[which].read()
        if not ok:
            return None
        return base64.b64encode(cv2.imencode(".jpg", f)[1].tobytes()).decode()

    t0 = twr.read()
    tower0 = (t0["pan_ticks"], t0["tilt_ticks"])
    print(f"\n  tower locked at pan {tower0[0]} tilt {tower0[1]} — do NOT nudge it.")
    print(f"  Hand-guide the {a.arm} arm. Hold still ~{STILL_FOR_S:.0f}s per sample.")
    print(f"  Keep the gripper in the HEAD camera's view; point the WRIST camera at")
    print(f"  the {a.landmark!r} when you can. Need {a.samples}. VARY the pose.\n")

    samples, last, prev, still_since = [], None, joints(), time.time()
    try:
        while len(samples) < a.samples:
            time.sleep(0.25)
            now = joints()
            if max(abs(x - y) for x, y in zip(now, prev)) > STILL_DEG:
                still_since = time.time()
            prev = now
            if time.time() - still_since < STILL_FOR_S:
                continue
            if last and max(abs(x - y) for x, y in zip(now, last)) < MOVED_DEG:
                continue
            t = twr.read()
            drift = max(abs(t["pan_ticks"] - tower0[0]), abs(t["tilt_ticks"] - tower0[1]))
            e = compute_forward_kinematics_joints_to_ee(
                {f"{j}.pos": v for j, v in zip(ARM_JOINTS, now)}, kin, ARM_JOINTS)
            ee = [round(float(e[k]), 5) for k in ("ee.x", "ee.y", "ee.z")]

            hb, wb = grab("head"), grab("wrist")
            head_hit = wrist_hit = None
            if hb:
                try:
                    d = detect(a.vision_url, hb, GRIPPER_NAME)
                    if d.get("found") and float(d.get("confidence", 0)) >= a.min_confidence:
                        head_hit = [round(float(d["cx"]), 4), round(float(d["cy"]), 4),
                                    round(float(d["confidence"]), 3)]
                except Exception as ex:
                    print(f"    head detect failed: {ex}")
            if wb:
                try:
                    d = detect(a.vision_url, wb, a.landmark)
                    if d.get("found") and float(d.get("confidence", 0)) >= a.min_confidence:
                        wrist_hit = [round(float(d["cx"]), 4), round(float(d["cy"]), 4),
                                     round(float(d["confidence"]), 3)]
                except Exception as ex:
                    print(f"    wrist detect failed: {ex}")

            if head_hit is None and wrist_hit is None:
                print("    neither camera saw its target — reposition")
                still_since = time.time()
                continue
            samples.append({
                "joints_deg": [round(x, 3) for x in now], "ee_xyz_m": ee,
                "head_pixel_uv_conf": head_hit, "wrist_pixel_uv_conf": wrist_hit,
                "tower": [t["pan_ticks"], t["tilt_ticks"]],
                "tower_drift_ticks": drift,
            })
            last = now
            flag = "  <-- TOWER MOVED" if drift > TOWER_DRIFT_TICKS else ""
            print(f"  [{len(samples)}/{a.samples}] ee ({ee[0]:+.3f},{ee[1]:+.3f},{ee[2]:+.3f})"
                  f"  head {head_hit[:2] if head_hit else '--'}"
                  f"  wrist {wrist_hit[:2] if wrist_hit else '--'}{flag}")
            still_since = time.time()
    except KeyboardInterrupt:
        print("\n  stopped early")
    finally:
        for c in cams.values():
            c.release()
        follower.bus.disconnect()

    n_head = sum(1 for s in samples if s["head_pixel_uv_conf"])
    n_wrist = sum(1 for s in samples if s["wrist_pixel_uv_conf"])
    moved = [s for s in samples if s["tower_drift_ticks"] > TOWER_DRIFT_TICKS]
    spread = (max(math.dist(s["ee_xyz_m"], t["ee_xyz_m"]) for s in samples for t in samples)
              if len(samples) > 1 else 0.0)
    pathlib.Path(a.out).write_text(json.dumps({
        "arm": a.arm, "landmark": a.landmark, "tower_reference": list(tower0),
        "head_camera_index": HEAD_INDEX, "wrist_camera_index": WRIST_INDEX[a.arm],
        "note": "head = eye-TO-hand (solve camera pose in the arm frame, valid only "
                "for tower_reference). wrist = eye-IN-hand (solve camera transform in "
                "the gripper frame). No frames retained.",
        "samples": samples}, indent=2) + "\n")
    print(f"\n  wrote {a.out}")
    print(f"  {len(samples)} samples — {n_head} usable for the HEAD (eye-to-hand) solve, "
          f"{n_wrist} for the WRIST (eye-in-hand) solve")
    print(f"  gripper spread {spread * 100:.0f} cm")
    if n_head < 4:
        print("  NOTE: a head-camera pose solve wants 4+ correspondences; "
              f"only {n_head} here.")
    if spread < 0.10:
        print("  WARNING: poses cluster within 10 cm — any solve from these is "
              "ill-conditioned. Recapture with the arm moved much further between poses.")
    if moved:
        print(f"  WARNING: the tower moved on {len(moved)} sample(s). Those head "
              "correspondences refer to a different camera pose and must not be mixed in.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
