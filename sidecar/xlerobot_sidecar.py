#!/usr/bin/env python3
"""XLeRobot 0.4.0 sidecar (dual SO-101 arms + wheeled base) for lex-robot.

Target hardware: the XLeRobot **0.4.0** (WowRobo kit / Vector-Wangel/
XLeRobot) — two 5-DOF SO-101 arms (STS3215 servos, ~40 cm reach, ~0.6–1 kg
payload per arm; 0.4.0's optional soft finray TPU fingers make the firmware
grip floor doubly appropriate) on 0.4.0's dual-wheel differential base, with
a head RGB camera (webcam / RealSense / hand-cam variants). Everything
LeRobot-native, so the hardware leg goes through LeRobot exactly like the
depot seam (depot_hw_sidecar.py). move_base is a goal-point command, so the
skill surface and grants are identical for the older 3-omni holonomic base.

This is the **transfer point** for that robot: the standard lex-robot sidecar
protocol (SIDECAR.md), plus XLeRobot's own skills:

    move_arm  {"arm":"left|right", x,y,z,rx,ry,rz}   → outcome
    grasp_arm {"arm":"left|right", "force": N}        → outcome
    move_base {"x","y","speed"}                       → outcome
    read_base {}                                      → {"x","y","heading"}
    render_qr {"payload": "..."}                       → {"ok","payload","detail"}
    scan_qr   {}                                       → {"payload","detail"?}
    show_image {"source": "path-or-http(s)-url"}        → outcome
    show_video {"source": "path-or-http(s)-url"}        → outcome
    show_url   {"url": "http(s)://..."}                 → outcome
    show_text  {"text": "..."}                          → outcome
    clear_display {}                                    → outcome

`render_qr`/`scan_qr` are the QR half of src/a2a_bootstrap.lex's stranger
handshake (two robots that don't know each other bootstrap trust from a QR
code, then verify each other's signed A2A card — see README's "Agentic
interactions" section). They work identically on every tier's `sidecar_url`,
same as every other skill here — see "QR bootstrap" below for what's
actually real on Tier 3 vs simulated on Tier 1/2.

`show_image`/`show_video`/`show_url`/`show_text`/`clear_display` are a
general-purpose sibling to `render_qr`: instead of one fixed QR image, a
kiosk browser pointed at `GET /display` can be told to show any local
file, any http(s) URL (image, video, or a full webpage via iframe), or
plain text. Unlike the arm/base/camera skills, these are **not** gated by
`LEX_ROBOT_HW` — see "Display" below for why.

Out of the box it runs as a **stub** (stdlib only, no hardware, no pip): the
base integrates kinematically toward the target, the arms report plausible
joint states, and grasp obeys an independent firmware grip floor.

Set LEX_ROBOT_HW=1 (+ the env vars in the "Real hardware" section below) to
drive the physical robot through LeRobot. **Read this first**: this backend
was written against the LeRobot / XLeRobot APIs as documented (so_follower's
SOFollower + FeetechMotorsBus + the robot_kinematic_processor IK helpers —
see SIDECAR.md), but it has not been exercised against a physical XLeRobot in
this repo's CI or by its authors — there is no hardware in the loop here to
validate against. Community XLeRobot software (the dual-wheel diff base
especially) moves fast and isn't merged upstream into lerobot, so treat this
as a **starting point to bench-test at low torque/no load**, not a
plug-and-drive certainty. If `lerobot`'s installed version doesn't match the
shapes below, connect() fails loudly with the mismatch rather than guessing.

Two layers of safety, by design (DESIGN.md §8):
  1. The Lex **grants** (one for the arms' reach box, one for the base's
     permitted floor area) already vetted the target and clamped grip force /
     base speed BEFORE the command reached this process.
  2. This sidecar independently enforces **firmware floors** — grip force
     (LEX_XLE_HARD_GRIP_N) and base speed (LEX_XLE_HARD_SPEED_MPS) — and a
     real deployment sits behind a hardware e-stop. A software grant is the
     logical boundary, never physical safety. Neither layer here does
     torque/current-based force sensing (STS3215's Present_Load register is
     read best-effort for the audit trail, see grasp_arm, but is NOT the
     pass/fail signal) — grasp success is position/settle-based. A stronger
     force-closed-loop grasp is a known gap, not a hidden one.

Run:
    python3 sidecar/xlerobot_sidecar.py                 # stub (no hardware)
    LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py  # drive the real robot

## Real hardware — environment variables

Arms (required when LEX_ROBOT_HW=1):
    LEX_XLE_LEFT_PORT / LEX_XLE_RIGHT_PORT     serial port per arm, e.g. /dev/ttyACM0
    LEX_XLE_LEFT_ID / LEX_XLE_RIGHT_ID         lerobot robot id (calibration file
                                                lookup); default xle_left / xle_right
    LEX_XLE_MAX_REL_TARGET                     optional per-step joint clamp (degrees)
                                                passed straight to SOFollowerConfig —
                                                defense in depth independent of the grant
    LEX_XLE_ARM_TIMEOUT_S / LEX_XLE_ARM_TOL_M  closed-loop reach budget (default 8 / 0.01)
    LEX_XLE_URDF_PATH                          path to the SO-101 URDF on disk — lerobot
                                                >=0.5's RobotKinematics (used for move_arm's
                                                Cartesian IK/FK) needs this explicitly; there
                                                is no bundled URDF. Get one from the SO-ARM100/
                                                XLeRobot hardware repo. Also needs `placo`
                                                (`pip install "lerobot[kinematics]"`). Unset =
                                                no Cartesian IK/FK (move_arm fails loudly).
    LEX_XLE_URDF_TARGET_FRAME                  end-effector frame name in that URDF (default
                                                "gripper_frame_link", lerobot's own default —
                                                override if your URDF names it differently)

Base — LEX_XLE_BASE=diff (default, XLeRobot 0.4.0) or =omni (0.3.0-era LeKiwi kit):
    diff:  LEX_XLE_BASE_PORT (required), LEX_XLE_BASE_LEFT_ID / _RIGHT_ID (default 1/2),
           LEX_XLE_WHEEL_RADIUS_M (default 0.05), LEX_XLE_TRACK_WIDTH_M (default 0.30)
    omni:  LEX_XLE_BASE_PORT (required), LEX_XLE_BASE_ID (default xle_base) — drives
           the real LeKiwi 3-omni-wheel base via lerobot.robots.lekiwi
    Both:  LEX_XLE_BASE_TIMEOUT_S (default 20)

Camera — up to three independent, best-effort slots ("head", "left", "right");
each is only opened if its env var is set, and a slot that fails to open
(missing device, wrong index, etc.) just stays unavailable rather than
crashing the sidecar:
    LEX_XLE_CAMERA_HEAD_INDEX   OpenCV index for the "head" camera
    LEX_XLE_CAMERA_LEFT_INDEX   OpenCV index for the "left" camera
    LEX_XLE_CAMERA_RIGHT_INDEX  OpenCV index for the "right" camera
    LEX_XLE_CAMERA_INDEX        legacy alias for LEX_XLE_CAMERA_HEAD_INDEX
                                 (used if LEX_XLE_CAMERA_HEAD_INDEX is unset)

Mic + local transcription (only imported if `listen` is actually called):
    LEX_XLE_MIC_DEVICE     sounddevice input device index/name (default: system default)
    LEX_XLE_WHISPER_MODEL  faster-whisper model name (default "base.en")

Speaker + local synthesis (only imported if `speak` is actually called):
    LEX_XLE_SPEAKER_DEVICE  sounddevice output device index/name (default: system default)
    LEX_XLE_TTS_VOICE       Kokoro voice id (default "af_heart" — see hexgrad/Kokoro-82M)
    LEX_XLE_TTS_SPEED       playback speed multiplier (default 1.0)

QR bootstrap (only imported if `render_qr`/`scan_qr` are actually called):
    LEX_XLE_QR_IMAGE_PATH     where render_qr writes the QR PNG (default
                               /tmp/xlerobot_qr.png). The XLeRobot 0.4.0 BOM has
                               no screen/e-ink/OLED, and lerobot pins
                               opencv-python-headless (no GUI window support
                               either), so "render" on Tier 3 means "write a
                               real, correct QR image to disk" — this file is
                               also fed straight into the Display mechanism
                               below, so a kiosk browser on GET /display shows
                               it automatically once a screen exists.
    LEX_XLE_QR_SCAN_TIMEOUT_S  how long scan_qr polls the head camera for a
                               decodable code before giving up (default 5)
    render_qr needs `qrcode` (`pip install "qrcode[pil]"`); scan_qr needs only
    cv2, which lerobot already pulls in as a base dependency (opencv-python-
    headless) for OpenCVCamera — no extra install for scanning.

Display (GET /display, /display/state, /display/content — always on, no
extra env vars, no extra pip installs):
    A kiosk browser (any Chromium/Firefox in fullscreen/kiosk mode, on
    whatever screen ends up attached — see docs/XLEROBOT_SETUP.md) pointed
    at `http://<sidecar-host>:8900/display` polls its state once a second
    and renders whatever show_image/show_video/show_url/show_text/
    render_qr last set: a local file (served via /display/content, MIME-
    sniffed with stdlib `mimetypes`), an http(s) URL (fetched by the
    browser itself — an image/video src, or a webpage via <iframe>), or
    plain text. Unlike move_arm/scan_qr this is **not** gated by
    LEX_ROBOT_HW: none of it needs a servo or camera, only a browser
    somewhere pointed at the URL, which this process has no way to verify
    either way — see DisplayState's docstring.
"""

import json
import math
import mimetypes
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
# Firmware floors — independent of (and behind) the Lex grant clamps.
# STS3215 servos are 30 kg·cm class; 25 N at the fingertips is already generous.
HARD_GRIP_N = float(os.environ.get("LEX_XLE_HARD_GRIP_N", "25"))
HARD_SPEED_MPS = float(os.environ.get("LEX_XLE_HARD_SPEED_MPS", "1.0"))
USE_HW = os.environ.get("LEX_ROBOT_HW", "0") == "1"
# Stub transcript for the mic (override to script voice demos offline).
CANNED_TRANSCRIPT = os.environ.get("LEX_XLE_TRANSCRIPT", "fetch the cup to the table")

# Tier-1 has no camera model at all (arms/base are position vectors, not a
# physics scene) — `locate_object` here is an explicitly-labeled canned
# lookup, not vision, so the flagship "find and fetch" demo runs at every
# tier. Real detection (color-threshold + MuJoCo ray-cast against the actual
# rendered camera image) lives in the Tier-2 sidecar (xlerobot_mujoco_sidecar.py
# -> gym_env/xlerobot_sim.py's XLeSim.locate_object).
CANNED_OBJECT_WORLD = {"cup": {"x": 0.75, "y": 0.0, "z": 0.30}}

# Same mount geometry as gym_env/xlerobot_sim.py's ARM_MOUNT — kept as a
# separate constant here rather than importing the gym_env module (Tier-1 has
# no mujoco/numpy dependency at all; see requirements.txt).
ARM_MOUNT_XY = {"left": (0.25, 0.15), "right": (0.25, -0.15)}


def _arm_frame_for(base, world):
    """Project a world position into whichever arm's frame is nearest, given
    the CURRENT base pose — the Tier-1 (no-physics) analogue of
    gym_env/xlerobot_sim.py's XLeSim.arm_frame_for."""
    c, s = math.cos(base["heading"]), math.sin(base["heading"])

    def offset_for(arm):
        mx, my = ARM_MOUNT_XY[arm]
        dx, dy = world["x"] - base["x"], world["y"] - base["y"]
        lx, ly = c * dx + s * dy, (0.0 - s) * dx + c * dy
        return lx - mx, ly - my, world["z"]

    best_arm = min(("left", "right"), key=lambda a: math.hypot(*offset_for(a)[:2]))
    ox, oy, oz = offset_for(best_arm)
    return {"arm": best_arm, "x": ox, "y": oy, "z": oz}

ARM_JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]

# XLeRobot 0.4.0 ships a dual-wheel DIFFERENTIAL base (no strafing); the
# 0.3.0-era kit was a 3-omni-wheel holonomic (LeKiwi) base. Matches the
# BASE_MODE convention in gym_env/xlerobot_sim.py so grant/skill semantics
# stay identical between sim and hardware.
BASE_MODE = os.environ.get("LEX_XLE_BASE", "diff")  # "diff" | "omni"
YAW_RATE = float(os.environ.get("LEX_XLE_YAW_RATE", "1.0"))  # rad/s in-place turn rate


# ---- pure helpers (no hardware/lerobot import — unit-testable standalone) ----

def clamp(value, lo, hi):
    return max(lo, min(hi, value))


def diff_drive_wheel_speeds(v_mps, omega_rad_s, wheel_radius_m, track_width_m):
    """Standard two-wheel differential-drive inverse kinematics.

    v_mps: forward body velocity, omega_rad_s: body angular velocity (CCW+).
    Returns (left_wheel_rad_s, right_wheel_rad_s).
    """
    left = (v_mps - omega_rad_s * track_width_m / 2.0) / wheel_radius_m
    right = (v_mps + omega_rad_s * track_width_m / 2.0) / wheel_radius_m
    return left, right


def bearing_and_turn(cur_x, cur_y, cur_heading, target_x, target_y):
    """Distance to target, bearing to target, and the signed turn (wrapped to
    [-pi, pi]) needed to face it from cur_heading. Shared by the sim's
    kinematic drive() and the real diff-drive control loop below."""
    dx, dy = target_x - cur_x, target_y - cur_y
    dist = math.hypot(dx, dy)
    bearing = math.atan2(dy, dx) if dist > 1e-9 else cur_heading
    turn = (bearing - cur_heading + math.pi) % (2 * math.pi) - math.pi
    return dist, bearing, turn


class HardwareError(RuntimeError):
    """Raised when the installed lerobot's API doesn't match what this
    sidecar expects, or hardware bring-up otherwise fails. Callers should let
    this crash the process loudly (SystemExit) rather than fall back to a
    stub silently — a robot that *looks* connected but isn't is worse than
    one that refuses to start."""


class _HwArm:
    """One SO-101 follower arm, driven through LeRobot's so_follower robot."""

    def __init__(self, side, port, robot_id, max_relative_target):
        try:
            from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
        except ImportError as e:
            raise HardwareError(
                f"lerobot's SO101Follower isn't importable ({e}). Install with "
                "`pip install \"lerobot[feetech]\"` — see SIDECAR.md."
            ) from e
        cfg_kwargs = {"port": port, "id": robot_id}
        if max_relative_target is not None:
            cfg_kwargs["max_relative_target"] = max_relative_target
        self.side = side
        self.config = SO101FollowerConfig(**cfg_kwargs)
        self.follower = SO101Follower(self.config)
        self.follower.connect(calibrate=False)
        self._kinematics = self._make_kinematics()
        self._ik = self._make_ik()

    def _make_kinematics(self):
        """Best-effort: build lerobot's placo-based RobotKinematics for this
        arm. lerobot >=0.5 no longer builds this into the robot object (it
        was `self.follower.kinematics` on 0.4.4) — the caller now has to
        supply a URDF explicitly, so this needs LEX_XLE_URDF_PATH and the
        `placo` extra (`pip install "lerobot[kinematics]"`). Returns None
        (no URDF configured, or this lerobot install's kinematics module
        doesn't match) — _make_ik/_forward_kinematics_ee degrade from there."""
        urdf_path = os.environ.get("LEX_XLE_URDF_PATH")
        if not urdf_path:
            return None
        try:
            from lerobot.model.kinematics import RobotKinematics
            target_frame = os.environ.get("LEX_XLE_URDF_TARGET_FRAME", "gripper_frame_link")
            return RobotKinematics(urdf_path=urdf_path, target_frame_name=target_frame, joint_names=ARM_JOINTS)
        except Exception:
            return None

    def _make_ik(self):
        """Best-effort: wire up LeRobot's own FK/IK processor for the arm so
        move_arm can command Cartesian (x,y,z) targets. If no kinematics
        model was built (see _make_kinematics) or the installed lerobot's IK
        module doesn't match, IK is unavailable and move_arm fails loudly
        per-call instead of silently no-op'ing."""
        if self._kinematics is None:
            return None
        try:
            from lerobot.robots.so_follower.robot_kinematic_processor import (
                InverseKinematicsEEToJoints,
            )
            return InverseKinematicsEEToJoints(kinematics=self._kinematics, motor_names=ARM_JOINTS)
        except Exception:
            return None

    def _forward_kinematics_ee(self, joints):
        """Best-effort FK for the settle check in move_to(). *joints* must be
        keyed like lerobot's own observations (f"{name}.pos" per ARM_JOINTS
        entry). Returns an (x, y, z) tuple, or None if no kinematics model is
        available or this lerobot install's FK entry point doesn't match what
        we tried — callers must degrade gracefully, not assume this always
        succeeds."""
        if self._kinematics is None:
            return None
        try:
            from lerobot.robots.so_follower.robot_kinematic_processor import (
                compute_forward_kinematics_joints_to_ee,
            )
            # compute_forward_kinematics_joints_to_ee mutates its input dict
            # in place (pops the *.pos keys, writes ee.* keys back into the
            # same object) -- pass a copy so callers keep their own dict
            # intact.
            ee = compute_forward_kinematics_joints_to_ee(dict(joints), self._kinematics, ARM_JOINTS)
            return float(ee["ee.x"]), float(ee["ee.y"]), float(ee["ee.z"])
        except Exception:
            return None

    def read_joints(self):
        obs = self.follower.get_observation()
        positions = [float(obs.get(f"{j}.pos", 0.0)) for j in ARM_JOINTS]
        return {"names": [f"{self.side}_{j}" for j in ARM_JOINTS], "positions": positions,
                "velocities": [0.0] * len(ARM_JOINTS)}

    def read_pose(self):
        obs = self.follower.get_observation()
        joints = {f"{j}.pos": obs.get(f"{j}.pos", 0.0) for j in ARM_JOINTS}
        ee = self._forward_kinematics_ee(joints)
        if ee is None:
            return {
                "ok": False,
                "detail": "no Cartesian FK available (URDF/placo not configured, or this "
                          "lerobot install's kinematics module doesn't match)",
            }
        x, y, z = ee
        return {"ok": True, "x": x, "y": y, "z": z}

    def move_to(self, x, y, z, rx, ry, rz, timeout_s, tol_m):
        if self._ik is None:
            raise HardwareError(
                "no Cartesian IK available: either LEX_XLE_URDF_PATH isn't set, `placo` "
                "isn't installed (`pip install \"lerobot[kinematics]\"`), or this lerobot "
                "install's `robot_kinematic_processor.InverseKinematicsEEToJoints` doesn't "
                "match what this sidecar expects. Fix one of those, or drive the arm in "
                "joint space."
            )
        import time as _time
        from lerobot.processor import create_transition, TransitionKey
        deadline = _time.monotonic() + timeout_s
        last_dist = None
        fk_available = True
        while _time.monotonic() < deadline:
            obs = self.follower.get_observation()
            # gripper.pos is a required field on the IK step's action dict
            # (it raises if any of the six ee.* fields is None) even though
            # move_to doesn't touch the gripper -- feed back the arm's own
            # current reading so it's a no-op passthrough, not a command.
            target = {
                "ee.x": x, "ee.y": y, "ee.z": z,
                "ee.wx": rx, "ee.wy": ry, "ee.wz": rz,
                "ee.gripper_pos": obs["gripper.pos"],
            }
            # InverseKinematicsEEToJoints is a pipeline step: it reads
            # self.transition (set by __call__, not by calling .action()
            # directly) to get at the observation, so it must be invoked as
            # ik(transition), not ik.action(...).
            transition = create_transition(observation=obs, action=target)
            joint_action = self._ik(transition)[TransitionKey.ACTION]
            self.follower.send_action(joint_action)
            _time.sleep(0.05)
            obs = self.follower.get_observation()
            joints = {f"{j}.pos": obs[f"{j}.pos"] for j in ARM_JOINTS}
            ee = self._forward_kinematics_ee(joints)
            if ee is None:
                fk_available = False
                break  # can't verify arrival on this install; degrade below
            last_dist = math.dist(ee, (x, y, z))
            if last_dist <= tol_m:
                return {"outcome": "reached",
                        "detail": f"{self.side} arm EE within {last_dist * 1000:.0f}mm of target"}
        if not fk_available:
            # No FK entry point on this lerobot install to verify arrival —
            # the IK command was sent and we waited a fixed settle window,
            # but this is a commanded, not sensor-verified, "reached".
            _time.sleep(min(0.5, timeout_s))
            return {"outcome": "reached",
                    "detail": f"{self.side} arm commanded to ({x:.2f},{y:.2f},{z:.2f}) "
                              "(no FK on this lerobot install — arrival unverified)"}
        return {"outcome": "timeout",
                "detail": f"{self.side} arm did not settle within {timeout_s}s (last dist {last_dist})"}

    def grasp(self, force_n, max_force_n):
        # Position-based close, scaled by the requested/firmware-capped force
        # as a fraction of the arm's rated max. Present_Load is read
        # best-effort for the audit trail only — see module docstring: this
        # is NOT a closed-loop force controller.
        frac = clamp(force_n / max(max_force_n, 1e-6), 0.0, 1.0)
        gripper_pos = frac * 100.0  # SO-101 gripper.pos is roughly 0 (open) .. 100 (closed)
        self.follower.send_action({"gripper.pos": gripper_pos})
        sensed = self._read_gripper_load()
        detail = f"{self.side} gripper closed at requested {force_n:.1f}N (firmware-capped)"
        if sensed is not None:
            detail += f", sensed load {sensed:.0f}"
        return {"outcome": "reached", "detail": detail}

    def release(self):
        self.follower.send_action({"gripper.pos": 0.0})
        return {"outcome": "reached", "detail": f"{self.side} released"}

    def _read_gripper_load(self):
        try:
            raw = self.follower.bus.sync_read("Present_Load", ["gripper"])
            return float(raw.get("gripper"))
        except Exception:
            return None

    def disconnect(self):
        try:
            self.follower.disconnect()
        except Exception:
            pass


class _HwDiffBase:
    """XLeRobot 0.4.0's dual-wheel differential base, driven directly over a
    Feetech motor bus in velocity mode. No canonical lerobot Robot class
    covers this base shape yet (only the 3-omni-wheel LeKiwi is upstream),
    so this talks to the bus directly — see the module docstring."""

    def __init__(self, port, left_id, right_id, wheel_radius_m, track_width_m):
        try:
            from lerobot.motors import Motor, MotorNormMode
            from lerobot.motors.feetech import FeetechMotorsBus
        except ImportError as e:
            raise HardwareError(
                f"lerobot's FeetechMotorsBus isn't importable ({e}). Install with "
                "`pip install \"lerobot[feetech]\"` — see SIDECAR.md."
            ) from e
        self.wheel_radius_m = wheel_radius_m
        self.track_width_m = track_width_m
        self.bus = FeetechMotorsBus(
            port=port,
            motors={
                "wheel_left": Motor(left_id, "sts3215", MotorNormMode.RANGE_M100_100),
                "wheel_right": Motor(right_id, "sts3215", MotorNormMode.RANGE_M100_100),
            },
        )
        self.bus.connect()
        try:
            self.bus.write("Operating_Mode", "wheel_left", 1)   # 1 == velocity/wheel mode
            self.bus.write("Operating_Mode", "wheel_right", 1)
        except Exception as e:
            raise HardwareError(f"could not set base wheels to velocity mode: {e}") from e
        # Dead-reckoning pose estimate — there is no encoder-feedback
        # localization wired here (a known gap, see SIDECAR.md); "reached" is
        # therefore a commanded-time estimate, not sensor-verified.
        self.pose = {"x": 0.0, "y": 0.0, "heading": 0.0}

    def _set_wheel_velocity(self, v_mps, omega_rad_s):
        left_w, right_w = diff_drive_wheel_speeds(v_mps, omega_rad_s, self.wheel_radius_m, self.track_width_m)
        # deg/s, matching the STS3215 velocity-mode convention used elsewhere
        # in lerobot (see lekiwi's _body_to_wheel_raw for the same unit choice).
        self.bus.sync_write("Goal_Velocity", {
            "wheel_left": math.degrees(left_w),
            "wheel_right": math.degrees(right_w),
        })

    def drive(self, x, y, speed, timeout_s):
        import time as _time
        deadline = _time.monotonic() + timeout_s
        last_t = _time.monotonic()
        arrive_tol = 0.03
        while _time.monotonic() < deadline:
            now = _time.monotonic()
            dt = now - last_t
            last_t = now
            dist, bearing, turn = bearing_and_turn(self.pose["x"], self.pose["y"], self.pose["heading"], x, y)
            if dist < arrive_tol:
                self._set_wheel_velocity(0.0, 0.0)
                return {"outcome": "reached",
                        "detail": f"base at ({self.pose['x']:.2f},{self.pose['y']:.2f}) (dead-reckoned)"}
            if abs(turn) > 0.05:
                omega = math.copysign(min(abs(turn), YAW_RATE), turn)
                self._set_wheel_velocity(0.0, omega)
                self.pose["heading"] += omega * dt
            else:
                self.pose["heading"] = bearing
                v = min(speed, dist * 4.0)
                self._set_wheel_velocity(v, 0.0)
                self.pose["x"] += v * math.cos(self.pose["heading"]) * dt
                self.pose["y"] += v * math.sin(self.pose["heading"]) * dt
            _time.sleep(0.02)
        self._set_wheel_velocity(0.0, 0.0)
        return {"outcome": "stalled",
                "detail": f"base did not reach ({x:.2f},{y:.2f}) within {timeout_s}s "
                          f"(dead-reckoned at {self.pose['x']:.2f},{self.pose['y']:.2f})"}

    def read(self):
        return dict(self.pose)

    def disconnect(self):
        try:
            self._set_wheel_velocity(0.0, 0.0)
            self.bus.disconnect()
        except Exception:
            pass


class _HwOmniBase:
    """The 0.3.0-era 3-omni-wheel base — this one *is* a canonical upstream
    lerobot robot (LeKiwi), so we drive it through that class directly rather
    than re-deriving the inverse kinematics."""

    def __init__(self, port, robot_id):
        try:
            from lerobot.robots.lekiwi import LeKiwi, LeKiwiConfig
        except ImportError as e:
            raise HardwareError(f"lerobot's LeKiwi robot isn't importable ({e}).") from e
        self.robot = LeKiwi(LeKiwiConfig(port=port, id=robot_id))
        self.robot.connect(calibrate=False)
        self.pose = {"x": 0.0, "y": 0.0, "heading": 0.0}

    def drive(self, x, y, speed, timeout_s):
        import time as _time
        deadline = _time.monotonic() + timeout_s
        last_t = _time.monotonic()
        arrive_tol = 0.03
        while _time.monotonic() < deadline:
            now = _time.monotonic()
            dt = now - last_t
            last_t = now
            dist, bearing, _turn = bearing_and_turn(self.pose["x"], self.pose["y"], self.pose["heading"], x, y)
            if dist < arrive_tol:
                self.robot.send_action({"x.vel": 0.0, "y.vel": 0.0, "theta.vel": 0.0})
                return {"outcome": "reached",
                        "detail": f"base at ({self.pose['x']:.2f},{self.pose['y']:.2f}) (dead-reckoned)"}
            v = min(speed, dist * 4.0)
            vx, vy = v * math.cos(bearing), v * math.sin(bearing)
            self.robot.send_action({"x.vel": vx, "y.vel": vy, "theta.vel": 0.0})
            self.pose["x"] += vx * dt
            self.pose["y"] += vy * dt
            self.pose["heading"] = bearing
            _time.sleep(0.02)
        self.robot.send_action({"x.vel": 0.0, "y.vel": 0.0, "theta.vel": 0.0})
        return {"outcome": "stalled", "detail": f"base did not reach ({x:.2f},{y:.2f}) within {timeout_s}s"}

    def read(self):
        return dict(self.pose)

    def disconnect(self):
        try:
            self.robot.send_action({"x.vel": 0.0, "y.vel": 0.0, "theta.vel": 0.0})
            self.robot.disconnect()
        except Exception:
            pass


class _HwCamera:
    def __init__(self, index):
        try:
            from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig
        except ImportError as e:
            raise HardwareError(f"lerobot's OpenCVCamera isn't importable ({e}).") from e
        self.camera = OpenCVCamera(OpenCVCameraConfig(index_or_path=index))
        self.camera.connect()

    def capture(self):
        """One raw HxWx3 uint8 RGB frame — shared by read_camera (JPEG-encodes
        it) and _hw_scan_qr (decodes a QR code from it)."""
        return self.camera.read()

    def read(self):
        import base64
        import io
        frame = self.capture()
        try:
            from PIL import Image
            buf = io.BytesIO()
            Image.fromarray(frame).save(buf, format="JPEG")
            jpeg_b64 = base64.b64encode(buf.getvalue()).decode()
        except ImportError:
            jpeg_b64 = ""  # frame captured but no JPEG encoder installed
        h, w = frame.shape[0], frame.shape[1]
        return {"width": int(w), "height": int(h), "jpeg_b64": jpeg_b64}

    def disconnect(self):
        try:
            self.camera.disconnect()
        except Exception:
            pass


def _hw_listen(seconds, device, model_name):
    """Record `seconds` of audio locally and transcribe with faster-whisper.
    Raw audio never leaves this process — only the transcript is returned."""
    try:
        import numpy as np
        import sounddevice as sd
    except ImportError as e:
        raise HardwareError(
            f"sounddevice/numpy not installed ({e}). `pip install sounddevice numpy`."
        ) from e
    try:
        from faster_whisper import WhisperModel
    except ImportError as e:
        raise HardwareError(f"faster-whisper not installed ({e}). `pip install faster-whisper`.") from e
    sample_rate = 16000
    kwargs = {"samplerate": sample_rate, "channels": 1, "dtype": "float32"}
    if device:
        kwargs["device"] = device
    audio = sd.rec(int(seconds * sample_rate), **kwargs)
    sd.wait()
    model = WhisperModel(model_name, device="cpu", compute_type="int8")
    segments, _info = model.transcribe(np.squeeze(audio, axis=-1), language="en")
    text = " ".join(s.text.strip() for s in segments).strip()
    return {"transcript": text, "confidence": 1.0, "seconds": seconds}


def _hw_speak(text, device, voice, speed):
    """Synthesize `text` locally with Kokoro and play it out the robot's
    speaker — the output-side mirror of _hw_listen: text goes IN to this
    process, only sound comes OUT, nothing is sent anywhere else.

    Kokoro's own model/voice weights are lazily pulled from Hugging Face Hub
    on first use (hexgrad/Kokoro-82M) and cached locally after that — the
    first real call is slow, later ones are not. Like _hw_listen's
    WhisperModel, the pipeline is (re)built on every call rather than
    cached across calls, matching that function's existing (simple, not
    optimized) shape.
    """
    try:
        import numpy as np
        import sounddevice as sd
    except ImportError as e:
        raise HardwareError(
            f"sounddevice/numpy not installed ({e}). `pip install sounddevice numpy`."
        ) from e
    try:
        from kokoro import KPipeline
    except ImportError as e:
        raise HardwareError(f"kokoro not installed ({e}). `pip install kokoro`.") from e
    sample_rate = 24000  # Kokoro's fixed output rate
    pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")  # American English
    chunks = [np.asarray(audio, dtype=np.float32) for _graphemes, _phonemes, audio in pipeline(text, voice=voice, speed=speed) if audio is not None]
    if not chunks:
        return {"outcome": "stalled", "detail": "kokoro produced no audio for the given text"}
    samples = np.concatenate(chunks)
    kwargs = {"samplerate": sample_rate, "channels": 1}
    if device:
        kwargs["device"] = device
    sd.play(samples, **kwargs)
    sd.wait()
    seconds = len(samples) / sample_rate
    return {"outcome": "reached", "detail": f"spoke {len(text)} chars ({seconds:.1f}s of audio)"}


def _hw_render_qr(payload, image_path):
    """Encode `payload` (an src/a2a_bootstrap.lex BootstrapBlob, base64url)
    as a real, scannable QR code and write it to disk. There is no display
    in the XLeRobot 0.4.0 BOM to show it on — see the module docstring's "QR
    bootstrap" section — so writing a correct image is as far as this
    sidecar goes; an attached screen picking up `image_path` is the next
    transfer point, not hidden or faked here."""
    try:
        import qrcode
    except ImportError as e:
        raise HardwareError(f'qrcode not installed ({e}). `pip install "qrcode[pil]"`.') from e
    qrcode.make(payload).save(image_path)
    return {"ok": "displayed", "payload": payload, "detail": f"QR image written to {image_path}"}


def _hw_scan_qr(camera, timeout_s):
    """Poll the head camera for a decodable QR code with OpenCV's built-in
    detector — no extra dependency (cv2 ships as a base lerobot dependency
    for OpenCVCamera itself). Polls rather than reading a single frame
    because the code being scanned is very unlikely to already be centered
    in frame the instant this is called."""
    try:
        import cv2
    except ImportError as e:
        raise HardwareError(f"cv2 not importable ({e}) — expected via lerobot's own opencv dependency.") from e
    import time as _time
    detector = cv2.QRCodeDetector()
    deadline = _time.monotonic() + timeout_s
    while True:
        frame = camera.capture()  # HxWx3 uint8 RGB
        payload, _points, _straight = detector.detectAndDecode(cv2.cvtColor(frame, cv2.COLOR_RGB2BGR))
        if payload:
            return {"payload": payload}
        if _time.monotonic() >= deadline:
            return {"payload": "", "detail": f"no QR code detected within {timeout_s}s"}
        _time.sleep(0.1)


class DisplayState:
    """What the kiosk page (GET /display) should currently show.

    Deliberately tier-independent, unlike render_qr/scan_qr: encoding text,
    serving a local file, or pointing at a URL needs no real servo or camera
    hardware at all -- the only hardware-shaped fact about "a screen" is
    whether an actual monitor with a kiosk browser is pointed at GET
    /display, and that's a deployment fact this process cannot observe or
    fake, so (unlike move_arm/scan_qr) there's no USE_HW branch here. This
    class always does the real thing; whether anyone's watching is outside
    its job.
    """

    def __init__(self):
        self.kind = "blank"  # blank | image | video | url | text
        self.content = ""  # <img>/<video> src, <iframe> src, or literal text
        self.local_path = None  # backing file for GET /display/content, if any
        self.version = 0  # bumped on every change; the kiosk page polls this

    def set_local_file(self, kind, path):
        self.local_path = path
        self.version += 1
        self.kind = kind
        # Cache-bust via the version in the query string so the kiosk page's
        # <img>/<video> tag is forced to refetch when the same path is shown
        # again with different bytes.
        self.content = f"/display/content?v={self.version}"
        return {"outcome": "reached", "detail": f"showing local {kind} file {path}"}

    def set_remote(self, kind, url):
        self.local_path = None
        self.version += 1
        self.kind = kind
        self.content = url
        return {"outcome": "reached", "detail": f"showing {kind} from {url}"}

    def set_text(self, text):
        self.local_path = None
        self.version += 1
        self.kind = "text"
        self.content = text
        return {"outcome": "reached", "detail": f"showing {len(text)} chars of text"}

    def clear(self):
        self.local_path = None
        self.version += 1
        self.kind = "blank"
        self.content = ""
        return {"outcome": "reached", "detail": "display cleared"}

    def to_json(self):
        return {"kind": self.kind, "content": self.content, "version": self.version}


# Self-contained kiosk page: no external JS/CSS, so it works on an offline
# robot. Polls /display/state once a second and only touches the DOM when
# the version actually changed. object-fit:contain (not cover) so nothing
# gets cropped -- important for a QR code shown via render_qr, still a
# reasonable default for photos/video.
DISPLAY_PAGE_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>lex-robot display</title>
<style>
  html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}
  #stage{width:100vw;height:100vh;display:flex;align-items:center;justify-content:center}
  #stage img,#stage video{max-width:100%;max-height:100%;object-fit:contain}
  #stage iframe{width:100%;height:100%;border:0}
  #stage .text{color:#fff;font:6vh/1.3 -apple-system,Helvetica,Arial,sans-serif;
               text-align:center;padding:4vw;white-space:pre-wrap}
</style></head>
<body><div id="stage"></div>
<script>
let lastVersion = -1;
function render(s) {
  const stage = document.getElementById('stage');
  stage.innerHTML = '';
  if (s.kind === 'image') {
    const el = document.createElement('img'); el.src = s.content; stage.appendChild(el);
  } else if (s.kind === 'video') {
    const el = document.createElement('video');
    el.src = s.content; el.autoplay = true; el.loop = true; el.muted = true; el.playsInline = true;
    stage.appendChild(el);
  } else if (s.kind === 'url') {
    const el = document.createElement('iframe'); el.src = s.content; stage.appendChild(el);
  } else if (s.kind === 'text') {
    const el = document.createElement('div'); el.className = 'text'; el.textContent = s.content;
    stage.appendChild(el);
  }
  // 'blank' -> stage stays empty
}
async function poll() {
  try {
    const r = await fetch('/display/state', {cache: 'no-store'});
    const s = await r.json();
    if (s.version !== lastVersion) { lastVersion = s.version; render(s); }
  } catch (e) { /* sidecar restarting/unreachable -- just retry next tick */ }
}
poll();
setInterval(poll, 1000);
</script></body></html>"""


class XLeRobot:
    """Thin wrapper around either the real hardware (arms/base/camera/mic) or
    a kinematic stub — same shape either way so handle_skill() never branches
    on USE_HW itself."""

    def __init__(self):
        self._hw_arms = {}
        self._hw_base = None
        self._hw_cameras = {}
        self.base = {"x": 0.0, "y": 0.0, "heading": 0.0}
        self.arms = {
            "left": {"positions": [0.0] * 6, "holding": False},
            "right": {"positions": [0.0] * 6, "holding": False},
        }
        # Tier-1/2 QR round trip (no display/no real camera at those tiers —
        # see render_qr/scan_qr below): last payload "shown", stashed here so
        # a scan_qr call gets back what render_qr last displayed.
        self._qr_payload = ""
        # What GET /display's kiosk page should currently show — see
        # DisplayState's docstring for why this isn't USE_HW-gated.
        self.display = DisplayState()
        if USE_HW:
            self._bring_up_hardware()

    def _bring_up_hardware(self):
        left_port = os.environ.get("LEX_XLE_LEFT_PORT")
        right_port = os.environ.get("LEX_XLE_RIGHT_PORT")
        base_port = os.environ.get("LEX_XLE_BASE_PORT")
        if not left_port or not right_port or not base_port:
            raise SystemExit(
                "LEX_ROBOT_HW=1 requires LEX_XLE_LEFT_PORT, LEX_XLE_RIGHT_PORT and "
                "LEX_XLE_BASE_PORT (serial ports for the two SO-101 arms + the base) "
                "— see SIDECAR.md."
            )
        max_rel = os.environ.get("LEX_XLE_MAX_REL_TARGET")
        max_rel = float(max_rel) if max_rel else None
        try:
            self._hw_arms["left"] = _HwArm("left", left_port, os.environ.get("LEX_XLE_LEFT_ID", "xle_left"), max_rel)
            self._hw_arms["right"] = _HwArm("right", right_port, os.environ.get("LEX_XLE_RIGHT_ID", "xle_right"), max_rel)
            if BASE_MODE == "omni":
                self._hw_base = _HwOmniBase(base_port, os.environ.get("LEX_XLE_BASE_ID", "xle_base"))
            else:
                self._hw_base = _HwDiffBase(
                    base_port,
                    int(os.environ.get("LEX_XLE_BASE_LEFT_ID", "1")),
                    int(os.environ.get("LEX_XLE_BASE_RIGHT_ID", "2")),
                    float(os.environ.get("LEX_XLE_WHEEL_RADIUS_M", "0.05")),
                    float(os.environ.get("LEX_XLE_TRACK_WIDTH_M", "0.30")),
                )
        except HardwareError as e:
            self._disconnect_partial()
            raise SystemExit(f"XLeRobot hardware bring-up failed: {e}") from e
        except BaseException:
            self._disconnect_partial()
            raise

        self._hw_cameras = {}
        camera_env_vars = {
            "head": os.environ.get("LEX_XLE_CAMERA_HEAD_INDEX", os.environ.get("LEX_XLE_CAMERA_INDEX")),
            "left": os.environ.get("LEX_XLE_CAMERA_LEFT_INDEX"),
            "right": os.environ.get("LEX_XLE_CAMERA_RIGHT_INDEX"),
        }
        for cam_name, index_str in camera_env_vars.items():
            if index_str is None:
                continue
            try:
                self._hw_cameras[cam_name] = _HwCamera(int(index_str))
            except Exception as e:
                print(f"[xlerobot] camera '{cam_name}' (index {index_str}) unavailable: {e}")

    def _disconnect_partial(self):
        """Leave nothing energized behind on a failed bring-up."""
        for a in self._hw_arms.values():
            a.disconnect()
        if self._hw_base is not None:
            self._hw_base.disconnect()
        for c in self._hw_cameras.values():
            c.disconnect()

    def reset(self):
        self.base = {"x": 0.0, "y": 0.0, "heading": 0.0}
        for a in self.arms.values():
            a["positions"] = [0.0] * 6
            a["holding"] = False
        return {"base": dict(self.base), "arms": {k: list(v["positions"]) for k, v in self.arms.items()}}

    # ---- sensing -------------------------------------------------------------
    def read_joints(self, arm):
        if USE_HW:
            return self._hw_arms[arm if arm in self._hw_arms else "left"].read_joints()
        a = self.arms.get(arm, self.arms["left"])
        return {
            "names": [f"{arm}_{j}" for j in ARM_JOINTS],
            "positions": list(a["positions"]),
            "velocities": [0.0] * 6,
        }

    def read_arm_pose(self, arm):
        if USE_HW:
            return self._hw_arms[arm if arm in self._hw_arms else "left"].read_pose()
        a = self.arms.get(arm, self.arms["left"])
        x, y, z = a["positions"][:3]
        return {"ok": True, "x": x, "y": y, "z": z}

    def read_base(self):
        if USE_HW:
            return self._hw_base.read()
        return dict(self.base)

    def read_camera(self, name):
        if USE_HW:
            cam = self._hw_cameras.get(name)
            if cam is None:
                return {"error": f"camera '{name}' not configured or unavailable"}
            return cam.read()
        return {"width": 640, "height": 480, "jpeg_b64": ""}

    def listen(self, seconds):
        if USE_HW:
            return _hw_listen(seconds, os.environ.get("LEX_XLE_MIC_DEVICE"),
                               os.environ.get("LEX_XLE_WHISPER_MODEL", "base.en"))
        return {"transcript": CANNED_TRANSCRIPT, "confidence": 1.0, "seconds": seconds}

    def speak(self, text):
        if USE_HW:
            return _hw_speak(text, os.environ.get("LEX_XLE_SPEAKER_DEVICE"),
                              os.environ.get("LEX_XLE_TTS_VOICE", "af_heart"),
                              float(os.environ.get("LEX_XLE_TTS_SPEED", "1.0")))
        # No physical speaker on Tier 1/2 (stub / physics sim) — say so rather
        # than silently doing nothing, matching locate_object's honesty
        # convention for capabilities a given tier doesn't actually have.
        return {"outcome": "reached", "detail": f"(simulated, no speaker) would say: {text}"}

    def render_qr(self, payload):
        if USE_HW:
            path = os.environ.get("LEX_XLE_QR_IMAGE_PATH", "/tmp/xlerobot_qr.png")
            result = _hw_render_qr(payload, path)
            # Feed the same file into the general display mechanism below, so
            # a kiosk browser already pointed at GET /display picks up the
            # bootstrap QR automatically instead of needing a separate path.
            self.display.set_local_file("image", path)
            return result
        # No display on Tier 1/2 either (see the module docstring) — stash
        # the payload so a paired scan_qr completes the round trip, same
        # honest-simulation convention as speak/listen at these tiers.
        self._qr_payload = payload
        return {"ok": "displayed", "payload": payload, "detail": "(simulated, no display) QR payload stored"}

    def scan_qr(self):
        if USE_HW:
            cam = self._hw_cameras.get("head")
            if cam is None:
                # Same "nothing found" outcome shape _hw_scan_qr itself
                # returns (payload/detail, no "error" key) rather than a new
                # error shape — see read_camera's "not configured" case for
                # the /skill/read_camera-side wording of the same fact.
                return {"payload": "", "detail": "camera 'head' not configured or unavailable"}
            timeout_s = float(os.environ.get("LEX_XLE_QR_SCAN_TIMEOUT_S", "5"))
            return _hw_scan_qr(cam, timeout_s)
        return {"payload": self._qr_payload}

    # ---- general-purpose display (image/video/webpage/text) --------------
    # Tier-independent (see DisplayState) — these always do the real thing,
    # whether or not USE_HW is set, because none of it needs a servo or
    # camera. A source starting with http(s):// is treated as a URL the
    # kiosk browser fetches itself; anything else is a local file path this
    # process serves over GET /display/content.
    def show_image(self, source):
        if not source:
            return {"outcome": "stalled", "detail": "show_image needs a non-empty path or URL"}
        if source.startswith("http://") or source.startswith("https://"):
            return self.display.set_remote("image", source)
        return self.display.set_local_file("image", source)

    def show_video(self, source):
        if not source:
            return {"outcome": "stalled", "detail": "show_video needs a non-empty path or URL"}
        if source.startswith("http://") or source.startswith("https://"):
            return self.display.set_remote("video", source)
        return self.display.set_local_file("video", source)

    def show_url(self, url):
        if not url:
            return {"outcome": "stalled", "detail": "show_url needs a non-empty url"}
        return self.display.set_remote("url", url)

    def show_text(self, text):
        return self.display.set_text(text)

    def clear_display(self):
        return self.display.clear()

    def locate_object(self, name):
        if USE_HW:
            # No real-camera object-detection model wired up yet — say so
            # rather than fabricating a position. Tier-2 (MuJoCo) is the only
            # tier with genuine detection today.
            return {"outcome": "not_found",
                    "detail": "real-camera object detection not implemented on Tier-3 hardware"}
        if name not in CANNED_OBJECT_WORLD:
            return {"outcome": "not_found", "detail": f"unknown object '{name}' (stub knows: cup)"}
        off = CANNED_OBJECT_WORLD[name]
        world = {"x": self.base["x"] + off["x"], "y": self.base["y"] + off["y"], "z": off["z"]}
        arm_frame = _arm_frame_for(self.base, world)
        return {
            "outcome": "found",
            "world": world,
            "arm_frame": arm_frame,
            "detail": f"'{name}' (canned Tier-1 lookup, not vision) at world "
                      f"({world['x']:.2f},{world['y']:.2f},{world['z']:.2f})",
        }

    def transform_to_arm(self, x, y, z):
        if USE_HW:
            return {"outcome": "not_found", "detail": "transform_to_arm not implemented on Tier-3 hardware"}
        world = {"x": x, "y": y, "z": z}
        return {"outcome": "found", "arm_frame": _arm_frame_for(self.base, world)}

    # ---- actuation -----------------------------------------------------------
    def move_arm(self, arm, x, y, z):
        if arm not in ("left", "right"):
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        if USE_HW:
            timeout_s = float(os.environ.get("LEX_XLE_ARM_TIMEOUT_S", "8"))
            tol_m = float(os.environ.get("LEX_XLE_ARM_TOL_M", "0.01"))
            return self._hw_arms[arm].move_to(x, y, z, 0.0, 0.0, 0.0, timeout_s, tol_m)
        a = self.arms[arm]
        a["positions"] = [round(v, 3) for v in [x, y, z, 0.0, 0.0, a["positions"][5]]]
        return {"outcome": "reached", "detail": f"{arm} arm EE at ({x:.2f},{y:.2f},{z:.2f})"}

    def grasp_arm(self, arm, force):
        if force > HARD_GRIP_N:
            return {"outcome": "stalled", "detail": f"grip {force:.0f}N exceeds firmware limit {HARD_GRIP_N:.0f}N"}
        if arm not in ("left", "right"):
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        if USE_HW:
            return self._hw_arms[arm].grasp(force, HARD_GRIP_N)
        a = self.arms[arm]
        a["holding"] = True
        a["positions"][5] = 1.0
        return {"outcome": "reached", "detail": f"{arm} gripper closed at {force:.1f}N (firmware-capped)"}

    def release_arm(self, arm):
        if arm not in ("left", "right"):
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        if USE_HW:
            return self._hw_arms[arm].release()
        a = self.arms[arm]
        was = a["holding"]
        a["holding"] = False
        a["positions"][5] = 0.0
        return {"outcome": "reached", "detail": f"{arm} released (was_holding={was})"}

    def move_base(self, x, y, speed):
        v = min(speed, HARD_SPEED_MPS)
        if USE_HW:
            timeout_s = float(os.environ.get("LEX_XLE_BASE_TIMEOUT_S", "20"))
            result = self._hw_base.drive(x, y, v, timeout_s)
            self.base = self._hw_base.read()
            return result
        dx, dy = x - self.base["x"], y - self.base["y"]
        dist = math.hypot(dx, dy)
        self.base["x"], self.base["y"] = round(x, 3), round(y, 3)
        self.base["heading"] = round(math.atan2(dy, dx), 3) if dist > 1e-9 else self.base["heading"]
        return {
            "outcome": "reached",
            "detail": f"base at ({x:.2f},{y:.2f}) after {dist:.2f}m at {v:.2f}m/s (firmware-capped)",
        }


ROBOT = XLeRobot()


def handle_skill(name, args):
    if name == "reset":
        return ROBOT.reset()
    if name == "read_joints":
        return ROBOT.read_joints(args.get("arm", "left"))
    if name == "read_arm_pose":
        return ROBOT.read_arm_pose(args.get("arm", "left"))
    if name == "read_base":
        return ROBOT.read_base()
    if name == "read_camera":
        return ROBOT.read_camera(args.get("name", "head"))
    if name == "listen":
        return ROBOT.listen(int(args.get("seconds", 3)))
    if name == "speak":
        return ROBOT.speak(args.get("text", ""))
    if name == "render_qr":
        return ROBOT.render_qr(args.get("payload", ""))
    if name == "scan_qr":
        return ROBOT.scan_qr()
    if name == "show_image":
        return ROBOT.show_image(args.get("source", ""))
    if name == "show_video":
        return ROBOT.show_video(args.get("source", ""))
    if name == "show_url":
        return ROBOT.show_url(args.get("url", ""))
    if name == "show_text":
        return ROBOT.show_text(args.get("text", ""))
    if name == "clear_display":
        return ROBOT.clear_display()
    if name == "move_arm":
        return ROBOT.move_arm(args.get("arm", "left"), float(args.get("x", 0.2)),
                              float(args.get("y", 0.0)), float(args.get("z", 0.2)))
    if name == "grasp_arm":
        return ROBOT.grasp_arm(args.get("arm", "left"), float(args.get("force", 10.0)))
    if name == "release_arm":
        return ROBOT.release_arm(args.get("arm", "left"))
    if name == "move_base":
        return ROBOT.move_base(float(args.get("x", 0.0)), float(args.get("y", 0.0)),
                               float(args.get("speed", 0.3)))
    if name == "locate_object":
        return ROBOT.locate_object(args.get("name", ""))
    if name == "transform_to_arm":
        return ROBOT.transform_to_arm(float(args.get("x", 0.0)), float(args.get("y", 0.0)), float(args.get("z", 0.0)))
    return {"error": f"unknown skill: {name}"}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        # Compact (no space after ':') to match sim_sidecar.py and satisfy
        # a2a_bootstrap.lex's strict jstr (its receive_qr parses this response
        # directly, unlike sense.lex's jstr which is written to tolerate
        # either spacing via str.trim — see that module's jstr comment).
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, code, content_type, body):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return None

    def do_POST(self):
        args = self._body()
        if args is None:
            return self._send(400, {"error": "invalid json"})
        if self.path.startswith("/skill/"):
            return self._send(200, handle_skill(self.path[len("/skill/"):], args))
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._send(200, {"ok": True, "hardware": USE_HW, "base": ROBOT.base})
        if path == "/display":
            return self._send_bytes(200, "text/html; charset=utf-8", DISPLAY_PAGE_HTML.encode())
        if path == "/display/state":
            return self._send(200, ROBOT.display.to_json())
        if path == "/display/content":
            return self._serve_display_content()
        return self._send(404, {"error": "not found"})

    def _serve_display_content(self):
        # Backs GET /display's <img>/<video> tag when show_image/show_video/
        # render_qr set a *local* file (an http(s):// source is fetched by
        # the browser directly and never routes through here). Same "no auth,
        # localhost only" model as every other route in this protocol
        # (SIDECAR.md) -- whatever process can reach this port can already
        # call any skill, so serving back whichever local file was last
        # explicitly set isn't a new trust boundary, just a new shape of it.
        local_path = ROBOT.display.local_path
        if not local_path or not os.path.isfile(local_path):
            return self._send(404, {"error": "no local display content set"})
        content_type = mimetypes.guess_type(local_path)[0] or "application/octet-stream"
        with open(local_path, "rb") as f:
            body = f.read()
        return self._send_bytes(200, content_type, body)

    def log_message(self, *a):
        print("[xlerobot]", self.command, self.path)


def main():
    mode = "REAL HARDWARE" if USE_HW else "stub (no hardware)"
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"lex-robot XLeRobot sidecar [{mode}] on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
