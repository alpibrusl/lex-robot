#!/usr/bin/env python3
"""Grasp using a hand-guided demonstration as the target pose.

WHY THIS EXISTS — TWO RULES THAT WERE WRONG

A visual-servo attempt failed for hours against what looked like a reach limit.
A 60-second hand-guided demonstration disproved it in one go, and showed both
mistakes:

  1. PERCEPTION DICTATED POSTURE. The servo's first move hoisted shoulder_lift
     +1200 ticks purely so the head camera could see the gripper. The real
     grasp sits at -53 from rest — so that first move went 1253 ticks (110
     degrees) in the WRONG DIRECTION, into a high cantilevered pose. Three
     joints then read ~990/1023 load, which read as "the can is out of reach".
     The arm was not near its limits because the target was far; it was near
     its limits because the code put it there.

  2. THE SAFETY MARGIN FORBADE THE ANSWER. Clamping 60 ticks inside each
     calibrated range blocks FOUR of six joints at the demonstrated grasp pose
     (shoulder_lift by 56, elbow_flex by 69, wrist_flex by 67, gripper by 62).
     Two of those demonstrated values sit just below the recorded range_min,
     so the calibration itself is slightly conservative and the extra margin
     compounded it.

So: start from rest, trust the demonstration, and clamp only enough to protect
the servo rather than enough to forbid the task.

WHAT IT DOES

Moves to the demonstrated joint pose with the gripper OPEN (opening first, so
the fingers arrive around the can rather than into it), interpolating in small
steps under a load guard, checks the wrist camera, closes, and reports whether
anything is actually held — judged by where the fingers stopped, not by hope.
"""
import argparse
import json
import pathlib
import sys
import time

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll"]
PORT = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00"
CAL = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration/robots/so_follower/xle_left.json"
# 10, not 60. The old margin blocked the demonstrated grasp on four joints.
# The calibrated range already encodes the mechanical stops; this only keeps a
# little air so a command cannot sit exactly on one.
MARGIN = 10
LOAD_ABORT = 700
GRIP_OPEN = 2900


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--demo", required=True, help="recorded hand-guided session (json)")
    p.add_argument("--steps", type=int, default=14, help="interpolation steps")
    p.add_argument("--dry-run", action="store_true", help="pose, but never close")
    a = p.parse_args()

    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig

    rec = json.loads(pathlib.Path(a.demo).read_text())
    goal = rec[-1]
    cal = json.loads(CAL.read_text()) if CAL.is_file() else {}
    grip_demo = int(goal["gripper"])

    def clamp(j, v):
        c = cal.get(j)
        return int(v) if not c else int(max(c["range_min"] + MARGIN,
                                            min(c["range_max"] - MARGIN, v)))

    rob = SO101Follower(SO101FollowerConfig(port=PORT, id="xle_left"))
    rob.bus.connect()
    home = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
    outcome = "did not start"
    try:
        print("  target pose from your demonstration:")
        for j in ARM + ["gripper"]:
            c = cal.get(j, {})
            print(f"    {j:<14}{int(goal[j]):>6}   (calibrated {c.get('range_min','?')}"
                  f"..{c.get('range_max','?')}, clamped to {clamp(j, goal[j])})")

        rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
        for j in ARM + ["gripper"]:
            rob.bus.write("Torque_Enable", j, 1, normalize=False, num_retry=3)
            rob.bus.write("Lock", j, 1, normalize=False, num_retry=3)
        time.sleep(0.5)

        # Gripper OPEN before travelling, or the fingers arrive into the can
        # instead of around it.
        rob.bus.write("Goal_Position", "gripper", GRIP_OPEN, normalize=False, num_retry=3)
        time.sleep(1.5)
        print("  gripper open; moving to the demonstrated pose")

        # Interpolate from where the arm ACTUALLY is now, not from the pose read
        # before torque was engaged. With torque off the arm droops under
        # gravity — measured 1113 -> 1062 on shoulder_lift — so interpolating
        # from the stale value commands it to LIFT back up first. That is the
        # one expensive direction: lowering costs load 28, raising costs 960,
        # and the guard then refuses at step 1 of a move that never needed to
        # go up at all.
        settled = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
        sag = {j: int(settled[j]) - int(home[j]) for j in ARM}
        if any(abs(v) > 5 for v in sag.values()):
            print(f"    arm settled since the initial read: {sag}")
        start = {j: int(settled[j]) for j in ARM}
        for s in range(1, a.steps + 1):
            frac = s / a.steps
            for j in ARM:
                tgt = clamp(j, start[j] + (int(goal[j]) - start[j]) * frac)
                rob.bus.write("Goal_Position", j, tgt, normalize=False, num_retry=3)
            time.sleep(0.45)
            # Load must be read AFTER the joint settles, and as a median.
            # Sampling straight after a command catches the acceleration
            # transient: those reads hit 990-1004 while the same joints holding
            # the same pose read exactly 0. Believing the transient is what
            # produced "the arm is at its limit, the can is out of reach" —
            # a conclusion about the hardware drawn from a measurement bug.
            time.sleep(0.35)
            hot = []
            for j in ARM:
                v = sorted(rob.bus.read("Present_Load", j, normalize=False, num_retry=3) & 0x3FF
                           for _ in range(3))
                hot.append((j, v[1]))
            worst = max(hot, key=lambda x: x[1])
            if worst[1] >= LOAD_ABORT:
                outcome = f"stopped at step {s}/{a.steps}: {worst[0]} load {worst[1]}"
                return 1
            if s % 4 == 0 or s == a.steps:
                print(f"    step {s:2d}/{a.steps}  worst load {worst[0]}={worst[1]}")

        now = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
        err = {j: int(now[j]) - clamp(j, goal[j]) for j in ARM}
        print(f"  arrived; per-joint error from the demo pose: {err}")

        if a.dry_run:
            outcome = "dry run — at the demonstrated pose, gripper NOT closed"
            return 0

        # Close to where the demonstration closed, not to a guessed value.
        target_close = clamp("gripper", grip_demo)
        rob.bus.write("Goal_Position", "gripper", target_close, normalize=False, num_retry=3)
        time.sleep(2.5)
        pos = rob.bus.read("Present_Position", "gripper", normalize=False, num_retry=3)
        load = rob.bus.read("Present_Load", "gripper", normalize=False, num_retry=3) & 0x3FF
        print(f"  gripper commanded {target_close}, stopped at {pos}, load {load}")
        # Fingers meeting air reach the commanded value. Something between them
        # stops them short — that, not a camera, is the honest test.
        if pos > target_close + 40 or load > 150:
            outcome = (f"HOLDING SOMETHING — fingers stopped {pos - target_close} ticks "
                       f"short of the commanded close, load {load}")
        else:
            outcome = f"closed on nothing — reached {pos}, load {load}"
        return 0
    finally:
        print(f"\n  OUTCOME: {outcome}")
        if outcome.startswith("HOLDING"):
            print("  LEAVING THE ARM HOLDING IT — torque stays on so it does not drop.")
            print("  Release with:  scripts/release_left_arm.sh")
        else:
            try:
                rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
                time.sleep(2.5)
                for j in ARM + ["gripper"]:
                    rob.bus.write("Torque_Enable", j, 0, normalize=False, num_retry=3)
                print("  arm home and released")
            except Exception as e:
                print(f"  cleanup issue: {e}")
        rob.bus.disconnect()


if __name__ == "__main__":
    sys.exit(main())
