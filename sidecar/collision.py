#!/usr/bin/env python3
"""Collision checking for the XLeRobot: joint limits are not a workspace.

Per-joint limits (see sidecar/probe_range.py and lex-robot#151) stop a joint
destroying itself. They cannot stop a perfectly legal joint configuration from
putting a gripper through the tower, because the real constraints are COUPLED —
whether the wrist hits the mast depends on shoulder_pan, shoulder_lift and
elbow_flex together, and on what the OTHER arm is doing.

Measuring the limits made this concrete: three of the "mechanical stops" found
on this robot turned out to be furniture, not mechanism — a wrist camera
meeting the cart, an arm meeting the tower column. Those stops are real but
POSTURE-DEPENDENT, so a per-joint bound derived from one of them is
conservative in the corner where it was measured and simply wrong elsewhere.

This module answers the question joint limits cannot: given a configuration of
both arms, does anything intersect?

Approach: conservative capsule approximation. Each arm link becomes a capsule
(a segment with a radius) between consecutive link origins from forward
kinematics; the tower is a vertical capsule; the cart tray is a half-space.
Capsules over-approximate the real geometry, so the model reports collisions
slightly early rather than slightly late — the correct direction to be wrong in
when the alternative is driving a servo into a mast.

Deliberately NOT using the URDF's collision meshes. They report several
self-collisions in the robot's own neutral pose (placo warns about this on
every load), so they cannot currently distinguish a real collision from the
model's own resting state. Capsules with explicit radii are cruder but honest,
and the radii are a knob you can widen.

    from collision import RobotCollisionModel
    model = RobotCollisionModel.from_json("sidecar/robot_geometry.json", urdf_path)
    hits = model.check(left_joints_deg, right_joints_deg)
    if hits: refuse the motion
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

EPS = 1e-9

# The chain of link frames each arm is built from. Consecutive pairs become
# capsules, so this ordering is the arm's physical skeleton.
ARM_FRAMES = ["base_link", "shoulder_link", "upper_arm_link", "lower_arm_link",
              "wrist_link", "gripper_link", "gripper_frame_link"]
ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll"]


# ── geometry ────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Capsule:
    """A segment with a radius — the swept volume of a sphere along a line."""
    a: tuple[float, float, float]
    b: tuple[float, float, float]
    radius: float
    name: str = ""


def point_segment_distance(p, a, b) -> float:
    p, a, b = np.asarray(p, float), np.asarray(a, float), np.asarray(b, float)
    ab = b - a
    denom = float(ab @ ab)
    if denom <= EPS:
        return float(np.linalg.norm(p - a))
    t = min(1.0, max(0.0, float((p - a) @ ab) / denom))
    return float(np.linalg.norm(p - (a + t * ab)))


def segment_segment_distance(p1, q1, p2, q2) -> float:
    """Closest approach of two finite segments (Ericson, Real-Time Collision
    Detection §5.1.9). Both segments are CLAMPED — treating them as infinite
    lines is the classic way to miss a collision at a joint's end."""
    p1, q1, p2, q2 = (np.asarray(v, float) for v in (p1, q1, p2, q2))
    d1, d2, r = q1 - p1, q2 - p2, p1 - p2
    a, e, f = float(d1 @ d1), float(d2 @ d2), float(d2 @ r)

    if a <= EPS and e <= EPS:                       # both degenerate to points
        return float(np.linalg.norm(p1 - p2))
    if a <= EPS:
        s, t = 0.0, min(1.0, max(0.0, f / e))
    else:
        c = float(d1 @ r)
        if e <= EPS:
            t, s = 0.0, min(1.0, max(0.0, -c / a))
        else:
            b = float(d1 @ d2)
            denom = a * e - b * b
            s = min(1.0, max(0.0, (b * f - c * e) / denom)) if denom > EPS else 0.0
            t = (b * s + f) / e
            if t < 0.0:
                t, s = 0.0, min(1.0, max(0.0, -c / a))
            elif t > 1.0:
                t, s = 1.0, min(1.0, max(0.0, (b - c) / a))
    return float(np.linalg.norm((p1 + d1 * s) - (p2 + d2 * t)))


def capsule_clearance(c1: Capsule, c2: Capsule) -> float:
    """Gap between two capsules. Negative means they interpenetrate."""
    return segment_segment_distance(c1.a, c1.b, c2.a, c2.b) - c1.radius - c2.radius


def capsule_plane_clearance(c: Capsule, plane_z: float) -> float:
    """Gap above a horizontal plane (the cart tray). Negative means through it."""
    return min(c.a[2], c.b[2]) - c.radius - plane_z


# ── the robot ───────────────────────────────────────────────────────────────

@dataclass
class ArmMount:
    """Where an arm's base_link sits in the shared robot frame.

    yaw_deg rotates the arm about vertical; the two arms face outward from the
    tower, so their yaws differ. THESE MUST BE MEASURED — see
    sidecar/robot_geometry.json.
    """
    position: tuple[float, float, float]
    yaw_deg: float

    def transform(self, p) -> tuple[float, float, float]:
        c, s = math.cos(math.radians(self.yaw_deg)), math.sin(math.radians(self.yaw_deg))
        x, y, z = p
        return (self.position[0] + c * x - s * y,
                self.position[1] + s * x + c * y,
                self.position[2] + z)


@dataclass
class Collision:
    a: str
    b: str
    clearance: float          # negative = interpenetrating

    def __str__(self) -> str:
        return f"{self.a} vs {self.b}: {self.clearance * 1000:+.0f} mm"


@dataclass
class RobotCollisionModel:
    mounts: dict[str, ArmMount]
    link_radii: dict[str, float]
    tower: Capsule | None
    tray_z: float | None
    margin: float = 0.01
    _fk: dict = field(default_factory=dict, repr=False)

    # -- construction --------------------------------------------------------

    @staticmethod
    def from_json(path: str, urdf_path: str) -> "RobotCollisionModel":
        g = json.loads(Path(path).read_text())
        mounts = {side: ArmMount(tuple(m["position"]), float(m["yaw_deg"]))
                  for side, m in g["arms"].items()}
        t = g.get("tower")
        tower = Capsule(tuple(t["base"]), tuple(t["top"]), float(t["radius"]), "tower") if t else None
        model = RobotCollisionModel(
            mounts=mounts, link_radii=g["link_radii"], tower=tower,
            tray_z=(g.get("cart") or {}).get("tray_z"), margin=float(g.get("margin_m", 0.01)),
        )
        model.load_kinematics(urdf_path)
        return model

    def load_kinematics(self, urdf_path: str) -> None:
        from lerobot.model.kinematics import RobotKinematics
        for frame in ARM_FRAMES:
            self._fk[frame] = RobotKinematics(urdf_path=urdf_path,
                                              target_frame_name=frame,
                                              joint_names=ARM_JOINTS)

    # -- capsules ------------------------------------------------------------

    def arm_capsules(self, side: str, joints_deg) -> list[Capsule]:
        """The arm's skeleton, in the shared robot frame."""
        q = np.asarray(joints_deg, float)[: len(ARM_JOINTS)]
        mount = self.mounts[side]
        pts = [mount.transform(tuple(self._fk[f].forward_kinematics(q)[:3, 3])) for f in ARM_FRAMES]
        out = []
        for i in range(len(ARM_FRAMES) - 1):
            seg = f"{ARM_FRAMES[i]}->{ARM_FRAMES[i+1]}"
            r = self.link_radii.get(ARM_FRAMES[i + 1], self.link_radii.get("default", 0.03))
            out.append(Capsule(pts[i], pts[i + 1], r, f"{side}:{seg}"))
        return out

    # -- the question this module exists to answer ---------------------------

    def check(self, left_joints_deg=None, right_joints_deg=None) -> list[Collision]:
        """Every violated pair, worst first. Empty means the pose is clear.

        A pair counts as colliding when clearance < margin, so the model
        refuses near-misses too — the arm should not graze the mast either.
        """
        caps: dict[str, list[Capsule]] = {}
        if left_joints_deg is not None:
            caps["left"] = self.arm_capsules("left", left_joints_deg)
        if right_joints_deg is not None:
            caps["right"] = self.arm_capsules("right", right_joints_deg)

        hits: list[Collision] = []
        for side, arm in caps.items():
            for i, c in enumerate(arm):
                if self.tower is not None and i > 0:      # base_link->shoulder is inside the mount
                    d = capsule_clearance(c, self.tower)
                    if d < self.margin:
                        hits.append(Collision(c.name, "tower", d))
                if self.tray_z is not None and i > 0:
                    d = capsule_plane_clearance(c, self.tray_z)
                    if d < self.margin:
                        hits.append(Collision(c.name, "cart tray", d))
        if "left" in caps and "right" in caps:
            # Skip each arm's first link: those are bolted down and cannot reach
            # each other, so any "collision" there is mounting geometry error.
            for c1 in caps["left"][1:]:
                for c2 in caps["right"][1:]:
                    d = capsule_clearance(c1, c2)
                    if d < self.margin:
                        hits.append(Collision(c1.name, c2.name, d))
        return sorted(hits, key=lambda h: h.clearance)
