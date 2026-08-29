#!/usr/bin/env python3
"""Two-camera grasp: the head camera judges the reach, the wrist camera the grasp.

WHY TWO

A wrist camera alone can only judge distance by how big the target looks, which
is weak and ambiguous — a single-camera run brought the can to the right height
while apparent size fell 0.176 -> 0.036, i.e. steadily FURTHER away, and closed
on air. It read as a servo bug. It was not.

The head camera sees the gripper AND the target in one frame, so it measures the
reach error DIRECTLY. Measured on this unit: gripper (0.569,0.793), can
(0.570,0.550) — dx +0.001, dy -0.243. The horizontal alignment was already
perfect and the whole error was vertical, which no amount of wrist-camera work
could have revealed.

So: head camera closes the gap, wrist camera does the last centimetres where the
target fills its view and the head's line of sight is worst.

NOTHING IS HARDCODED

  The gripper is located by opening and closing it and differencing frames —
  in EITHER camera. No marker, no printer, no model. 0.1 px repeatable.
  The grasp point in the wrist view is measured the same way, because the
  fingers are not at the image centre (they sit near 0.64, 0.87).
  The image Jacobian is learned by probing two joints and measuring where the
  gripper went. Direction, gain and sign all come from the robot, so a
  remounted camera or a different arm re-derives itself.

An earlier version hardcoded the approach direction and got it backwards; the
probed axes have been right every time.

SAFETY

Goal is synced to present before torque, so engaging cannot snap. Every move is
clamped to the calibrated travel limits, and load is read after each one and
refused at 620/1023 — the previous attempt ended with the servo itself raising
"Overload error!", which this keeps ahead of. The arm returns home and releases
on every exit path.
"""
import argparse
import base64
import json
import os
import pathlib
import sys
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "sidecar"))

ARM = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]
PORT = "/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00"
HEAD_CAM, WRIST_CAM = 4, 2
CAL = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration/robots/so_follower/xle_left.json"
GRIP_OPEN, GRIP_CLOSED = 2900, 2100
MARGIN, LOAD_WARN, LOAD_ABORT = 60, 380, 620
# Candidates for the servo pair. Which two get used is CHOSEN BY PROBING, not
# fixed: the first version hardcoded (shoulder_pan, shoulder_lift) and stalled
# because shoulder_pan draws ~990/1023 at this extension. Probing every
# candidate and keeping the best-conditioned pair of the ones that actually
# move without straining is the same "measure, do not assume" rule that fixed
# the approach direction and the aim point.
SERVO_CANDIDATES = ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--target", default="beer can")
    p.add_argument("--vision-url",
                   default=os.environ.get("LEX_XLE_VISION_URL", "http://127.0.0.1:8901"))
    p.add_argument("--head-pan", type=int, default=1097)
    p.add_argument("--head-tilt", type=int, default=3300)
    p.add_argument("--reach-pose", type=int, default=1200,
                   help="shoulder_lift ticks above rest, to get the gripper into view")
    p.add_argument("--head-steps", type=int, default=8)
    p.add_argument("--gap-ok", type=float, default=0.06,
                   help="head-view gap counted as 'within grasping range'")
    p.add_argument("--wrist-down", type=int, default=250,
                   help="ticks to pitch the wrist down before aligning (0 to skip)")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()

    import cv2
    import numpy as np
    import tower
    from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig

    cal = json.loads(CAL.read_text()) if CAL.is_file() else {}
    cams = {}
    for name, idx in (("head", HEAD_CAM), ("wrist", WRIST_CAM)):
        c = cv2.VideoCapture(idx, cv2.CAP_V4L2)
        c.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        c.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        c.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        for _ in range(6):
            c.read()
        cams[name] = c

    rob = SO101Follower(SO101FollowerConfig(port=PORT, id="xle_left"))
    rob.bus.connect()
    twr = tower.TowerDriver(shared_bus=rob.bus, pan_limits=(347, 3747),
                            tilt_limits=(2523, 3400))
    home = rob.bus.sync_read("Present_Position", normalize=False, num_retry=3)
    tw0 = twr.read()

    def clamp(j, v):
        c = cal.get(j)
        return int(v) if not c else int(max(c["range_min"] + MARGIN,
                                            min(c["range_max"] - MARGIN, v)))

    def load_of(j):
        return rob.bus.read("Present_Load", j, normalize=False, num_retry=3) & 0x3FF

    def pos_of(j):
        return rob.bus.read("Present_Position", j, normalize=False, num_retry=3)

    def go(j, v, wait=1.3, guard=True):
        rob.bus.write("Goal_Position", j, clamp(j, v), normalize=False, num_retry=3)
        time.sleep(wait)
        if guard:
            ld = load_of(j)
            if ld >= LOAD_ABORT:
                raise RuntimeError(f"{j} load {ld} — refusing before it overloads")
            if ld >= LOAD_WARN:
                print(f"      (load {j}={ld})")
        return pos_of(j)

    def frame(which):
        for _ in range(4):
            cams[which].read()
        ok, f = cams[which].read()
        return f if ok else None

    last_grip = {}

    def find_gripper(which, near=None, max_jump=0.25):
        """Locate the gripper in EITHER camera by open/close differencing.

        `near` rejects a blob that has leapt across the frame. Without it one
        probe reported the gripper moving 0.5 of the frame for a 98-tick nudge
        (a plausible 0.03 in the run before), because the largest motion blob
        was something else entirely — a hand, a reflection — and the servo then
        lost tracking completely.
        """
        go("gripper", GRIP_CLOSED, wait=1.1, guard=False)
        f1 = frame(which)
        go("gripper", GRIP_OPEN, wait=1.1, guard=False)
        f2 = frame(which)
        if f1 is None or f2 is None:
            return None
        g1 = cv2.cvtColor(f1, cv2.COLOR_BGR2GRAY).astype(np.int16)
        g2 = cv2.cvtColor(f2, cv2.COLOR_BGR2GRAY).astype(np.int16)
        d = cv2.GaussianBlur(np.abs(g2 - g1).astype(np.uint8), (5, 5), 0)
        _, m = cv2.threshold(d, 25, 255, cv2.THRESH_BINARY)
        m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
        n, _l, st, ce = cv2.connectedComponentsWithStats(m, 8)
        if n < 2:
            return None
        ref = near if near is not None else last_grip.get(which)
        cands = [k for k in range(1, n) if st[k, cv2.CC_STAT_AREA] >= 300]
        if not cands:
            return None
        if ref is not None:
            cands = [k for k in cands
                     if np.linalg.norm(np.array([ce[k][0] / 640, ce[k][1] / 480]) - ref)
                     <= max_jump] or None
            if cands is None:
                return None
        i = max(cands, key=lambda k: st[k, cv2.CC_STAT_AREA])
        pt = np.array([ce[i][0] / 640, ce[i][1] / 480])
        last_grip[which] = pt
        return pt

    def find_target(which, tries=3):
        """Locate the target via the vision service; two agreeing reads of three."""
        seen = []
        for _ in range(tries):
            f = frame(which)
            if f is None:
                continue
            b = base64.b64encode(cv2.imencode(".jpg", f)[1].tobytes()).decode()
            try:
                req = urllib.request.Request(
                    f"{a.vision_url}/vision/detect",
                    data=json.dumps({"image_b64": b, "name": a.target}).encode(),
                    headers={"Content-Type": "application/json"})
                d = json.loads(urllib.request.urlopen(req, timeout=150).read())
            except Exception:
                continue
            if d.get("found"):
                seen.append(np.array([float(d["cx"]), float(d["cy"])]))
        for i in range(len(seen)):
            for j in range(i + 1, len(seen)):
                if np.abs(seen[i] - seen[j]).max() <= 0.18:
                    return (seen[i] + seen[j]) / 2
        return None

    outcome = "did not start"
    try:
        rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
        for j in ARM:
            rob.bus.write("Torque_Enable", j, 1, normalize=False, num_retry=3)
            rob.bus.write("Lock", j, 1, normalize=False, num_retry=3)
        time.sleep(0.5)
        go("gripper", GRIP_OPEN, guard=False)
        go("shoulder_lift", home["shoulder_lift"] + a.reach_pose, wait=2.5)
        # Point the fingers DOWN before aligning. The loop was matching WHERE the
        # gripper is while ignoring which way it FACES, so it arrived beside the
        # can with the fingers pointing along it rather than over it. Which
        # wrist_flex direction is "down" is probed, not assumed: the one that
        # moves the wrist camera's view toward the floor moves distant scene
        # content UP the frame.
        if a.wrist_down:
            w0 = pos_of("wrist_flex")
            base_view = frame("wrist")
            best_dir, best_shift = None, 0.0
            for sign in (+1, -1):
                try:
                    landed = go("wrist_flex", w0 + sign * 150, wait=1.6)
                except RuntimeError as e:
                    print(f"    wrist probe {sign:+d}: {e}")
                    go("wrist_flex", w0, wait=1.3, guard=False)
                    continue
                if abs(landed - w0) < 30:
                    go("wrist_flex", w0, wait=1.3, guard=False)
                    continue
                v = frame("wrist")
                go("wrist_flex", w0, wait=1.3, guard=False)
                if base_view is None or v is None:
                    continue
                g1 = cv2.cvtColor(base_view, cv2.COLOR_BGR2GRAY).astype(np.float32)
                g2 = cv2.cvtColor(v, cv2.COLOR_BGR2GRAY).astype(np.float32)
                win = cv2.createHanningWindow((g1.shape[1], g1.shape[0]), cv2.CV_32F)
                (_dx, dy), _r = cv2.phaseCorrelate(g1 * win, g2 * win)
                per = dy / (landed - w0)
                print(f"    wrist probe {sign:+d}: moved {landed-w0:+d}, view shifted "
                      f"dy {dy:+.1f}px")
                if -per > best_shift:          # scene UP the frame == camera pitched DOWN
                    best_shift, best_dir = -per, landed - w0
            if best_dir:
                tilt_to = w0 + int(np.sign(best_dir) * a.wrist_down)
                print(f"    tilting wrist down by {a.wrist_down} ticks "
                      f"({np.sign(best_dir):+.0f} direction)")
                try:
                    go("wrist_flex", tilt_to, wait=2.0)
                except RuntimeError as e:
                    print(f"    wrist tilt limited: {e}")
            else:
                print("    could not establish which way tilts the wrist down")

        twr.hold()
        twr.move_to(pan_ticks=a.head_pan, tilt_ticks=a.head_tilt)
        time.sleep(1.5)
        print(f"  arm at reach pose; head at pan {a.head_pan} tilt {a.head_tilt}")

        # ── PHASE 1: head camera closes the reach gap ────────────────────────
        grip = find_gripper("head")
        tgt = find_target("head")
        if grip is None or tgt is None:
            outcome = (f"head view cannot see both "
                       f"(gripper={'ok' if grip is not None else 'no'}, "
                       f"target={'ok' if tgt is not None else 'no'})")
            return 1
        print(f"  head: gripper {grip.round(3)}  target {tgt.round(3)}  "
              f"gap {np.linalg.norm(tgt-grip):.3f}")

        # Learn the 2x2 image Jacobian: how each joint moves the GRIPPER in view.
        # Probing beats assuming — a hardcoded approach direction was backwards.
        PROBE = 100
        measured = {}
        for j in SERVO_CANDIDATES:
            for sign in (+1, -1):
                start = pos_of(j)
                try:
                    landed = go(j, start + sign * PROBE, wait=1.6)
                except RuntimeError as e:
                    print(f"    probe {j}{sign:+d}: {e}")
                    go(j, start, wait=1.3, guard=False)
                    continue
                # Use the ACTUAL movement, never the commanded delta. elbow_flex
                # sits at 3046 with a clamped ceiling of 2997, so a commanded
                # +100 became a real -49 — and dividing by +100 gave a gain with
                # the wrong magnitude AND the wrong sign. The elbow looked
                # useless when in fact it helps, downward, with 2101 ticks spare.
                actual = landed - start
                g2 = find_gripper("head")
                ld = load_of(j)
                go(j, start, wait=1.3, guard=False)
                if abs(actual) < 20:
                    print(f"    probe {j}{sign:+d}: clamped (moved {actual}) — "
                          f"no travel this way")
                    continue
                if g2 is None:
                    continue
                col = (g2 - grip) / actual
                if np.linalg.norm(col) > 1e-6:
                    measured[j] = (col, ld)
                    print(f"    probe {j}: commanded {sign*PROBE:+d}, MOVED {actual:+d} "
                          f"-> gripper {(g2-grip).round(3)}  load {ld}")
                break
        if len(measured) < 2:
            outcome = (f"only {len(measured)} joint(s) can move the gripper without "
                       "straining — cannot solve a 2-D correction")
            return 1
        # Best pair = most independent directions, tie-broken toward lighter load.
        # A pair whose columns point the same way is singular: it can only push
        # the gripper along one line, and the solve blows up.
        best = None
        names = list(measured)
        for i in range(len(names)):
            for k in range(i + 1, len(names)):
                A, B = measured[names[i]], measured[names[k]]
                M = np.column_stack([A[0], B[0]])
                # Condition number, not raw determinant: a pair where one joint
                # barely moves the gripper is near-singular, and solving through
                # it produced steps so small every one was skipped.
                sv = np.linalg.svd(M, compute_uv=False)
                cond = sv[0] / sv[-1] if sv[-1] > 0 else 1e12
                if cond > 40:
                    continue
                score = abs(np.linalg.det(M)) / (1 + (A[1] + B[1]) / 2000.0)
                if best is None or score > best[0]:
                    best = (score, [names[i], names[k]], M)
        if best is None:
            outcome = ("no pair of joints moves the gripper independently enough "
                       "to servo on (all candidate pairs ill-conditioned)")
            return 1
        _, usable, Jm = best
        if abs(np.linalg.det(Jm)) < 1e-9:
            outcome = "no two joints move the gripper independently — Jacobian singular"
            return 1
        print(f"    chose {usable} (det {np.linalg.det(Jm):.3e}) from "
              f"{len(measured)} usable axes")

        stalled = 0
        for step in range(a.head_steps):
            grip = find_gripper("head")
            tgt = find_target("head")
            if grip is None or tgt is None:
                outcome = "lost the gripper or the target in the head view"
                return 1
            err = tgt - grip
            gap = float(np.linalg.norm(err))
            print(f"  head step {step+1}: gap {gap:.3f} (dx {err[0]:+.3f} dy {err[1]:+.3f})")
            if gap < a.gap_ok:
                print("    within grasping range — handing over to the wrist camera")
                break
            dq = np.linalg.solve(Jm, err)                       # ticks per joint
            # Move a FIXED distance along the solved direction rather than
            # scaling the raw solution: with an ill-conditioned Jacobian the raw
            # dq is enormous, scaling it down drove every joint below the 8-tick
            # minimum, and the loop sat still for eight iterations.
            biggest = float(np.abs(dq).max())
            if biggest < 1e-9:
                outcome = "solved correction is zero — nothing to do"
                return 1
            dq = dq / biggest * min(130.0, biggest)
            applied = 0
            for j, d in zip(usable, dq):
                if abs(d) < 8:
                    continue
                try:
                    go(j, pos_of(j) + int(d), wait=1.5)
                    applied += 1
                except RuntimeError as e:
                    print(f"    {e}")
            if applied == 0:
                stalled += 1
                if stalled >= 2:
                    outcome = (f"cannot close the last {gap:.3f} of head-view gap — "
                               "every joint that would help is at its load or travel "
                               "limit. The target is out of reach from here.")
                    return 1
            else:
                stalled = 0

        # ── PHASE 2: wrist camera does the grasp ─────────────────────────────
        aim = find_gripper("wrist")
        if aim is None:
            outcome = "cannot see the fingers in the wrist view — no aim point"
            return 1
        print(f"  wrist: grasp point at {aim.round(3)}")
        go("gripper", GRIP_OPEN, guard=False)
        for step in range(4):
            can = find_target("wrist")
            if can is None:
                outcome = "target not visible in the wrist view for the final alignment"
                return 1
            err = can - aim
            print(f"  wrist step {step+1}: err dx {err[0]:+.3f} dy {err[1]:+.3f}")
            if abs(err[0]) < 0.07 and abs(err[1]) < 0.14:
                break
            dq = np.linalg.solve(Jm, err * np.array([1.0, 1.0]))
            for j, d in zip(usable, dq * 0.5):
                if abs(d) < 8:
                    continue
                try:
                    go(j, pos_of(j) + int(max(-120, min(120, d))), wait=1.4)
                except RuntimeError as e:
                    print(f"    {e}")

        if a.dry_run:
            outcome = "dry run — aligned by both cameras, gripper NOT closed"
            return 0
        go("gripper", GRIP_CLOSED, wait=2.0, guard=False)
        pos = pos_of("gripper")
        outcome = (f"SOMETHING IS HELD — fingers stopped at {pos}, "
                   f"{pos - GRIP_CLOSED} ticks short of empty"
                   if pos > GRIP_CLOSED + 60 else
                   f"closed on nothing — fingers reached {pos}")
        return 0
    finally:
        print(f"\n  OUTCOME: {outcome}")
        try:
            twr.move_to(pan_ticks=tw0["pan_ticks"], tilt_ticks=tw0["tilt_ticks"])
            rob.bus.sync_write("Goal_Position", home, normalize=False, num_retry=3)
            time.sleep(2.5)
            for j in ARM:
                rob.bus.write("Torque_Enable", j, 0, normalize=False, num_retry=3)
            print("  arm home and released; tower restored")
        except Exception as e:
            print(f"  cleanup issue: {e}")
        twr.close()
        rob.bus.disconnect()
        for c in cams.values():
            c.release()


if __name__ == "__main__":
    sys.exit(main())
