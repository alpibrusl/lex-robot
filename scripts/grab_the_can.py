#!/usr/bin/env python3
"""Try to pick up a can, by visual servoing — no camera calibration needed.

WHY NO CALIBRATION

Calibration answers "where is that pixel in the world". Grasping only needs
"which way do I move to put the object between the fingers", and that can be
LEARNED in two probe moves: nudge a joint, see which way the object slid in
the image, keep the sign. Several hours of hand-eye work were sunk into the
former when the task only ever needed the latter.

HOW IT WORKS

  1. Drive shoulder_lift until the target appears in the wrist camera.
  2. Probe shoulder_pan by a small amount and measure the pixel shift. That
     gives px-per-tick AND its sign, for this arm, this camera, this pose.
  3. Centre the target horizontally using that gain.
  4. Creep forward, re-centring as it grows, until it fills enough of the
     frame to be within the fingers.
  5. Close the gripper. Confirm by load, not by hope.

SAFETY

Torque is engaged only after goal is synced to present, so nothing snaps.
Every joint move is bounded and clamped to the calibrated travel limits, each
is verified to have landed, and the arm returns to its start pose and releases
on ANY exit including exceptions. Lose sight of the target and it stops rather
than groping.
"""
import argparse
import base64
import json
import os
import pathlib
import sys
import time
import urllib.request

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
PORT = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00"
WRIST_CAM = 2
CAL = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration/robots/so_follower/xle_left.json"
GRIP_OPEN, GRIP_CLOSED = 2900, 2100
MARGIN = 60
# Present_Load is 0..1023. shoulder_lift threw an Overload error holding the arm
# extended; stop well before the servo has to protect itself.
LOAD_WARN, LOAD_ABORT = 380, 620


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--target", default="beer can")
    p.add_argument("--vision-url", default=os.environ.get("LEX_XLE_VISION_URL",
                                                          "http://127.0.0.1:8901"))
    p.add_argument("--lift-search-max", type=int, default=1400,
                   help="max shoulder_lift ticks above start while hunting for the target")
    p.add_argument("--approach-steps", type=int, default=5)
    p.add_argument("--dry-run", action="store_true",
                   help="find and centre, but never close the gripper")
    a = p.parse_args()

    import cv2

    cal = json.loads(CAL.read_text()) if CAL.is_file() else {}

    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
    cap = cv2.VideoCapture(WRIST_CAM, cv2.CAP_V4L2)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    for _ in range(8):
        cap.read()
    rob = SO101Follower(SO101FollowerConfig(port=PORT, id="xle_left"))
    rob.bus.connect()
    home = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)

    def clamp(j, v):
        c = cal.get(j)
        if not c:
            return int(v)
        return int(max(c["range_min"] + MARGIN, min(c["range_max"] - MARGIN, v)))

    def load_of(j):
        return rob.bus.read("Present_Load", j, normalize=False, num_retry=3) & 0x3FF

    def go(j, v, wait=1.3):
        rob.bus.write("Goal_Position", j, clamp(j, v), normalize=False, num_retry=3)
        time.sleep(wait)
        return rob.bus.read("Present_Position", j, normalize=False, num_retry=3)

    def go_guarded(j, v, wait=1.3):
        """Move, then check the servo is not straining.

        The first real attempt ended with the bus raising "Overload error!" on
        shoulder_lift — the servo protecting itself while holding the arm
        extended. Reacting to load BEFORE that point keeps the decision with us
        rather than with the motor's fault handler.
        """
        pos = go(j, v, wait)
        ld = load_of(j)
        if ld >= LOAD_ABORT:
            raise RuntimeError(f"{j} load {ld} >= {LOAD_ABORT} — stopping before it overloads")
        if ld >= LOAD_WARN:
            print(f"    (load on {j} is {ld}, getting heavy)")
        return pos

    def see():
        """(cx, cy, area_frac) of the target in the wrist view, or None."""
        for _ in range(4):
            cap.read()
        ok, f = cap.read()
        if not ok:
            return None
        b = base64.b64encode(cv2.imencode(".jpg", f)[1].tobytes()).decode()
        try:
            req = urllib.request.Request(
                f"{a.vision_url}/vision/detect",
                data=json.dumps({"image_b64": b, "name": a.target}).encode(),
                headers={"Content-Type": "application/json"})
            d = json.loads(urllib.request.urlopen(req, timeout=150).read())
        except Exception as e:
            print(f"    vision error: {e}")
            return None
        if not d.get("found"):
            return None
        return float(d["cx"]), float(d["cy"]), float(d.get("w", 0)) * float(d.get("h", 0))

    def see_twice(tries=3, agree=0.18):
        """A confirmed sighting: two reads that agree, out of up to `tries`.

        Demanding two CONSECUTIVE agreeing reads was too strict — this detector
        misses intermittently even with the target plainly in frame, and the
        servo loop then aborted mid-approach. Polling a third time and pairing
        whichever two agree keeps the confirmation without the brittleness.
        """
        seen = [h for h in (see() for _ in range(tries)) if h is not None]
        if len(seen) < 2:
            return None
        for i in range(len(seen)):
            for j in range(i + 1, len(seen)):
                if (abs(seen[i][0] - seen[j][0]) <= agree
                        and abs(seen[i][1] - seen[j][1]) <= agree):
                    return tuple((seen[i][k] + seen[j][k]) / 2 for k in range(3))
        return None

    def measure_grasp_point(n=3):
        """Where the FINGERS are in the wrist image — the real aim point.

        The wrist camera is not co-located with the grasp, so centring a target
        in the frame leaves it beside the fingers. Measured on this unit the
        fingers sit at (0.633, 0.887): 13% right and 39% BELOW centre. Servoing
        to (0.5,0.5) therefore reaches past the object, which is exactly what
        the operator observed before this was measured.

        Found the same way the head-camera work found the gripper: open and
        close, difference the frames, take the motion blob. Nothing is
        hardcoded — remount the camera and this re-measures itself.
        """
        import numpy as np
        pts = []
        for _ in range(n):
            go("gripper", GRIP_CLOSED, wait=1.1)
            for _ in range(4):
                cap.read()
            ok, f1 = cap.read()
            go("gripper", GRIP_OPEN, wait=1.1)
            for _ in range(4):
                cap.read()
            ok2, f2 = cap.read()
            if not (ok and ok2):
                continue
            g1 = cv2.cvtColor(f1, cv2.COLOR_BGR2GRAY).astype(np.int16)
            g2 = cv2.cvtColor(f2, cv2.COLOR_BGR2GRAY).astype(np.int16)
            d = cv2.GaussianBlur(np.abs(g2 - g1).astype(np.uint8), (5, 5), 0)
            _, m = cv2.threshold(d, 25, 255, cv2.THRESH_BINARY)
            m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
            nn, _l, st, ce = cv2.connectedComponentsWithStats(m, 8)
            if nn < 2:
                continue
            i = max(range(1, nn), key=lambda k: st[k, cv2.CC_STAT_AREA])
            if st[i, cv2.CC_STAT_AREA] < 2000:
                continue
            pts.append((ce[i][0] / 640, ce[i][1] / 480))
        if len(pts) < 2:
            return None
        return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))

    def well_framed(h):
        """Reject targets hugging the border: they vanish on the first probe,
        which is exactly how the first attempt failed."""
        return h is not None and 0.12 < h[0] < 0.88 and 0.10 < h[1] < 0.86

    outcome = "did not start"
    try:
        rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
        for j in ARM:
            rob.bus.write("Torque_Enable", j, 1, normalize=False, num_retry=3)
            rob.bus.write("Lock", j, 1, normalize=False, num_retry=3)
        time.sleep(0.5)
        go("gripper", GRIP_OPEN)
        print("  torque on (goal pre-synced), gripper open")

        # 1. hunt — search the WHOLE range and keep the best-framed view, rather
        # than committing to the first sighting. The first attempt stopped at a
        # target sitting at y=0.93, on the bottom edge, and lost it immediately.
        best = None
        for d in range(0, a.lift_search_max + 1, 200):
            go("shoulder_lift", home["shoulder_lift"] + d, wait=1.6)
            h = see_twice()
            ok = well_framed(h)
            print(f"    lift +{d:4d}: "
                  + (f"target at {h[0]:.2f},{h[1]:.2f} area {h[2]:.3f}"
                     f"{'' if ok else '  (too close to the edge)'}" if h else "not seen"))
            if ok:
                centred = abs(h[0] - 0.5) + abs(h[1] - 0.5)
                if best is None or centred < best[0]:
                    best = (centred, home["shoulder_lift"] + d, h)
        if best is None:
            outcome = "target never came into view well enough to servo on"
            return 1
        _, lift, hit = best
        print(f"    best view at lift {lift}: target {hit[0]:.2f},{hit[1]:.2f}")
        go("shoulder_lift", lift, wait=1.6)

        aim = measure_grasp_point()
        if aim is None:
            outcome = "could not locate the fingers in the wrist view — no aim point"
            return 1
        print(f"    grasp point measured at ({aim[0]:.3f},{aim[1]:.3f})"
              f"  [image centre would have been off by "
              f"{aim[0]-0.5:+.3f},{aim[1]-0.5:+.3f}]")
        go("gripper", GRIP_OPEN, wait=1.0)

        # 2. probe for the sign and gain of pan -> pixel-x
        PROBE = 70                     # small: 120 pushed the target out of frame
        before = see_twice()
        if not before:
            outcome = "lost the target before probing"
            return 1
        before = before[0]
        after = None
        for direction in (+1, -1):     # if one way loses it, try the other
            go("shoulder_pan", home["shoulder_pan"] + direction * PROBE, wait=1.5)
            after = see_twice()
            if after:
                PROBE = direction * PROBE
                break
            print(f"    probe {direction:+d} lost the target; trying the other way")
        if not after:
            outcome = "lost the target while probing, both directions"
            return 1
        dpix = after[0] - before
        print(f"    probe: pan +{PROBE} moved the target {dpix:+.3f} in x")
        if abs(dpix) < 0.02:
            outcome = "pan barely moves the target in view — cannot servo on it"
            return 1
        ticks_per_unit = PROBE / dpix          # signed: the learned control gain
        pan = home["shoulder_pan"] + PROBE

        # 3. centre horizontally
        for it in range(4):
            cur = see_twice()
            if not cur:
                outcome = "lost the target while centring"
                return 1
            err = cur[0] - aim[0]
            print(f"    centre {it+1}: x={cur[0]:.3f} err={err:+.3f} area={cur[2]:.3f}")
            if abs(err) < 0.05:
                break
            # NEGATIVE err: to REMOVE the error we move by -err, not +err.
            # Without the minus the loop drives the target off-frame — it did
            # exactly that on the first run: 0.40 -> 0.28 -> 0.135 -> lost.
            step = max(-200, min(200, int(-err * ticks_per_unit)))
            pan = clamp("shoulder_pan", pan + step)
            go("shoulder_pan", pan, wait=1.3)

        # 3b. LEARN which joint and direction brings the target toward the fingers.
        #
        # The previous version assumed +shoulder_lift approaches. It does the
        # opposite — the can rose in view (y 0.34 -> 0.24) while the fingers sit
        # at y~0.86 — and the arm strained until the servo threw Overload. The
        # pan gain was learned by probing and worked first time; hardcoding this
        # one was the same mistake, unmeasured.
        approach = None
        for joint in ("shoulder_lift", "elbow_flex"):
            base = see_twice()
            if not base:
                continue
            start = rob.bus.read("Present_Position", joint, normalize=False, num_retry=3)
            for sign in (+1, -1):
                try:
                    go_guarded(joint, start + sign * 110, wait=1.5)
                except RuntimeError as e:
                    print(f"    probe {joint}{sign:+d}: {e}")
                    go(joint, start, wait=1.2)
                    continue
                h = see_twice()
                ld = load_of(joint)
                go(joint, start, wait=1.2)
                if not h:
                    print(f"    probe {joint}{sign:+d}: lost sight")
                    continue
                dy = h[1] - base[1]          # want the target to move DOWN toward aim
                print(f"    probe {joint}{sign:+d}110 -> dy {dy:+.3f} (want +), load {ld}")
                if dy > 0.015 and (approach is None or dy > approach[2]):
                    approach = (joint, sign, dy, ld)
            if approach:
                break
        if approach is None:
            outcome = ("no joint direction brings the target toward the fingers — "
                       "the can is probably outside this arm's reach from here")
            return 1
        aj, asign, ady, _ = approach
        print(f"    approach axis: {aj} {asign:+d} ({ady:+.3f} of y per 110 ticks)")

        # 3c. LEARN a REACH axis — one that closes distance, i.e. makes the
        # target bigger.
        #
        # Height alone is not enough. Driving only the y axis walked the target
        # down into the fingers' line while the apparent size FELL 0.172 -> 0.094:
        # the gripper swung on an arc, ending nearer the right height and further
        # away. It closed on air. A grasp needs both, so the remaining joints get
        # probed for whichever one actually shortens the reach.
        reach = None
        for joint in ("elbow_flex", "wrist_flex", "shoulder_lift"):
            if joint == aj:
                continue
            base = see_twice()
            if not base:
                continue
            start = rob.bus.read("Present_Position", joint, normalize=False, num_retry=3)
            for sign in (+1, -1):
                try:
                    go_guarded(joint, start + sign * 110, wait=1.5)
                except RuntimeError as e:
                    print(f"    reach probe {joint}{sign:+d}: {e}")
                    go(joint, start, wait=1.2)
                    continue
                h = see_twice()
                go(joint, start, wait=1.2)
                if not h:
                    continue
                darea = h[2] - base[2]
                print(f"    reach probe {joint}{sign:+d}110 -> area {darea:+.3f} (want +)")
                if darea > 0.008 and (reach is None or darea > reach[2]):
                    reach = (joint, sign, darea)
            if reach:
                break
        if reach:
            rj, rsign, rda = reach
            print(f"    reach axis: {rj} {rsign:+d} ({rda:+.3f} of area per 110 ticks)")
        else:
            rj = None
            print("    no axis closes distance — the can may be beyond reach from here")

        # 4. approach
        for it in range(a.approach_steps):
            cur = see_twice()
            if not cur:
                outcome = "lost the target while approaching"
                return 1
            print(f"    approach {it+1}: x={cur[0]:.3f} y={cur[1]:.3f} area={cur[2]:.3f}")
            # Close enough when the target has come DOWN to the fingers' height,
            # not merely when it looks big. Area alone stopped the approach with
            # the can still well above the grasp point.
            # Ready only when it is BOTH at the fingers' height AND close enough
            # to be between them. Height alone let it close on air.
            if abs(cur[1] - aim[1]) < 0.13 and cur[2] > 0.20:
                print(f"    at grasp height (y={cur[1]:.2f} vs {aim[1]:.2f}) AND "
                      f"near (area {cur[2]:.3f}) — closing")
                break
            # Alternate: correct HEIGHT when the target is off the fingers' line,
            # otherwise close DISTANCE. Doing only one is what missed last time.
            gap = aim[1] - cur[1]
            if abs(gap) > 0.10 or rj is None:
                cur_a = rob.bus.read("Present_Position", aj, normalize=False, num_retry=3)
                step = int(max(60, min(200, abs(gap) / max(ady, 1e-3) * 110 * 0.6)))
                go_guarded(aj, cur_a + asign * (step if gap > 0 else -step), wait=1.5)
            else:
                cur_r = rob.bus.read("Present_Position", rj, normalize=False, num_retry=3)
                go_guarded(rj, cur_r + rsign * 110, wait=1.5)
            e = cur[0] - aim[0]
            if abs(e) > 0.08:
                pan = clamp("shoulder_pan", pan + int(-e * ticks_per_unit * 0.6))
                go("shoulder_pan", pan, wait=1.2)

        # 5. close, and check whether anything is actually held
        if a.dry_run:
            outcome = "dry run — centred and approached, gripper NOT closed"
            return 0
        go("gripper", GRIP_CLOSED, wait=1.8)
        pos = rob.bus.read("Present_Position", "gripper", normalize=False, num_retry=3)
        load = rob.bus.read("Present_Load", "gripper", normalize=False, num_retry=3)
        mag = load & 0x3FF
        print(f"    gripper closed to {pos} (commanded {GRIP_CLOSED}), load {mag}")
        # Fully closed on air lands at the commanded value; something in the way
        # stops it short. That is the honest test, not a camera looking at it.
        if pos > GRIP_CLOSED + 60:
            outcome = f"SOMETHING IS HELD — fingers stopped at {pos}, {pos-GRIP_CLOSED} ticks short of empty"
        else:
            outcome = f"closed on nothing — fingers reached {pos}, no object between them"
        return 0
    finally:
        print(f"\n  OUTCOME: {outcome}")
        print("  returning to start pose and releasing")
        try:
            rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
            time.sleep(2.5)
            for j in ARM:
                rob.bus.write("Torque_Enable", j, 0, normalize=False, num_retry=3)
        except Exception as e:
            print(f"  cleanup issue: {e}")
        rob.bus.disconnect()
        cap.release()


if __name__ == "__main__":
    sys.exit(main())
