"""Snapshot the arm's current NORMALIZED pose, to author real waypoints.

Read-only on the servos. Pose the arm by hand (torque off) or drive it where
you want it, then hit ENTER to capture. Emits a `cycle` array that drops
straight into sidecar/waypoints_pick_place.json.

    python sidecar/capture_waypoints.py --port /dev/cu.usbmodem5B3D0437151 --id xle_left

Requires the arm to be calibrated (see `lerobot-calibrate`) -- normalized
units are meaningless without it.
"""
import argparse, json

from lerobot.robots.so_follower import SOFollowerRobotConfig, SO101Follower

p = argparse.ArgumentParser()
p.add_argument("--port", required=True)
p.add_argument("--id", default="xle_left")
p.add_argument("--out", default="-")
a = p.parse_args()

robot = SO101Follower(SOFollowerRobotConfig(port=a.port, id=a.id))
robot.connect()
cycle = []
try:
    print("ENTER captures the current pose; 'q' then ENTER finishes.\n")
    while True:
        if input(f"[{len(cycle)}] name (or 'q'): ").strip().lower() == "q":
            break
        name = f"wp{len(cycle)}"
        obs = robot.get_observation()
        pose = {k.removesuffix(".pos"): round(float(v), 2)
                for k, v in obs.items() if k.endswith(".pos")}
        cycle.append({"name": name, "move_s": 1.5, "hold_s": 0.3, "pose": pose})
        print(f"    captured {pose}")
finally:
    robot.disconnect()

blob = json.dumps({"fps": 30, "cycle": cycle}, indent=2)
if a.out == "-":
    print("\n" + blob)
else:
    open(a.out, "w").write(blob + "\n")
    print(f"\nwrote {a.out}")
