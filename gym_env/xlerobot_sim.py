"""XLeRobot MuJoCo scene + sim core — shared by the Tier-2 sidecar and the gym env.

A physics model of the XLeRobot 0.4.0's shape: a wheeled cart (slide-x/slide-y,
velocity-actuated so the base genuinely *drives* through contacts; kinematics
follow base_mode — the 0.4.0 dual-wheel differential by default, the older
3-omni holonomic as an option) carrying two arm end-effectors
(mocap-teleoperated spheres at SO-101-ish mounting offsets — the
Cartesian-teleop shortcut the depot G1 sidecar uses, fine for governance
demos, not a real controller). The room has a counter and a cup: the cup is a
free body with mass; a grasp within tolerance activates a weld equality — a real
mechanical join, the same trick as the G1 connector seat.

Consumers:
  sidecar/xlerobot_mujoco_sidecar.py — lex-robot sidecar protocol over this sim
  gym_env/xlerobot_env.py            — Gymnasium Env over the same scene

Frames: world coordinates are metres; arm targets arrive in the ARM frame
(x forward, y lateral, z above the arm base plate — the grant's ~40 cm SO-101
reach box) and are mapped onto the world by rotating the mount by the base's
current heading, so "forward" genuinely follows the cart's nose on the
differential base and each arm keeps its last commanded arm-frame offset while
the base drives (no snap-back).
"""

from __future__ import annotations

import math
import os

import mujoco
import numpy as np

# Room: 4m x 3m floor (matches the demo's base grant), counter along the +x
# wall, a cup on the counter — reachable once the cart is close.
XML = """
<mujoco model="xlerobot_room">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="2 1.5 3" dir="0 0 -1" diffuse="0.9 0.9 0.9"/>
    <geom name="floor" type="plane" size="4 3 0.1" pos="2 1.5 0" rgba="0.25 0.27 0.25 1"/>
    <body name="counter" pos="3.4 1.0 0.4">
      <geom type="box" size="0.3 0.6 0.4" rgba="0.5 0.42 0.3 1"/>
    </body>
    <body name="cup" pos="3.15 1.0 0.86">
      <freejoint/>
      <geom type="cylinder" size="0.03 0.05" mass="0.2" rgba="0.85 0.3 0.3 1"/>
      <site name="cup_top" pos="0 0 0.05" size="0.01" rgba="1 0.6 0.6 1"/>
    </body>
    <body name="cart" pos="0.5 1.5 0.15">
      <joint name="cart_x" type="slide" axis="1 0 0" damping="8"/>
      <joint name="cart_y" type="slide" axis="0 1 0" damping="8"/>
      <geom type="box" size="0.22 0.18 0.15" mass="8" rgba="0.2 0.35 0.55 1"/>
      <site name="cart_center" pos="0 0 0" size="0.02" rgba="0.4 0.8 1 1"/>
      <camera name="head" pos="0.1 0 0.45" xyaxes="0 -1 0 0 0 1"/>
    </body>
    <body name="ee_left" mocap="true" pos="0.75 1.65 0.55">
      <geom type="sphere" size="0.03" contype="0" conaffinity="0" rgba="0.3 0.9 0.5 1"/>
      <site name="tip_left" pos="0 0 0" size="0.012" rgba="0 1 0 1"/>
    </body>
    <body name="ee_right" mocap="true" pos="0.75 1.35 0.55">
      <geom type="sphere" size="0.03" contype="0" conaffinity="0" rgba="0.9 0.8 0.3 1"/>
      <site name="tip_right" pos="0 0 0" size="0.012" rgba="1 0.9 0 1"/>
    </body>
  </worldbody>
  <actuator>
    <velocity name="drive_x" joint="cart_x" kv="60" ctrlrange="-1.5 1.5"/>
    <velocity name="drive_y" joint="cart_y" kv="60" ctrlrange="-1.5 1.5"/>
  </actuator>
  <equality>
    <weld name="grasp_left" body1="ee_left" body2="cup" active="false"/>
    <weld name="grasp_right" body1="ee_right" body2="cup" active="false"/>
  </equality>
</mujoco>
"""

# Where each arm's frame sits on the cart (cart frame: x nose-forward): forward
# of center, left/right of the midline, at the arm base plate height.
ARM_MOUNT = {"left": np.array([0.25, 0.15, 0.40]), "right": np.array([0.25, -0.15, 0.40])}
HOME_OFF = np.array([0.0, 0.0, 0.15])  # parked EE offset in the arm frame
GRASP_TOL = 0.08   # m — EE-to-cup distance that counts as "in hand"
ARRIVE_TOL = 0.03  # m — base arrival threshold

# XLeRobot 0.4.0 ships a dual-wheel DIFFERENTIAL base (no strafing); the
# 0.3.0-era kit was a 3-omni-wheel holonomic base. Default matches 0.4.0.
BASE_MODE = os.environ.get("LEX_XLE_BASE", "diff")  # "diff" | "omni"
YAW_RATE = 2.0  # rad/s — in-place turn rate for the differential base


class XLeSim:
    """Physics core: drive(), reach(), grasp(), release(), observations."""

    def __init__(self, base_mode=None):
        self.base_mode = base_mode or BASE_MODE
        self.m = mujoco.MjModel.from_xml_string(XML)
        self.d = mujoco.MjData(self.m)
        self.mocap = {a: self.m.body(f"ee_{a}").mocapid[0] for a in ("left", "right")}
        self.tip = {a: self.m.site(f"tip_{a}").id for a in ("left", "right")}
        self.weld = {a: self.m.equality(f"grasp_{a}").id for a in ("left", "right")}
        self.jx = self.m.joint("cart_x").qposadr[0]
        self.jy = self.m.joint("cart_y").qposadr[0]
        self.cup = self.m.body("cup").id
        self.heading = 0.0
        self.arm_off = {}
        self.reset()

    def reset(self):
        mujoco.mj_resetData(self.m, self.d)
        self.d.eq_active[self.weld["left"]] = 0
        self.d.eq_active[self.weld["right"]] = 0
        self.heading = 0.0
        self.arm_off = {a: HOME_OFF.copy() for a in ("left", "right")}
        for a in ("left", "right"):
            self.d.mocap_pos[self.mocap[a]] = self.world_of(a, self.arm_off[a])
        mujoco.mj_forward(self.m, self.d)
        return self.observe()

    # ---- frames ---------------------------------------------------------------
    def base_xy(self):
        return np.array([0.5 + self.d.qpos[self.jx], 1.5 + self.d.qpos[self.jy]])

    def world_of(self, arm, off):
        """Arm-frame offset (x fwd, y lateral, z above the arm base plate) →
        world position: rotate mount + offset by the base heading, translate."""
        b = self.base_xy()
        mx, my, mz = ARM_MOUNT[arm]
        lx, ly = mx + off[0], my + off[1]
        c, s = math.cos(self.heading), math.sin(self.heading)
        return np.array([b[0] + c * lx - s * ly, b[1] + s * lx + c * ly, mz + off[2]])

    def cup_pos(self):
        return self.d.xpos[self.cup].copy()

    def observe(self):
        b = self.base_xy()
        return {
            "base": {"x": float(b[0]), "y": float(b[1]), "heading": self.heading},
            "ee": {a: [float(v) for v in self.d.site_xpos[self.tip[a]]] for a in ("left", "right")},
            "cup": [float(v) for v in self.cup_pos()],
            "holding": {a: bool(self.d.eq_active[self.weld[a]]) for a in ("left", "right")},
        }

    # ---- actuation ------------------------------------------------------------
    def drive(self, x, y, speed, max_steps=None):
        """Velocity-actuated drive to (x, y): real contacts en route.

        Base kinematics follow self.base_mode: "diff" (default — XLeRobot
        0.4.0's dual-wheel differential base: turn in place toward the target
        at a bounded yaw rate, then the commanded velocity is constrained to
        the current heading, no strafing) or "omni" (the 0.3.0-era
        3-omni-wheel holonomic base: velocity straight at the target). A
        skill-level kinematic constraint, not a wheel-torque model — the skill
        surface and the grant are identical either way.

        The step budget is derived from the leg length (with turn + settle
        margin) unless max_steps is given; "reached" is reported only when the
        base actually arrived within ARRIVE_TOL — an obstructed cart that runs
        out of steps short of the target reports "stalled".
        """
        target = np.array([x, y])
        dt = self.m.opt.timestep
        if max_steps is None:
            legs = float(np.linalg.norm(target - self.base_xy()))
            max_steps = int(legs / max(speed, 1e-6) / dt * 3) + 1200  # drive + turn + settle margin
        steps = 0
        while steps < max_steps:
            b = self.base_xy()
            err = target - b
            dist = float(np.linalg.norm(err))
            if dist < ARRIVE_TOL:
                break
            bearing = math.atan2(float(err[1]), float(err[0]))
            if self.base_mode == "diff":
                # turn in place first (bounded yaw rate), drive only along heading
                turn = (bearing - self.heading + math.pi) % (2 * math.pi) - math.pi
                if abs(turn) > 0.05:
                    self.heading += math.copysign(min(abs(turn), YAW_RATE * dt), turn)
                    v = np.zeros(2)
                else:
                    self.heading = bearing
                    fwd = np.array([math.cos(self.heading), math.sin(self.heading)])
                    v = fwd * min(speed, dist * 4.0)
            else:
                self.heading = bearing
                v = err / max(dist, 1e-9) * min(speed, dist * 4.0)
            self.d.ctrl[0], self.d.ctrl[1] = float(v[0]), float(v[1])
            self._ride_arms()
            mujoco.mj_step(self.m, self.d)
            steps += 1
        self.d.ctrl[:] = 0.0
        b = self.base_xy()
        if float(np.linalg.norm(target - b)) >= ARRIVE_TOL:
            return {"outcome": "stalled",
                    "detail": f"base stopped at ({b[0]:.2f},{b[1]:.2f}) short of ({x:.2f},{y:.2f})"}
        return {"outcome": "reached",
                "detail": f"base at ({b[0]:.2f},{b[1]:.2f}) in {steps} physics steps ({self.base_mode} drive)"}

    def _ride_arms(self):
        """Each EE keeps its commanded arm-frame offset while the base moves —
        it rides the (possibly turning) cart instead of snapping to the mount."""
        for a in ("left", "right"):
            self.d.mocap_pos[self.mocap[a]] = self.world_of(a, self.arm_off[a])

    def reach(self, arm, x, y, z, steps=200):
        """Teleop the EE toward an arm-frame target; physics steps interpolate."""
        self.arm_off[arm] = np.array([x, y, z], dtype=np.float64)
        target = self.world_of(arm, self.arm_off[arm])
        for _ in range(steps):
            cur = self.d.mocap_pos[self.mocap[arm]]
            self.d.mocap_pos[self.mocap[arm]] = cur + 0.08 * (target - cur)
            mujoco.mj_step(self.m, self.d)
        tip = self.d.site_xpos[self.tip[arm]]
        return {"outcome": "reached",
                "detail": f"{arm} EE at ({tip[0]:.2f},{tip[1]:.2f},{tip[2]:.2f})"}

    def grasp(self, arm):
        """Weld the cup to the EE if within tolerance — a real mechanical join."""
        tip = self.d.site_xpos[self.tip[arm]]
        dist = float(np.linalg.norm(tip - self.cup_pos()))
        if dist > GRASP_TOL:
            return {"outcome": "stalled", "detail": f"nothing within reach (cup {dist:.3f}m away)"}
        # The weld's relpose defaults to the XML reference poses; write the
        # CURRENT relative pose so activation grips in place instead of yanking.
        eid = self.weld[arm]
        eq = self.m.eq_data[eid]
        eq[:] = 0.0
        eq[3:6] = self.cup_pos() - self.d.mocap_pos[self.mocap[arm]]  # EE frame = world (identity quat)
        eq[6:10] = self.d.xquat[self.cup]
        eq[10] = 1.0
        self.d.eq_active[eid] = 1
        mujoco.mj_forward(self.m, self.d)
        return {"outcome": "reached", "detail": f"{arm} gripper welded the cup (dist {dist:.3f}m)"}

    def render_camera(self, name="head", width=320, height=240):
        """Offscreen render of a scene camera (the 0.4.0 head cam analogue).
        Returns an HxWx3 uint8 array, or None when no GL backend is available
        (headless CI without EGL/osmesa) — callers degrade to an explicit
        error rather than fake pixels."""
        try:
            if not hasattr(self, "_renderer"):
                self._renderer = mujoco.Renderer(self.m, height, width)
            self._renderer.update_scene(self.d, camera=name)
            img = self._renderer.render()
            # A silently-black frame means the software GL stack is broken —
            # treat it the same as no renderer (honesty over fake imagery).
            return img if img.any() else None
        except Exception:
            return None

    def release(self, arm):
        was = bool(self.d.eq_active[self.weld[arm]])
        self.d.eq_active[self.weld[arm]] = 0
        return {"outcome": "reached", "detail": f"{arm} released (was_holding={was})"}
