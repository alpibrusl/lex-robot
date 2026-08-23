#!/usr/bin/env python3
"""Collect hand-eye calibration samples by HAND-GUIDING the arm.

WHY HAND-GUIDED

The wrist camera is eye-IN-hand: it moves with the arm, so it has no fixed
pose in the arm frame and cannot be a static CameraModel. What IS fixed is its
transform in the GRIPPER frame — find that once and it composes with FK at
every future pose.

Solving for it needs the same landmark seen from several different gripper
poses. Driving the arm there blindly is the risky way to get them; the arm is
backdrivable, so a human placing it is faster, safer, and needs no prior
calibration — which is the whole point, since we do not have one yet.

WHAT IT RECORDS, AND WHAT IT DOES NOT

Per sample: the six joint angles, the FK gripper pose, and the landmark's
NORMALIZED PIXEL position from the vision service's /vision/detect. It does
NOT keep the frames. A wrist camera photographs your room, and nothing here
needs the pixels once the detection is out of them.

Torque stays OFF the whole time — this tool never commands a joint. You move
the arm; it watches. It waits for the arm to be STILL before sampling, so a
frame captured mid-motion cannot be paired with a pose already moved on from.

USAGE
    # sidecar stopped (it owns the bus and cameras), vision service running
    scripts/capture_handeye_poses.py --landmark "beer can" --samples 6

Move the arm so the can is visible in the wrist camera, hold still ~2 s, and
it takes a sample; reposition and repeat. Vary the pose as much as you can —
different heights, angles and distances. Samples that all look alike constrain
nothing, and the tool will say so.
"""
import argparse
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
CAM_INDEX = {"left": 2, "right": 0}          # verified on hardware, see the Pi env file
STILL_DEG = 0.8                              # per-joint movement counting as "still"
STILL_FOR_S = 2.0
MOVED_DEG = 4.0                              # a new pose must differ by at least this


def detect(vision_url, jpeg_b64, name, timeout_s):
    body = json.dumps({"image_b64": jpeg_b64, "name": name}).encode()
    req = urllib.request.Request(f"{vision_url}/vision/detect", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s) as r:
        return json.loads(r.read())


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--arm", choices=["left", "right"], default="left")
    p.add_argument("--landmark", default="beer can")
    p.add_argument("--samples", type=int, default=6)
    p.add_argument("--vision-url", default=os.environ.get("LEX_XLE_VISION_URL",
                                                          "http://127.0.0.1:8901"))
    p.add_argument("--min-confidence", type=float, default=0.3)
    p.add_argument("--out", default="handeye_samples.json")
    a = p.parse_args()

    import base64

    import cv2
    from lerobot.model.kinematics import RobotKinematics
    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    from lerobot.robots.so_follower.robot_kinematic_processor import (
        compute_forward_kinematics_joints_to_ee)

    urdf = os.environ.get("LEX_XLE_URDF_PATH", "")
    if not urdf or not pathlib.Path(urdf).is_file():
        sys.exit("LEX_XLE_URDF_PATH must point at the SO-101 URDF (FK is how the "
                 "gripper pose is known). See deploy/pi/xlerobot.env.example.")
    kin = RobotKinematics(urdf_path=urdf, joint_names=ARM_JOINTS,
                          target_frame_name=os.environ.get("LEX_XLE_URDF_TARGET_FRAME",
                                                           "gripper_frame_link"))

    follower = SO101Follower(SO101FollowerConfig(port=PORTS[a.arm], id=f"xle_{a.arm}"))
    follower.bus.connect()          # bus only: never configure(), so torque stays OFF
    cap = cv2.VideoCapture(CAM_INDEX[a.arm], cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    for _ in range(8):
        cap.read()

    def joints():
        o = follower.bus.sync_read("Present_Position")
        return [float(o[j]) for j in ARM_JOINTS]

    def ee(js):
        e = compute_forward_kinematics_joints_to_ee(
            {f"{j}.pos": v for j, v in zip(ARM_JOINTS, js)}, kin, ARM_JOINTS)
        return [round(float(e[k]), 5) for k in ("ee.x", "ee.y", "ee.z")]

    print(f"\n  Hand-guide the {a.arm} arm so the {a.landmark!r} is in the wrist camera.")
    print(f"  Hold still ~{STILL_FOR_S:.0f}s to take a sample. Torque is OFF; I never move the arm.")
    print(f"  Need {a.samples} samples — VARY the pose between them.\n")

    samples, last_sampled = [], None
    prev, still_since = joints(), time.time()
    try:
        while len(samples) < a.samples:
            time.sleep(0.25)
            now = joints()
            if max(abs(x - y) for x, y in zip(now, prev)) > STILL_DEG:
                still_since = time.time()
            prev = now
            if time.time() - still_since < STILL_FOR_S:
                continue
            if last_sampled and max(abs(x - y) for x, y in zip(now, last_sampled)) < MOVED_DEG:
                continue                     # same pose as last time; move it further
            for _ in range(4):
                cap.read()
            ok, frame = cap.read()
            if not ok:
                continue
            b64 = base64.b64encode(cv2.imencode(".jpg", frame)[1].tobytes()).decode()
            try:
                d = detect(a.vision_url, b64, a.landmark, 120)
            except Exception as e:
                print(f"    vision service unreachable: {e}")
                continue
            conf = float(d.get("confidence", 0) or 0)
            if not d.get("found") or conf < a.min_confidence:
                print(f"    {a.landmark!r} not seen (found={d.get('found')}, "
                      f"conf={conf:.2f}) — reposition so it is clearly in view")
                still_since = time.time()
                continue
            pose = ee(now)
            samples.append({"joints_deg": [round(x, 3) for x in now],
                            "ee_xyz_m": pose,
                            "pixel_uv": [round(float(d["cx"]), 4), round(float(d["cy"]), 4)],
                            "confidence": round(conf, 3)})
            last_sampled = now
            print(f"  [{len(samples)}/{a.samples}] gripper ({pose[0]:+.3f},{pose[1]:+.3f},"
                  f"{pose[2]:+.3f})  {a.landmark} at pixel "
                  f"({d['cx']:.3f},{d['cy']:.3f})  conf {conf:.2f}")
            still_since = time.time()
    except KeyboardInterrupt:
        print("\n  stopped early")
    finally:
        cap.release()
        follower.bus.disconnect()

    if len(samples) < 3:
        print(f"\n  Only {len(samples)} samples — too few to solve anything. Need 3+.")
        return 1
    spread = max(math.dist(s["ee_xyz_m"], t["ee_xyz_m"]) for s in samples for t in samples)
    pathlib.Path(a.out).write_text(json.dumps(
        {"arm": a.arm, "landmark": a.landmark, "camera_index": CAM_INDEX[a.arm],
         "note": "eye-in-hand: solve for the camera transform in the GRIPPER frame, "
                 "plus the landmark's fixed world position. No frames retained.",
         "samples": samples}, indent=2) + "\n")
    print(f"\n  wrote {a.out}: {len(samples)} samples, gripper spread {spread * 100:.0f} cm")
    if spread < 0.10:
        print("  WARNING: poses are clustered within 10 cm. A solve from these will be "
              "ill-conditioned — recapture with the arm moved much further between samples.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
