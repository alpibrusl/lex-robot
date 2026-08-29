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
    read_base {}                                      → { "ok": bool, "x","y","heading", "wheel_temps_c"?, "detail"? }
    read_arm_pose {"arm":"left|right"}                → { "ok": bool, "x","y","z", "detail"? }
    read_grant {}                                      → { "ok": bool, "arms","grippers" }
    render_qr {"payload": "..."}                       → {"ok","payload","detail"}
    scan_qr   {}                                       → {"payload","detail"?}
    show_image {"source": "path-or-http(s)-url"}        → outcome
    show_video {"source": "path-or-http(s)-url"}        → outcome
    show_url   {"url": "http(s)://..."}                 → outcome
    show_text  {"text": "..."}                          → outcome
    show_report {"source","items","caption"?}           → outcome
    show_prompt {"question","options":["...", ...]}     → outcome
    read_touch  {}                                      → {"option": "...", "detail"?}
    clear_display {}                                    → outcome
    detect_object {"name": "..."}                       → {"found","cx","cy","w","h","confidence","detail"}

`render_qr`/`scan_qr` are the QR half of src/a2a_bootstrap.lex's stranger
handshake (two robots that don't know each other bootstrap trust from a QR
code, then verify each other's signed A2A card — see README's "Agentic
interactions" section). They work identically on every tier's `sidecar_url`,
same as every other skill here — see "QR bootstrap" below for what's
actually real on Tier 3 vs simulated on Tier 1/2.

`show_image`/`show_video`/`show_url`/`show_text`/`show_report`/
`clear_display` are a general-purpose sibling to `render_qr`: instead of
one fixed QR image, a kiosk browser pointed at `GET /display` can be told
to show any local file, any http(s) URL (image, video, or a full webpage
via iframe), plain text, or `show_report` (a picture PLUS a findings
list shown together — for "here's what I saw" moments a single image or
text block can't express, e.g. `src/skills.lex`'s `list_visible_items` +
`show_report` pair). Unlike the arm/base/camera skills, these are **not**
gated by `LEX_ROBOT_HW` — see "Display" below for why.

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

Arms (at least ONE required when LEX_ROBOT_HW=1 — each slot is optional so a
partial build runs during bring-up or as a single-arm robot; a missing arm's
skills return an honest error rather than falling through to the other arm):
    LEX_XLE_LEFT_PORT / LEX_XLE_RIGHT_PORT     serial port per arm, e.g. /dev/ttyACM0
    LEX_XLE_LEFT_ID / LEX_XLE_RIGHT_ID         lerobot robot id (calibration file
                                                lookup); default xle_left / xle_right
    LEX_XLE_MAX_REL_TARGET                     optional per-step joint clamp (degrees)
                                                passed straight to SOFollowerConfig —
                                                defense in depth independent of the grant
    LEX_XLE_ARM_TIMEOUT_S / LEX_XLE_ARM_TOL_M  closed-loop reach budget (default 8 / 0.01)
    LEX_XLE_COLLISION=0                        disable the collision pre-check (default on)
    LEX_XLE_GEOMETRY_PATH                      where the arms/tower/cart actually are
                                                (default sidecar/robot_geometry.json) — move_arm
                                                refuses a pose that collides, which joint limits
                                                cannot catch since the constraint is coupled
    LEX_XLE_STALL_ERROR_DEG / _STALL_CONFIRM   when a joint that stops tracking counts as
                                                blocked rather than slow (default 8 deg / 3)
    LEX_XLE_GRIPPER_OPEN_PCT / _CLOSED_PCT     which end of the gripper's normalized range is
                                                open vs shut (default 0/100). This follows from
                                                CALIBRATION, not from the SO-101: on a unit
                                                calibrated the other way, the defaults make
                                                `release` close the gripper.
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

Grant enforcement (all tiers, not just LEX_ROBOT_HW=1 — see SIDECAR.md
"Grant enforcement" for why this exists):
    LEX_XLE_GRANT_PATH                         path to a grant capsule JSON (default
                                                manifests/xlerobot.capsule.json). move_arm
                                                is denied outright outside the arm's
                                                workspace_m box; grasp_arm's force is clamped
                                                to the gripper's max_grip_force_n. Unset or
                                                unreadable = no enforcement (best-effort, like
                                                everything else optional in this file).

Base — LEX_XLE_BASE=diff (default, XLeRobot 0.4.0) or =omni (0.3.0-era LeKiwi kit):
    diff:  LEX_XLE_BASE_PORT (a dedicated serial port for the base) OR
           LEX_XLE_BASE_SHARED_ARM=left|right (the wheels share that arm's
           own bus instead — mutually exclusive with LEX_XLE_BASE_PORT; see
           SIDECAR.md's servo-bus-layout note for when this applies),
           LEX_XLE_BASE_LEFT_ID / _RIGHT_ID (default 1/2),
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

Split-compute vision (`detect_object` — see deploy/VISION_SPLIT.md):
    LEX_XLE_VISION_URL        base URL of a running sidecar/vision_service.py
                               (e.g. http://mac-studio.local:8901). When set,
                               detect_object captures a head-camera frame and
                               sends it there for judgment — the camera read
                               stays on the robot; only the already-captured
                               JPEG crosses the LAN (the same [net]-judgment
                               posture as list_visible_items). When unset:
                               Tier-3 says so honestly; the Tier-1 stub falls
                               back to an explicitly-labeled canned detection
                               (same convention as locate_object).
    LEX_XLE_VISION_TIMEOUT_S  per-call budget (default 15)

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

Touch (POST /display/touch — the display's one INPUT path):
    `show_prompt` puts a question plus large tap targets on the kiosk page;
    a tap POSTs {"option","version"} back here, and `read_touch` hands the
    tapped option to the governed program — the touchscreen's input layer
    as a granted capability, the same posture `listen` takes for the mic.
    A tap is only accepted while ITS prompt is still showing (kind and
    version are checked), and each prompt holds at most one answer: a new
    show_prompt discards any unread tap, so a stale answer can never leak
    into a newer question. On the Tier-1 stub, when no real tap is pending,
    read_touch answers with a canned tap so the demos run headless:
    LEX_XLE_TOUCH   which option the canned tap picks (default: the
                    prompt's first option; must match one of the options
                    or read_touch honestly reports the mismatch)
    A real tap always wins over the canned one — a browser pointed at the
    stub's /display is a real touchscreen. On Tier 3 there is no canned
    fallback: no tap yet means {"option": ""}.
"""

import json
import math
import mimetypes
import contextlib
import os
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import perimeter

import governance

HOST = "127.0.0.1"
PORT = int(os.environ.get("LEX_ROBOT_SIDECAR_PORT", "8900"))
# The perimeter: who may talk to this sidecar, who may change the robot, and
# what happens when the caller goes quiet (sidecar/perimeter.py, #195/#196).
# Every gate in it is off unless configured, so an unconfigured run behaves
# exactly as it did before.
SOCKET_PATH = os.environ.get("LEX_ROBOT_SIDECAR_SOCKET")
DEADMAN = perimeter.Deadman.from_env()
# Firmware floors — independent of (and behind) the Lex grant clamps.
# STS3215 servos are 30 kg·cm class; 25 N at the fingertips is already generous.
HARD_GRIP_N = float(os.environ.get("LEX_XLE_HARD_GRIP_N", "25"))
HARD_SPEED_MPS = float(os.environ.get("LEX_XLE_HARD_SPEED_MPS", "1.0"))
USE_HW = os.environ.get("LEX_ROBOT_HW", "0") == "1"
# Stub transcript for the mic (override to script voice demos offline).
CANNED_TRANSCRIPT = os.environ.get("LEX_XLE_TRANSCRIPT", "fetch the cup to the table")
# Stub tap for the touchscreen (see "Touch" in the module docstring). Empty
# means "the prompt's first option" so headless demos need no configuration.
CANNED_TOUCH = os.environ.get("LEX_XLE_TOUCH", "")

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
# A joint that stops tracking its commanded position by more than this, for
# this many consecutive cycles, is blocked rather than slow. Bench-measured on
# this hardware: free travel holds within a couple of degrees, while a real
# obstruction parks the joint tens of degrees from its goal at full torque.
# Which end of the gripper's normalized 0..100 range is open, and which shut.
# Not a constant of the hardware: RANGE_0_100 maps the CALIBRATED raw min to 0
# and max to 100, so the direction depends on which way the gripper was swept.
# Defaults preserve the original assumption (0 open, 100 closed); this unit
# needs them swapped, and deploy/mac/xlerobot.env.example sets that.
GRIPPER_OPEN_PCT = float(os.environ.get("LEX_XLE_GRIPPER_OPEN_PCT", "0"))
GRIPPER_CLOSED_PCT = float(os.environ.get("LEX_XLE_GRIPPER_CLOSED_PCT", "100"))

STALL_ERROR_DEG = int(os.environ.get("LEX_XLE_STALL_ERROR_DEG", "8"))
STALL_CONFIRM = int(os.environ.get("LEX_XLE_STALL_CONFIRM", "3"))

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
        self._connect_without_snapping()
        self._kinematics = self._make_kinematics()
        self._ik = self._make_ik()

    def _connect_without_snapping(self):
        """`follower.connect(calibrate=False)`, but the arm cannot lunge as it
        engages.

        lerobot's connect() ends in configure(), and configure()'s
        `with bus.torque_disabled():` re-enables torque on the way out. Nothing
        in that path touches Goal_Position, so the servos engage against
        whatever goal they already hold -- and a servo that has just been
        powered up holds 0. Measured on this unit on the Pi after a fresh
        power-up: every joint's Goal_Position read 0 while the arms rested
        limp, the furthest 3046 ticks (~268 deg) away, and configure_motors()
        sets Acceleration=254 immediately beforehand. Plain connect() would
        therefore drive every joint to the bottom of its encoder at maximum
        acceleration.

        Syncing goal to present first -- while torque is still off, so the
        write moves nothing -- makes engaging a no-op: the arm stiffens where
        it stands. This is the same discipline tower.py's hold() already
        applies to the tower servos, which share these buses.

        Raw ticks on both sides (normalize=False): this is a hardware-frame
        round trip and must not depend on the calibration being loaded.
        """
        bus = self.follower.bus
        bus.connect()
        bus.sync_write(
            "Goal_Position",
            bus.sync_read("Present_Position", normalize=False),
            normalize=False,
        )
        for cam in self.follower.cameras.values():
            cam.connect()
        self.follower.configure()

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

    def read_health(self):
        """Rail voltage and worst joint temperature for this arm.

        The servos' Present_Voltage IS the battery telemetry on this build --
        there is no separate fuel gauge, and the pack feeds the servo rail
        directly. Every servo reports it and they agree closely, so the median
        rejects a single bad read without needing all of them to answer.

        Held under the port lock like any other bus traffic. On a marginal bus
        some joints simply will not answer; that is reported as `joints`
        (how many did) rather than being averaged away, because a falling
        count is itself the interesting signal.

        Read per-motor rather than via sync_read: a group sync read of these
        one-byte status registers fails outright on this stack (ConnectionError
        from the comm layer) even while position reads are fine, and a
        per-motor loop also lets one silent joint be counted instead of
        failing the whole strip.
        """
        volts, temps = {}, {}
        with hold_port(self.config.port):
            for motor in ARM_JOINTS:
                for reg, sink in (("Present_Voltage", volts), ("Present_Temperature", temps)):
                    try:
                        sink[motor] = self.follower.bus.read(
                            reg, motor, normalize=False, num_retry=2)
                    except Exception:
                        pass  # one quiet joint must not take the whole reading down
        out = {"joints": len(volts), "of": len(ARM_JOINTS)}
        if volts:
            ordered = sorted(volts.values())
            out["volts"] = round(ordered[len(ordered) // 2] / 10.0, 1)
        if temps:
            hottest = max(temps, key=lambda k: temps[k])
            out["temp_c"] = int(temps[hottest])
            out["hottest"] = hottest
        return out

    def read_pose(self):
        try:
            obs = self.follower.get_observation()
        except Exception as e:
            return {"ok": False, "detail": f"transient hardware read error: {e}"}
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

    def move_to(self, x, y, z, rx, ry, rz, timeout_s, tol_m, collision_check=None):
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
        # Distinguishing "converging slowly" from "jammed against something"
        # needs the joint-level tracking error, not the Cartesian distance: a
        # blocked arm sits at a constant offset from the goal its servos were
        # given. Same signal, same consecutive-confirmation rule, as
        # probe_range.StallDetector -- one lagging sample is not a wall.
        try:
            from probe_range import StallDetector
            stall = StallDetector(error_threshold=STALL_ERROR_DEG, confirm=STALL_CONFIRM)
        except Exception:
            stall = None
        while _time.monotonic() < deadline:
            try:
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
                # Refuse BEFORE commanding. Joint limits cannot catch this: a
                # perfectly in-range configuration can still put the gripper
                # through the mast, because the constraint is coupled across
                # joints and across arms (see sidecar/collision.py).
                if collision_check is not None:
                    hits = collision_check(joint_action)
                    if hits:
                        return {"outcome": "denied",
                                "detail": f"{self.side} arm: that pose collides -- "
                                          + "; ".join(str(h) for h in hits[:3])}
                self.follower.send_action(joint_action)
                _time.sleep(0.05)
                obs = self.follower.get_observation()
                joints = {f"{j}.pos": obs[f"{j}.pos"] for j in ARM_JOINTS}
                if stall is not None:
                    worst = max(
                        (abs(float(joint_action[k]) - float(obs[k]))
                         for k in joint_action if k.endswith(".pos") and k in obs),
                        default=0.0)
                    # feed the worst joint's error through the same detector
                    if stall.update(0, int(round(worst))):
                        return {"outcome": "stalled",
                                "detail": f"{self.side} arm stopped tracking: worst joint "
                                          f"{stall.worst} deg from its commanded position over "
                                          f"{STALL_CONFIRM} samples -- blocked, not slow"}
                ee = self._forward_kinematics_ee(joints)
            except Exception as e:
                # A transient bus glitch (serial noise, a concurrent reader
                # stepping on this arm's port, etc.) must not abort the whole
                # move or crash the HTTP connection -- skip this cycle and
                # keep trying until the deadline, same as slow physical
                # progress toward the target would look from the outside.
                print(f"[xlerobot] {self.side} arm: transient read/write error, retrying: {e}")
                continue
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
                "detail": f"{self.side} arm did not settle within {timeout_s}s (last dist "
                          f"{last_dist}) -- tracking stayed within tolerance, so this is slow "
                          f"convergence or an unreachable target, NOT a blockage"}

    def grasp(self, force_n, scale_max_n):
        # Position-based close, scaled by the requested force as a fraction
        # of `scale_max_n` -- the caller's choice of "what counts as 100%
        # closed": the granted max_grip_force_n when a grant is configured,
        # else the firmware floor (HARD_GRIP_N). Scaling against the
        # firmware floor even when a lower grant is active would make full
        # closure mathematically unreachable at any grant-permitted force.
        # Present_Load is read best-effort for the audit trail only — see
        # module docstring: this is NOT a closed-loop force controller.
        frac = clamp(force_n / max(scale_max_n, 1e-6), 0.0, 1.0)
        # Which END of the normalized range is "closed" is NOT a property of the
        # SO-101 -- it falls out of how the gripper was calibrated, because
        # RANGE_0_100 maps the recorded raw min to 0 and max to 100 with no
        # notion of open or shut. This unit calibrates the other way round from
        # what this file used to assume: 0 is CLOSED and 100 is OPEN, verified
        # on hardware (raw 2048 = fingers touching, raw 3453 = wide). Assuming
        # it made `release` drive the gripper further shut while reporting
        # success. Configurable, defaulting to the previous assumption so no
        # other robot changes behaviour.
        gripper_pos = GRIPPER_OPEN_PCT + frac * (GRIPPER_CLOSED_PCT - GRIPPER_OPEN_PCT)
        # Direct bus write, bypassing SO101Follower.send_action()'s
        # max_relative_target clamp entirely. That clamp is a real,
        # intentional safety measure for move_arm's incremental jogging, but
        # it can't be selectively exempted per motor across calls with
        # different action key sets: lerobot's ensure_safe_goal_position
        # requires a dict-typed max_relative_target's keys to exactly match
        # each call's action -- move_to sends all 6 joints every cycle,
        # grasp/release send only the gripper, so one static per-arm config
        # can't satisfy both (this was tried and crashed with "max_relative_
        # target keys must match those of goal_present_pos"). grasp/release
        # are meant to be complete, one-shot actions ("reached" after a
        # single command, not a multi-click jog), so this goes straight to
        # the bus instead.
        self.follower.bus.write("Goal_Position", "gripper", gripper_pos, normalize=True)
        sensed = self._read_gripper_load()
        detail = f"{self.side} gripper closed at requested {force_n:.1f}N (of {scale_max_n:.0f}N max)"
        if sensed is not None:
            detail += f", sensed load {sensed:.0f}"
        return {"outcome": "reached", "detail": detail}

    def release(self):
        # Direct bus write -- see the comment in grasp() for why this
        # bypasses send_action()'s max_relative_target clamp.
        self.follower.bus.write("Goal_Position", "gripper", GRIPPER_OPEN_PCT, normalize=True)
        return {"outcome": "reached",
                "detail": f"{self.side} released (gripper to {GRIPPER_OPEN_PCT:.0f}%)"}

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
    so this talks to the bus directly — see the module docstring.

    On this hardware family the wheels are wired onto the *same* physical
    serial bus as one arm's own 6 servos, not a dedicated port (see
    SIDECAR.md's servo-bus-layout note) — so this accepts exactly one of:
    `port` (a genuinely dedicated serial connection for the base) or
    `shared_bus` (an already-connected FeetechMotorsBus reused from an
    _HwArm, i.e. `_HwArm.follower.bus`).

    Reusing an arm's bus means NEVER touching its `.motors`/`.calibration`
    dicts: those belong to the owning SO101Follower, whose own
    get_observation()/send_action() read/write "all configured motors" via
    the bus's public name-keyed API with no explicit motor list. Registering
    the wheels there (tried first, and it looked like it worked — Operating_
    Mode set fine, wheel_temps_c read fine) went on to silently break the
    arm: get_observation() started sync_read-ing Present_Position for the
    wheels too, and that register IS calibration-normalized, so it KeyError'd
    on the wheels' missing calibration entry the moment anything polled arm
    pose (`read_arm_pose`/the /control page). So this instead drives the
    wheels through the bus's private, ID-based primitives (`_write`, `_read`,
    `_sync_write`, `_sync_read` — addr/length looked up once via
    `get_address`, sign-magnitude encoding done by hand for the signed
    Goal_Velocity register), which touch only the raw serial protocol and
    never consult `.motors`/`.calibration` at all -- safe on a shared bus,
    and works identically for a genuinely dedicated port.
    """

    _MODEL = "sts3215"
    _VELOCITY_SIGN_BIT = 15  # STS3215 Goal_Velocity is sign-magnitude, not two's complement
    _STEPS_PER_DEG = 4096.0 / 360.0  # same convention as lekiwi's _degps_to_raw

    def __init__(self, left_id, right_id, wheel_radius_m, track_width_m, port=None, shared_bus=None):
        if (port is None) == (shared_bus is None):
            raise ValueError("_HwDiffBase needs exactly one of port or shared_bus")
        try:
            from lerobot.motors.encoding_utils import decode_sign_magnitude, encode_sign_magnitude
            from lerobot.motors.feetech import FeetechMotorsBus
            from lerobot.motors.motors_bus import get_address
        except ImportError as e:
            raise HardwareError(
                f"lerobot's FeetechMotorsBus isn't importable ({e}). Install with "
                "`pip install \"lerobot[feetech]\"` — see SIDECAR.md."
            ) from e
        self._encode_sign_magnitude = encode_sign_magnitude
        self._decode_sign_magnitude = decode_sign_magnitude
        self.wheel_radius_m = wheel_radius_m
        self.track_width_m = track_width_m
        self.left_id = left_id
        self.right_id = right_id
        self._owns_bus = shared_bus is None
        if shared_bus is not None:
            self.bus = shared_bus
        else:
            self.bus = FeetechMotorsBus(port=port, motors={})
            self.bus.connect()
        self._op_mode_addr, self._op_mode_len = get_address(self.bus.model_ctrl_table, self._MODEL, "Operating_Mode")
        self._goal_vel_addr, self._goal_vel_len = get_address(self.bus.model_ctrl_table, self._MODEL, "Goal_Velocity")
        self._temp_addr, self._temp_len = get_address(self.bus.model_ctrl_table, self._MODEL, "Present_Temperature")
        try:
            self.bus._write(self._op_mode_addr, self._op_mode_len, left_id, 1)   # 1 == velocity/wheel mode
            self.bus._write(self._op_mode_addr, self._op_mode_len, right_id, 1)
        except Exception as e:
            raise HardwareError(f"could not set base wheels to velocity mode: {e}") from e
        # Dead-reckoning pose estimate — there is no encoder-feedback
        # localization wired here (a known gap, see SIDECAR.md); "reached" is
        # therefore a commanded-time estimate, not sensor-verified.
        self.pose = {"x": 0.0, "y": 0.0, "heading": 0.0}

    def _degps_to_raw(self, degps):
        max_magnitude = (1 << self._VELOCITY_SIGN_BIT) - 1  # encode_sign_magnitude's own ceiling
        raw = int(round(degps * self._STEPS_PER_DEG))
        return max(-max_magnitude, min(max_magnitude, raw))

    def _set_wheel_velocity(self, v_mps, omega_rad_s):
        left_w, right_w = diff_drive_wheel_speeds(v_mps, omega_rad_s, self.wheel_radius_m, self.track_width_m)
        # deg/s, matching the STS3215 velocity-mode convention used elsewhere
        # in lerobot (see lekiwi's _body_to_wheel_raw for the same unit choice).
        ids_values = {
            self.left_id: self._encode_sign_magnitude(self._degps_to_raw(math.degrees(left_w)), self._VELOCITY_SIGN_BIT),
            self.right_id: self._encode_sign_magnitude(self._degps_to_raw(math.degrees(right_w)), self._VELOCITY_SIGN_BIT),
        }
        self.bus._sync_write(self._goal_vel_addr, self._goal_vel_len, ids_values)

    def drive(self, x, y, speed, timeout_s):
        import time as _time
        deadline = _time.monotonic() + timeout_s
        last_t = _time.monotonic()
        arrive_tol = 0.03
        while _time.monotonic() < deadline:
            # The deadman (#195). A goal-point drive runs for up to
            # LEX_XLE_BASE_TIMEOUT_S with nobody watching, so a planner that
            # stalls mid-inference, a client that is killed, or a laptop that
            # sleeps leaves the base driving to a goal nobody wants any more.
            # Checked every tick, before any wheel command. Off unless a
            # caller armed it by sending /heartbeat -- see perimeter.Deadman.
            if DEADMAN.expired():
                self._set_wheel_velocity(0.0, 0.0)
                return {"outcome": "stalled", "detail": DEADMAN.stop_detail()}
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

    def _read_wheel_temps(self):
        # Best-effort, audit-trail only -- same spirit as _HwArm's gripper
        # load read: never blocks or fails the pose read if the bus hiccups.
        # Present_Temperature isn't a signed register, so no sign decoding.
        try:
            raw, _comm = self.bus._sync_read(self._temp_addr, self._temp_len, [self.left_id, self.right_id])
            return {"left": float(raw[self.left_id]), "right": float(raw[self.right_id])}
        except Exception:
            return None

    def read(self):
        result = dict(self.pose)
        temps = self._read_wheel_temps()
        if temps is not None:
            result["wheel_temps_c"] = temps
        return result

    def disconnect(self):
        try:
            self._set_wheel_velocity(0.0, 0.0)
            # A shared bus belongs to the _HwArm that owns it -- that arm's
            # own disconnect() closes it. Closing it here too would pull the
            # arm's connection out from under it if the base is torn down
            # first (_disconnect_partial disconnects arms and the base
            # independently, order not guaranteed).
            if self._owns_bus:
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
            # The deadman (#195). A goal-point drive runs for up to
            # LEX_XLE_BASE_TIMEOUT_S with nobody watching, so a planner that
            # stalls mid-inference, a client that is killed, or a laptop that
            # sleeps leaves the base driving to a goal nobody wants any more.
            # Checked every tick, before any wheel command. Off unless a
            # caller armed it by sending /heartbeat -- see perimeter.Deadman.
            if DEADMAN.expired():
                self.robot.send_action({"x.vel": 0.0, "y.vel": 0.0, "theta.vel": 0.0})
                return {"outcome": "stalled", "detail": DEADMAN.stop_detail()}
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


def _augment_frame(frame):
    """Re-encode a read_camera() result with the bearing scale drawn on.

    Best-effort by design: if OpenCV or the overlay module is missing the
    ORIGINAL frame comes back untouched. A missing scale costs accuracy; a
    raised exception here would cost the planner its eyes entirely.
    """
    jpeg = frame.get("jpeg_b64", "") if isinstance(frame, dict) else ""
    if not jpeg:
        return frame
    try:
        import base64

        import cv2
        import numpy as np

        import camera_overlay as ov
        buf = np.frombuffer(base64.b64decode(jpeg), np.uint8)
        img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if img is None:
            return frame
        ov.draw_bearing_scale(img)
        ok, enc = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
        if not ok:
            return frame
        out = dict(frame)
        out["jpeg_b64"] = base64.b64encode(enc.tobytes()).decode()
        out["augmented"] = True
        out["fov_deg"] = ov.DEFAULT_FOV_DEG
        return out
    except Exception:
        return frame


class _HwCamera:
    def __init__(self, index):
        try:
            from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig
        except ImportError as e:
            raise HardwareError(f"lerobot's OpenCVCamera isn't importable ({e}).") from e
        # Resolution is not just bandwidth economy on a three-camera build.
        # These UVC cameras negotiate 1920x1080 by default, and this unit's USB
        # topology cannot carry three of those at once. Bench-measured on the
        # real hardware: opened ONE AT A TIME all three deliver distinct frames;
        # held open together at 1080p the third returns NO frame at all, and the
        # /control page renders it as "camera unavailable"; dropped to 640x480
        # all three stream concurrently and distinctly. Left unset, a
        # multi-camera build silently loses a camera, so anything reading two
        # views at once (episode verification, multi-camera recording) needs
        # these set. Note the fourcc request is best-effort -- lerobot logs
        # "failed to set fourcc=MJPG" on this stack and continues; 640x480 alone
        # was enough.
        w = os.environ.get("LEX_XLE_CAMERA_WIDTH")
        h = os.environ.get("LEX_XLE_CAMERA_HEIGHT")
        fps = os.environ.get("LEX_XLE_CAMERA_FPS")
        fourcc = os.environ.get("LEX_XLE_CAMERA_FOURCC")
        cfg = {"index_or_path": index}
        if w and h:
            cfg["width"], cfg["height"] = int(w), int(h)
        if fps:
            cfg["fps"] = int(fps)
        if fourcc:
            cfg["fourcc"] = fourcc
        self.camera = OpenCVCamera(OpenCVCameraConfig(**cfg))
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
        self.kind = "blank"  # blank | image | video | url | text | report | prompt
        self.content = ""  # <img>/<video> src, <iframe> src, or literal text
        self.local_path = None  # backing file for GET /display/content, if any
        self.items = []  # report only: the findings list alongside the image
        self.caption = ""  # report only: one-line context above the list
        self.options = []  # prompt only: the tap targets, in display order
        self.touch = None  # prompt only: the one unread tap, if any
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

    def set_report(self, source, items, caption):
        # A picture plus what was found in it, shown together -- the
        # composite kind show_image/show_text alone can't express. Same
        # local-vs-http(s) branching show_image already uses for `source`.
        self.version += 1
        self.kind = "report"
        self.items = list(items)
        self.caption = caption
        if source.startswith("http://") or source.startswith("https://"):
            self.local_path = None
            self.content = source
        else:
            self.local_path = source
            self.content = f"/display/content?v={self.version}"
        return {"outcome": "reached", "detail": f"showing report: {len(items)} item(s)"}

    def set_prompt(self, question, options):
        # A question plus tap targets -- the display's only interactive kind.
        # Discards any unread tap: an answer can only ever belong to the
        # prompt that is currently showing, never carry over to a new one.
        self.local_path = None
        self.version += 1
        self.kind = "prompt"
        self.content = question
        self.options = [str(o) for o in options]
        self.touch = None
        return {"outcome": "reached",
                "detail": f"showing prompt with {len(self.options)} option(s)"}

    def record_touch(self, option, version):
        # Accept a tap from the kiosk page only if it answers the prompt
        # that is showing RIGHT NOW -- kind and version both checked, so a
        # tap racing a display change is rejected rather than misfiled.
        if self.kind != "prompt":
            return {"ok": False, "detail": "no prompt on the display"}
        if version != self.version:
            return {"ok": False, "detail": "prompt changed since this tap"}
        if option not in self.options:
            return {"ok": False, "detail": f"'{option}' is not one of the prompt's options"}
        self.touch = option
        return {"ok": True}

    def take_touch(self):
        tap = self.touch
        self.touch = None
        return tap

    def clear(self):
        self.local_path = None
        self.version += 1
        self.kind = "blank"
        self.content = ""
        self.items = []
        self.caption = ""
        self.options = []
        self.touch = None
        return {"outcome": "reached", "detail": "display cleared"}

    def to_json(self):
        base = {"kind": self.kind, "content": self.content, "version": self.version}
        if self.kind == "report":
            base["items"] = self.items
            base["caption"] = self.caption
        if self.kind == "prompt":
            base["options"] = self.options
            base["answered"] = self.touch is not None
        return base


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
  #stage .report{width:90vw;height:90vh;display:flex;gap:3vw;align-items:center;
                  font:3.2vh/1.4 -apple-system,Helvetica,Arial,sans-serif;color:#fff}
  #stage .report img{max-width:45vw;max-height:80vh;object-fit:contain;border-radius:1vh}
  #stage .report .panel{max-width:45vw}
  #stage .report .caption{opacity:0.75;margin:0 0 1.5vh}
  #stage .report ul{margin:0;padding-left:1.1em}
  #stage .report li{margin-bottom:0.6vh}
  /* prompt: finger-first sizing — a 7-inch panel is the design target, so
     targets are viewport-proportional, not pixel-sized */
  #stage .prompt{width:92vw;height:92vh;display:flex;flex-direction:column;
                 justify-content:center;gap:4vh;color:#fff;
                 font-family:-apple-system,Helvetica,Arial,sans-serif}
  #stage .prompt .question{font-size:7vh;line-height:1.25;text-align:center}
  #stage .prompt .options{display:flex;flex-wrap:wrap;gap:3vh;justify-content:center}
  #stage .prompt button{flex:1 1 38vw;min-height:20vh;font-size:6vh;
                        font-family:inherit;color:#fff;background:#1c3d5a;
                        border:0.6vh solid #4a90d9;border-radius:3vh;
                        touch-action:manipulation;-webkit-tap-highlight-color:transparent}
  #stage .prompt button:disabled{opacity:0.35}
  #stage .prompt button.chosen{background:#2e7d32;border-color:#66bb6a;opacity:1}
  /* Always-on status strip. Sits over the bottom edge so it costs the content
     no room, and stays quiet: dim grey until something is actually wrong. */
  #status{position:fixed;left:0;right:0;bottom:0;display:flex;gap:2.4vw;
          align-items:center;padding:1.1vh 2.4vw;
          font:2.0vh/1 -apple-system,Helvetica,Arial,sans-serif;
          color:#7c8496;background:rgba(0,0,0,0.55);
          border-top:1px solid #1e2230;letter-spacing:.02em}
  #status .dot{width:1.5vh;height:1.5vh;border-radius:50%;background:#4ade80;
               flex:none;box-shadow:0 0 1.4vh rgba(74,222,128,.7)}
  #status.bad .dot{background:#f87171;box-shadow:0 0 1.4vh rgba(248,113,113,.8)}
  #status.bad{color:#f0a0a0}
  #status .sp{margin-left:auto}
  #status b{color:#c3cad8;font-weight:600}
  #status .warn{color:#fbbf24}
</style></head>
<body><div id="stage"></div>
<div id="status"><span class="dot"></span><span id="statustext">starting…</span
   ><span id="statusup" class="sp"></span></div>
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
  } else if (s.kind === 'report') {
    const wrap = document.createElement('div'); wrap.className = 'report';
    const img = document.createElement('img'); img.src = s.content; wrap.appendChild(img);
    const panel = document.createElement('div'); panel.className = 'panel';
    if (s.caption) {
      const cap = document.createElement('p'); cap.className = 'caption'; cap.textContent = s.caption;
      panel.appendChild(cap);
    }
    const ul = document.createElement('ul');
    (s.items || []).forEach(it => { const li = document.createElement('li'); li.textContent = it; ul.appendChild(li); });
    panel.appendChild(ul);
    wrap.appendChild(panel);
    stage.appendChild(wrap);
  } else if (s.kind === 'prompt') {
    const wrap = document.createElement('div'); wrap.className = 'prompt';
    const q = document.createElement('div'); q.className = 'question'; q.textContent = s.content;
    wrap.appendChild(q);
    const row = document.createElement('div'); row.className = 'options';
    const buttons = [];
    (s.options || []).forEach(opt => {
      const b = document.createElement('button'); b.textContent = opt;
      b.onclick = async () => {
        // Send the version this prompt was rendered with, so a tap that
        // races a display change is rejected server-side, not misfiled.
        try {
          const r = await fetch('/display/touch', {method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({option: opt, version: s.version})});
          const res = await r.json();
          if (res.ok) { buttons.forEach(x => x.disabled = true); b.classList.add('chosen'); }
        } catch (e) { /* sidecar unreachable -- leave the buttons live to retry */ }
      };
      buttons.push(b); row.appendChild(b);
    });
    if (s.answered) buttons.forEach(x => x.disabled = true);
    wrap.appendChild(row);
    stage.appendChild(wrap);
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

// Status strip. Polled on its own, slower clock: the server caches this and
// it reads the servo bus, so it must not ride the 1s content poll.
function fmtUptime(s) {
  if (s < 60) return s + 's';
  if (s < 3600) return Math.floor(s / 60) + 'm';
  return Math.floor(s / 3600) + 'h' + String(Math.floor((s % 3600) / 60)).padStart(2, '0');
}
async function pollStatus() {
  const el = document.getElementById('status');
  const txt = document.getElementById('statustext');
  try {
    const s = await (await fetch('/display/status', {cache: 'no-store'})).json();
    const bits = [];
    bits.push(s.mode === 'hardware' ? '<b>live</b>' : '<b>stub</b>');
    (s.arms || []).forEach(a => {
      const good = a.ok;
      const detail = a.error ? a.error : (a.joints + '/' + a.of);
      bits.push((good ? '' : '<span class="warn">') + a.side + ' ' + detail +
                (good ? '' : '</span>'));
    });
    if ((s.cameras || []).length) bits.push(s.cameras.length + ' cam');
    // Rail voltage, NOT a charge estimate -- this pack regulates its output.
    if (s.rail_v != null) bits.push('<b>' + s.rail_v.toFixed(1) + 'V</b> rail');
    if (s.battery && s.battery.available) bits.push('<b>' + s.battery.percent + '%</b> batt');
    else bits.push('batt n/a');
    if (s.servo_temp_c != null) {
      const hot = s.servo_temp_c >= 60;
      bits.push((hot ? '<span class="warn">' : '') + 'servo ' + s.servo_temp_c + '°C' +
                (hot ? '</span>' : ''));
    }
    if (s.pi_temp_c != null) {
      const hot = s.pi_temp_c >= 75;
      bits.push((hot ? '<span class="warn">' : '') + 'pi ' + s.pi_temp_c.toFixed(0) + '°C' +
                (hot ? '</span>' : ''));
    }
    txt.innerHTML = bits.join(' · ');
    document.getElementById('statusup').textContent = fmtUptime(s.uptime_s || 0);
    el.classList.toggle('bad', !s.ok);
  } catch (e) {
    txt.textContent = 'sidecar unreachable';
    document.getElementById('statusup').textContent = '';
    el.classList.add('bad');
  }
}
pollStatus();
setInterval(pollStatus, 5000);
</script></body></html>"""

TEACH_PAGE_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>lex-robot teach</title>
<style>
  :root { --bg:#0a0a1a; --bg2:#0f0f2a; --bg3:#141430; --border:#1e2050;
          --text:#d0d8f0; --muted:#5a6080; --cyan:#22d3ee; --yellow:#fbbf24;
          --lime:#4ade80; --red:#f87171; }
  * { box-sizing:border-box; }
  html,body { margin:0; background:var(--bg); color:var(--text);
              font-family:'Courier New',Courier,monospace; font-size:13px; }
  header { background:var(--bg2); border-bottom:1px solid var(--border);
           padding:10px 16px; display:flex; align-items:center; gap:12px; }
  header h1 { font-size:14px; color:var(--cyan); letter-spacing:.08em; margin:0; }
  header a { color:var(--muted); margin-left:auto; }
  .wrap { padding:14px 16px; max-width:1000px; }
  .panel { background:var(--bg2); border:1px solid var(--border); padding:14px; margin-bottom:14px; }
  h2 { font-size:13px; color:var(--cyan); margin:0 0 10px; }
  label { display:block; color:var(--muted); font-size:11px; margin:8px 0 2px; }
  input, textarea, select { width:100%; background:var(--bg3); color:var(--text);
       border:1px solid var(--border); padding:5px; font-family:inherit; font-size:12px; }
  textarea { resize:vertical; min-height:44px; }
  .row { display:flex; gap:10px; } .row > * { flex:1; }
  button { background:var(--bg3); color:var(--text); border:1px solid var(--border);
           padding:7px 14px; cursor:pointer; font-family:inherit; }
  button:disabled { opacity:.35; cursor:not-allowed; }
  button.go { border-color:var(--lime); color:var(--lime); }
  button.stop { border-color:var(--red); color:var(--red); }
  .hint { color:var(--muted); font-size:11px; line-height:1.5; margin:6px 0; }
  .status { margin-top:10px; font-size:12px; min-height:16px; }
  table { width:100%; border-collapse:collapse; font-size:12px; }
  th,td { text-align:left; padding:4px 6px; border-bottom:1px solid var(--border); vertical-align:top; }
  th { color:var(--muted); font-weight:normal; font-size:11px; }
  .ok { color:var(--lime); } .warn { color:var(--yellow); } .bad { color:var(--red); }
  .tag { background:var(--bg3); border:1px solid var(--border); padding:0 5px; margin-right:3px; }
  .cams { display:flex; gap:10px; flex-wrap:wrap; margin:10px 0; }
  .cam { flex:1; min-width:220px; max-width:320px; }
  .cam .lbl { color:var(--muted); font-size:11px; letter-spacing:.05em; margin-bottom:3px; }
  .cam .box { aspect-ratio:4/3; background:var(--bg3); border:1px solid var(--border);
              display:flex; align-items:center; justify-content:center; overflow:hidden; }
  .cam.rec .box { border-color:var(--red); }
  .cam img { width:100%; height:100%; object-fit:contain; display:block; }
  .cam .unavail { color:var(--muted); font-size:11px; text-align:center; padding:8px; }
</style></head>
<body>
<header><h1>TEACH BY DEMONSTRATION</h1><a href="/control">&rarr; arm control</a><a href="/governance" style="margin-left:12px">&rarr; governance</a></header>
<div class="wrap">

<div class="panel">
  <h2>POSITION THE ARM</h2>
  <div class="hint">
    Do this BEFORE recording. Otherwise the only way to unlock the arm is to start a
    recording, and repositioning becomes the opening of every demonstration.
    Every demonstration should begin from the SAME pose &mdash; variation the task does
    not contain is variation the policy has to learn anyway.
  </div>
  <div class="row" style="margin-top:8px">
    <button id="free">Free arm</button>
    <button id="hold">Lock where it is</button>
    <button id="sethome">Set this as home</button>
    <button id="gohome" class="go">Go to home</button>
  </div>
  <div class="status" id="posstatus"></div>
</div>

<div class="panel">
  <h2>RECORD A DEMONSTRATION</h2>
  <div class="hint">
    The five arm joints go LIMP when recording starts &mdash; these servos have no gravity
    compensation, so the arm's weight is yours to hold. The gripper stays powered, so open
    and close it from the <a href="/control" style="color:var(--cyan)">control page</a>
    rather than squeezing the fingers by hand.
  </div>
  <div class="row">
    <div><label>name (also the filename)</label><input id="name" placeholder="pick_cup_tray_left_01"></div>
    <div><label>arm</label><select id="arm"><option value="left">left</option><option value="right">right</option></select></div>
  </div>
  <label>task &mdash; natural language, and this is TRAINING INPUT, not a comment</label>
  <textarea id="task" placeholder="pick up the cup from the left of the tray and place it on the plate"></textarea>
  <div class="hint">
    Every demonstration of the same task must use the SAME wording: it becomes
    <code>--dataset.single_task</code>, which language-conditioned policies are trained
    against, so varied phrasing reads as a varied task.
  </div>
  <div class="row">
    <div><label>tags (comma separated)</label><input id="tags" placeholder="pick, cup, nominal"></div>
    <div><label>max seconds</label><input id="seconds" type="number" value="60" min="2"></div>
    <div><label>fps</label><input id="fps" type="number" value="20" min="2" max="50"></div>
  </div>
  <label style="display:flex; align-items:center; gap:6px; margin-top:10px">
    <input type="checkbox" id="freegrip" style="width:auto">
    <span>also free the gripper &mdash; squeeze the fingers by hand instead of
    commanding them from the control page</span>
  </label>
  <div class="row" style="margin-top:12px">
    <button id="start" class="go">Start recording</button>
    <button id="stop" class="stop" disabled>Stop &amp; save</button>
  </div>
  <div class="status" id="recstatus"></div>
  <div class="hint" style="margin-top:10px">
    These are the views being written into the dataset &mdash; the scene camera and this
    arm's wrist. If a frame looks wrong here, it is wrong in the training data.
  </div>
  <div class="cams" id="cams"></div>
</div>

<div class="panel">
  <h2>LIBRARY</h2>
  <div class="status" id="libstatus"></div>
  <table id="lib"><thead><tr>
    <th>name</th><th>task</th><th>arm</th><th>frames</th><th>secs</th>
    <th>max step</th><th>checks</th><th></th>
  </tr></thead><tbody></tbody></table>
</div>

</div>
<script>
const $ = id => document.getElementById(id);
async function skill(name, args) {
  const r = await fetch('/skill/' + name, {method:'POST', headers:{'Content-Type':'application/json'},
                                           body: JSON.stringify(args || {})});
  return r.json();
}
function say(el, res, okKey) {
  const good = okKey === 'outcome' ? res.outcome === 'reached' : res.ok;
  $(el).innerHTML = (good ? '<span class="ok">' : '<span class="bad">')
    + (res.detail || res.outcome || '') + '</span>';
}
$('free').onclick = async () => say('posstatus',
  await skill('teach_free', {arm: $('arm').value, include_gripper: $('freegrip').checked}), 'ok');
$('hold').onclick = async () => say('posstatus', await skill('teach_hold', {arm: $('arm').value}), 'ok');
$('sethome').onclick = async () => say('posstatus', await skill('teach_home_set', {arm: $('arm').value}), 'ok');
$('gohome').onclick = async () => {
  $('posstatus').textContent = 'moving to home...';
  say('posstatus', await skill('teach_home_go', {arm: $('arm').value}), 'outcome');
};
async function showHome() {
  const r = await skill('teach_home_get', {arm: $('arm').value});
  $('gohome').disabled = !r.ok;
  if (!r.ok) $('posstatus').innerHTML = '<span class="warn">no home pose saved for this arm '
    + '&mdash; Free it, position it, then Set this as home</span>';
}
$('arm').addEventListener('change', showHome);

$('start').onclick = async () => {
  const name = $('name').value.trim();
  if (!name) { $('recstatus').innerHTML = '<span class="bad">give it a name first</span>'; return; }
  const res = await skill('teach_start', {
    arm: $('arm').value, name, task: $('task').value.trim(),
    tags: $('tags').value.split(',').map(s=>s.trim()).filter(Boolean),
    seconds: parseFloat($('seconds').value)||60, fps: parseFloat($('fps').value)||20,
    free_gripper: $('freegrip').checked});
  $('recstatus').innerHTML = res.ok
    ? '<span class="ok">' + res.detail + '</span> &mdash; limp: ' + (res.free||[]).join(', ')
    : '<span class="bad">' + res.detail + '</span>';
};
$('stop').onclick = async () => {
  const res = await skill('teach_stop', {});
  if (!res.ok) { $('recstatus').innerHTML = '<span class="bad">'+res.detail+'</span>'; return; }
  const bits = ['<span class="ok">saved ' + res.saved + '</span>',
                res.frames + ' frames', res.duration_s + 's',
                'max step ' + res.max_step_deg + ' deg'];
  (res.problems||[]).forEach(p => bits.push('<span class="bad">' + p + '</span>'));
  (res.warnings||[]).forEach(w => bits.push('<span class="warn">' + w + '</span>'));
  $('recstatus').innerHTML = bits.join(' &middot; ');
  refresh();
};
// Which cameras a recording of THIS arm will capture: the scene camera plus
// that arm's own wrist -- the pair the recorder defaults to.
function previewSlots() { return ['head', $('arm').value]; }

function ensureCamBoxes() {
  const want = previewSlots().join(',');
  const el = $('cams');
  if (el.dataset.slots === want) return;
  el.dataset.slots = want;
  el.innerHTML = previewSlots().map(c =>
    `<div class="cam" id="cam-${c}"><div class="lbl">${c.toUpperCase()}</div>
       <div class="box"><span class="unavail">camera: --</span></div></div>`).join('');
}
$('arm').addEventListener('change', () => { ensureCamBoxes(); refreshCams(); });

let camBusy = false;
async function refreshCams() {
  if (camBusy) return;          // never stack camera reads: they share the bus lock
  camBusy = true;
  try {
    for (const c of previewSlots()) {
      const box = document.querySelector(`#cam-${c} .box`);
      if (!box) continue;
      try {
        const r = await skill('read_camera', {name: c});
        box.innerHTML = r.jpeg_b64
          ? `<img src="data:image/jpeg;base64,${r.jpeg_b64}">`
          : `<span class="unavail">${r.error || 'no frame'}</span>`;
      } catch (e) {
        box.innerHTML = '<span class="unavail">stale</span>';
      }
    }
  } finally { camBusy = false; }
}

async function poll() {
  const s = await skill('teach_status', {});
  $('start').disabled = s.recording;
  $('stop').disabled = !s.recording;
  previewSlots().forEach(c => {
    const el = document.getElementById('cam-' + c);
    if (el) el.classList.toggle('rec', !!s.recording);
  });
  if (s.recording) {
    $('recstatus').innerHTML = '<span class="warn">RECORDING</span> ' + s.name + ' &mdash; ' +
      s.frames + ' frames, ' + s.elapsed_s + 's &mdash; move the arm by hand';
  } else if (s.error) {
    $('recstatus').innerHTML = '<span class="bad">' + s.error + '</span>';
  }
}
function checks(r) {
  if (r.error) return '<span class="bad">' + r.error + '</span>';
  const out = [];
  if (r.ok) out.push('<span class="ok">replayable</span>');
  (r.problems||[]).forEach(p => out.push('<span class="bad">' + p + '</span>'));
  (r.warnings||[]).forEach(w => out.push('<span class="warn">' + w + '</span>'));
  return out.join('<br>');
}
async function refresh() {
  const res = await skill('teach_list', {});
  const tb = $('lib').querySelector('tbody');
  const rs = res.recordings || [];
  tb.innerHTML = rs.map(r => `<tr>
      <td>${r.name}</td>
      <td>${r.task ? r.task : '<span class="warn">(none)</span>'}<br>` +
        (r.tags||[]).map(t=>'<span class="tag">'+t+'</span>').join('') + `</td>
      <td>${r.arm||'<span class="warn">?</span>'}</td>
      <td>${r.frames==null?'':r.frames}</td>
      <td>${r.duration_s==null?'':r.duration_s}</td>
      <td>${r.max_step_deg==null?'':r.max_step_deg}</td>
      <td>${checks(r)}</td>
      <td><button onclick="replay('${r.name}')" ${r.ok?'':'disabled'}>Replay</button>
          <button onclick="del('${r.name}')">Delete</button></td>
    </tr>`).join('');
  $('libstatus').textContent = rs.length ? rs.length + ' recording(s)' : 'nothing taught yet';
}
async function replay(name) {
  $('libstatus').innerHTML = 'replaying ' + name + '...';
  const r = await skill('teach_replay', {name});
  $('libstatus').innerHTML = (r.outcome === 'reached' ? '<span class="ok">' : '<span class="bad">')
    + r.outcome + ': ' + (r.detail||'') + '</span>';
}
async function del(name) {
  if (!confirm('Delete ' + name + '?')) return;
  await skill('teach_delete', {name});
  refresh();
}
ensureCamBoxes(); refreshCams(); refresh(); poll(); showHome();
setInterval(poll, 1000);
// Slower than the status poll: each frame is a bus-locked read, and the
// recorder needs that bus. A preview is for checking framing, not for
// watching at rate.
setInterval(refreshCams, 2000);
</script></body></html>"""

CONTROL_PAGE_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>lex-robot arm control</title>
<style>
  :root {
    --bg:#0a0a1a; --bg2:#0f0f2a; --bg3:#141430; --border:#1e2050;
    --text:#d0d8f0; --muted:#5a6080; --cyan:#22d3ee; --yellow:#fbbf24;
    --lime:#4ade80; --red:#f87171;
  }
  * { box-sizing: border-box; }
  html,body { margin:0; padding:0; background:var(--bg); color:var(--text);
              font-family:'Courier New',Courier,monospace; font-size:13px; }
  header { background:var(--bg2); border-bottom:1px solid var(--border);
           padding:10px 16px; display:flex; align-items:center; gap:12px; }
  header h1 { font-size:14px; color:var(--cyan); letter-spacing:.08em; margin:0; }
  #gate { margin-left:auto; display:flex; align-items:center; gap:6px; }
  #notice { padding:8px 16px; color:var(--muted); font-size:11px; border-bottom:1px solid var(--border); }
  /* Layout mirrors the robot: the tower camera sits above and between the two
     arms, the base underneath -- so the page reads like the machine looks. */
  #tower { display:flex; justify-content:center; border-bottom:1px solid var(--border); }
  #tower .panel { width:100%; max-width:440px; }
  #arms { display:grid; grid-template-columns:1fr 1fr; gap:1px; background:var(--border); }
  #baserow { border-top:1px solid var(--border); }
  @media (max-width: 700px) { #arms { grid-template-columns:1fr; } }
  .panel { background:var(--bg); padding:14px 16px; }
  .panel h2 { font-size:13px; color:var(--cyan); margin:0 0 10px; display:flex; align-items:center; gap:8px; }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--red); flex-shrink:0; }
  .dot.ok { background:var(--lime); }
  table.joints { width:100%; border-collapse:collapse; margin-bottom:12px; }
  table.joints td { padding:2px 4px; border-bottom:1px solid var(--border); font-size:12px; }
  table.joints td:first-child { color:var(--muted); }
  .pose { margin-bottom:12px; font-size:12px; }
  .pose .unavail { color:var(--yellow); }
  .axis-row { display:flex; align-items:center; gap:8px; margin-bottom:6px; }
  .axis-row label { width:14px; color:var(--muted); }
  .axis-row button { width:28px; height:24px; background:var(--bg3); color:var(--text);
                      border:1px solid var(--border); cursor:pointer; }
  .axis-row button:disabled { opacity:.35; cursor:not-allowed; }
  .step-row, .gripper-row { display:flex; align-items:center; gap:8px; margin:10px 0; }
  .step-row input, .gripper-row input { width:64px; background:var(--bg3); color:var(--text);
                                         border:1px solid var(--border); padding:2px 4px; }
  .gripper-row button { background:var(--bg3); color:var(--text); border:1px solid var(--border);
                         padding:4px 10px; cursor:pointer; }
  .gripper-row button:disabled { opacity:.35; cursor:not-allowed; }
  .status { margin-top:10px; font-size:11px; color:var(--muted); min-height:14px; }
  /* Capped, not full-bleed: at full panel width a 4:3 feed pushed the joint
     table and jog controls below the fold on a laptop screen. */
  .camera { width:100%; max-width:300px; aspect-ratio:4/3; background:var(--bg3);
            border:1px solid var(--border); margin:0 auto 12px; display:flex;
            align-items:center; justify-content:center; overflow:hidden; }
  #tower .camera { max-width:400px; }
  .maps { display:flex; gap:10px; margin-bottom:12px; justify-content:center; }
  .mapwrap { text-align:center; }
  .mapwrap .caption { color:var(--muted); font-size:10px; letter-spacing:.05em; }
  svg.map { width:120px; height:120px; background:var(--bg3); border:1px solid var(--border); }
  .hint { color:var(--muted); font-size:11px; margin-bottom:8px; line-height:1.5; }
  .axis-row label { width:auto; min-width:112px; }
  .camera img { width:100%; height:100%; object-fit:contain; display:block; }
  .camera .unavail { color:var(--muted); font-size:11px; padding:8px; text-align:center; }
</style></head>
<body>
<header>
  <h1>XLEROBOT ARM CONTROL</h1>
  <a href="/governance" style="color:var(--muted);text-decoration:none">&rarr; governance</a>
  <div id="gate"><input type="checkbox" id="enable"><label for="enable">Enable control</label></div>
</header>
<div id="notice">"Enable control" only gates this page's buttons -- it is not a
  safety system. The sidecar's own joint clamp, Lex grants, and the hardware
  e-stop are the real safety boundary.</div>
<div id="tower">
  <div class="panel">
    <h2><span class="dot" id="dot-head"></span>HEAD / TOWER CAMERA</h2>
    <div class="camera" id="camera-head"><span class="unavail">camera: --</span></div>
  </div>
</div>
<div id="arms">
  <div class="panel" data-arm="left">
    <h2><span class="dot" id="dot-left"></span>LEFT ARM</h2>
    <div class="camera" id="camera-left"><span class="unavail">camera: --</span></div>
    <table class="joints" id="joints-left"></table>
    <div class="hint">GRIPPER POSITION -- where the gripper tip is in space,
      not joint angles. The maps below show it from above and from the side;
      the outlined box is the granted workspace.</div>
    <div class="maps">
      <div class="mapwrap"><svg class="map" id="maptop-left" viewBox="0 0 100 100"></svg>
        <div class="caption">FROM ABOVE</div></div>
      <div class="mapwrap"><svg class="map" id="mapside-left" viewBox="0 0 100 100"></svg>
        <div class="caption">FROM THE SIDE</div></div>
    </div>
    <div class="pose" id="pose-left">pose: --</div>
    <div id="jog-left"></div>
    <div class="step-row">step (m) <input type="number" id="step-left" value="0.01" step="0.005" min="0.001"></div>
    <div class="gripper-row">
      <button id="open-left" disabled>Open</button>
      <button id="close-left" disabled>Close</button>
      force (N) <input type="number" id="force-left" value="10" min="0">
    </div>
    <div class="status" id="status-left"></div>
  </div>
  <div class="panel" data-arm="right">
    <h2><span class="dot" id="dot-right"></span>RIGHT ARM</h2>
    <div class="camera" id="camera-right"><span class="unavail">camera: --</span></div>
    <table class="joints" id="joints-right"></table>
    <div class="hint">GRIPPER POSITION -- where the gripper tip is in space,
      not joint angles. The maps below show it from above and from the side;
      the outlined box is the granted workspace.</div>
    <div class="maps">
      <div class="mapwrap"><svg class="map" id="maptop-right" viewBox="0 0 100 100"></svg>
        <div class="caption">FROM ABOVE</div></div>
      <div class="mapwrap"><svg class="map" id="mapside-right" viewBox="0 0 100 100"></svg>
        <div class="caption">FROM THE SIDE</div></div>
    </div>
    <div class="pose" id="pose-right">pose: --</div>
    <div id="jog-right"></div>
    <div class="step-row">step (m) <input type="number" id="step-right" value="0.01" step="0.005" min="0.001"></div>
    <div class="gripper-row">
      <button id="open-right" disabled>Open</button>
      <button id="close-right" disabled>Close</button>
      force (N) <input type="number" id="force-right" value="10" min="0">
    </div>
    <div class="status" id="status-right"></div>
  </div>
</div>
<div id="baserow">
  <div class="panel">
    <h2><span class="dot" id="dot-base"></span>BASE / WHEELS</h2>
    <div class="pose" id="base-info">base: --</div>
  </div>
</div>
<script>
const ARMS = ["left", "right"];
const AXES = ["x", "y", "z"];
let enabled = false;
let lastPose = {left: null, right: null};
let busy = {left: false, right: false};
let polling = {left: false, right: false};
let grant = null;  // fetched once from read_grant; null = no grant configured

// Every command/poll fetch on this page goes through this, not raw fetch():
// on real hardware a request can hang indefinitely (a wedged serial bus,
// a servo that stops responding -- both observed live this session), and
// with no timeout that leaves busy[arm]/polling[arm] stuck true forever,
// permanently disabling that arm's buttons until a manual page reload.
// Aborting after a generous window turns that into a normal caught error
// instead, so the existing catch/finally blocks recover on their own.
async function fetchWithTimeout(url, options, timeoutMs = 15000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, {...options, signal: controller.signal});
  } finally {
    clearTimeout(timer);
  }
}

document.getElementById('enable').addEventListener('change', (e) => {
  enabled = e.target.checked;
  updateButtonStates();
});

async function fetchGrant() {
  try {
    const r = await fetchWithTimeout('/skill/read_grant', {method: 'POST', body: '{}'});
    const g = await r.json();
    if (g.ok) {
      grant = g;
      for (const arm of ARMS) {
        const maxForce = grant.grippers && grant.grippers[arm];
        if (maxForce) document.getElementById(`force-${arm}`).max = maxForce;
      }
    }
  } catch (e) { /* no grant available -- buttons just aren't workspace-limited */ }
  updateButtonStates();
}

function updateButtonStates() {
  for (const arm of ARMS) {
    const baseDisable = !enabled || busy[arm] || !lastPose[arm];
    document.querySelectorAll(`#jog-${arm} button`).forEach(b => {
      let disable = baseDisable;
      if (!disable && grant && grant.arms && grant.arms[arm] && grant.arms[arm].workspace_m) {
        const axis = b.dataset.axis;
        const dir = parseFloat(b.dataset.dir);
        const step = parseFloat(document.getElementById(`step-${arm}`).value) || 0.01;
        const target = lastPose[arm][axis] + dir * step;
        const bound = grant.arms[arm].workspace_m[AXES.indexOf(axis)];
        if (target < bound.min || target > bound.max) disable = true;
      }
      b.disabled = disable;
    });
    document.getElementById(`open-${arm}`).disabled = !enabled || busy[arm];
    document.getElementById(`close-${arm}`).disabled = !enabled || busy[arm];
  }
}

// "x/y/z" says nothing about which way the gripper actually goes. Each axis is
// labelled with what it does physically, with the axis letter kept as a
// secondary cue so the numbers on screen still tie back to the API.
// +y = the robot's LEFT (viewed from behind, the same convention the arms are
// named by). Established three ways that agree: the left arm's shoulder_pan
// hits a mechanical stop on DECREASING ticks; a human watching the arm sweep
// reported that as "cannot turn further left"; and FK at the working pose puts
// decreasing ticks at +0.025 m of y. That matches the standard URDF convention
// (x forward, y left, z up), but it is measured here, not assumed -- the URDF
// fixes each arm's own frame, not how the arm is mounted.
const AXIS_LABEL = {
  x: {name: 'reach', neg: 'in', pos: 'out'},
  y: {name: 'across', neg: 'right', pos: 'left'},
  z: {name: 'height', neg: 'down', pos: 'up'},
};

function buildJogControls() {
  for (const arm of ARMS) {
    const container = document.getElementById(`jog-${arm}`);
    for (const axis of AXES) {
      const L = AXIS_LABEL[axis];
      const row = document.createElement('div');
      row.className = 'axis-row';
      row.innerHTML = `<label>${L.name} (${axis})</label>` +
        `<button data-axis="${axis}" data-dir="-1" disabled>${L.neg}</button>` +
        `<button data-axis="${axis}" data-dir="1" disabled>${L.pos}</button>`;
      container.appendChild(row);
    }
    container.querySelectorAll('button').forEach(btn => {
      btn.addEventListener('click', () => jog(arm, btn.dataset.axis, parseFloat(btn.dataset.dir)));
    });
  }
}

async function jog(arm, axis, dir) {
  if (!enabled || busy[arm] || !lastPose[arm]) return;
  const step = parseFloat(document.getElementById(`step-${arm}`).value) || 0.01;
  const target = {x: lastPose[arm].x, y: lastPose[arm].y, z: lastPose[arm].z};
  target[axis] += dir * step;
  busy[arm] = true; updateButtonStates();
  try {
    const r = await fetchWithTimeout('/skill/move_arm', {
      method: 'POST',
      body: JSON.stringify({arm, x: target.x, y: target.y, z: target.z}),
    });
    const j = await r.json();
    document.getElementById(`status-${arm}`).textContent = `${j.outcome}: ${j.detail || ''}`;
  } catch (e) {
    document.getElementById(`status-${arm}`).textContent = 'command failed (sidecar unreachable)';
  } finally {
    busy[arm] = false; updateButtonStates();
  }
}

async function gripperCmd(arm, action) {
  if (!enabled || busy[arm]) return;
  busy[arm] = true; updateButtonStates();
  try {
    let body, skill;
    if (action === 'open') {
      skill = 'release_arm'; body = {arm};
    } else {
      skill = 'grasp_arm';
      const force = parseFloat(document.getElementById(`force-${arm}`).value) || 10;
      body = {arm, force};
    }
    const r = await fetchWithTimeout(`/skill/${skill}`, {method: 'POST', body: JSON.stringify(body)});
    const j = await r.json();
    document.getElementById(`status-${arm}`).textContent = `${j.outcome}: ${j.detail || ''}`;
  } catch (e) {
    document.getElementById(`status-${arm}`).textContent = 'command failed (sidecar unreachable)';
  } finally {
    busy[arm] = false; updateButtonStates();
  }
}

for (const arm of ARMS) {
  document.getElementById(`open-${arm}`).addEventListener('click', () => gripperCmd(arm, 'open'));
  document.getElementById(`close-${arm}`).addEventListener('click', () => gripperCmd(arm, 'close'));
  // Changing the step size changes which jog buttons would leave the
  // workspace box, so re-evaluate button states right away rather than
  // waiting for the next poll tick.
  document.getElementById(`step-${arm}`).addEventListener('input', updateButtonStates);
}

// Fallback ranges when no grant is configured -- wide enough to contain any
// pose this arm can actually reach, so the dot never lands off-canvas.
const FALLBACK_RANGE = {x: {min: 0.0, max: 0.5}, y: {min: -0.35, max: 0.35}, z: {min: 0.0, max: 0.5}};

function axisRange(arm, axis) {
  const ws = grant && grant.arms && grant.arms[arm] && grant.arms[arm].workspace_m;
  const b = ws && ws[AXES.indexOf(axis)];
  if (b && typeof b.min === 'number' && typeof b.max === 'number' && b.max > b.min) return b;
  return FALLBACK_RANGE[axis];
}

// Draw one 2D projection: `h` across the canvas, `v` up it. Both the granted
// box and the current gripper position are drawn in the same frame, so "am I
// near the edge of what I'm allowed?" is answerable at a glance.
function drawMap(svg, arm, hAxis, vAxis, pose, hLabel, vLabel) {
  const PAD = 12, SIZE = 100 - 2 * PAD;
  // Plot a margin WIDER than the granted box, so the box reads as a region
  // inside the view rather than coinciding with its border -- otherwise
  // "how close am I to the edge of what I'm allowed?" is invisible, and a
  // pose outside the grant would be clipped instead of shown escaping it.
  const widen = (r) => {
    const m = (r.max - r.min) * 0.18;
    return {min: r.min - m, max: r.max + m};
  };
  const gh = axisRange(arm, hAxis), gv = axisRange(arm, vAxis);
  const hr = widen(gh), vr = widen(gv);
  const sx = (val) => PAD + ((val - hr.min) / (hr.max - hr.min)) * SIZE;
  const sy = (val) => PAD + (1 - (val - vr.min) / (vr.max - vr.min)) * SIZE;   // v grows upward
  const parts = [
    `<rect x="${PAD}" y="${PAD}" width="${SIZE}" height="${SIZE}" fill="none"
           stroke="#1e2050" stroke-width="1"/>`,
    `<text x="50" y="97" fill="#5a6080" font-size="7" text-anchor="middle"
           font-family="monospace">${hLabel}</text>`,
    `<text x="4" y="50" fill="#5a6080" font-size="7" text-anchor="middle"
           font-family="monospace" transform="rotate(-90 4 50)">${vLabel}</text>`,
  ];
  if (grant && grant.arms && grant.arms[arm] && grant.arms[arm].workspace_m) {
    parts.push(`<rect x="${sx(gh.min)}" y="${sy(gv.max)}"
      width="${sx(gh.max) - sx(gh.min)}" height="${sy(gv.min) - sy(gv.max)}"
      fill="rgba(74,222,128,.07)" stroke="#4ade80" stroke-width="1" stroke-dasharray="3 2"/>`);
  }
  if (pose) {
    const cx = sx(pose[hAxis]), cy = sy(pose[vAxis]);
    // Red when the gripper is outside the granted box -- the thing actually
    // worth noticing, rather than merely off the edge of the drawing.
    const inside = pose[hAxis] >= gh.min && pose[hAxis] <= gh.max &&
                   pose[vAxis] >= gv.min && pose[vAxis] <= gv.max;
    parts.push(`<line x1="${PAD}" y1="${cy}" x2="${100 - PAD}" y2="${cy}" stroke="#22d3ee" stroke-width=".4" opacity=".4"/>`);
    parts.push(`<line x1="${cx}" y1="${PAD}" x2="${cx}" y2="${100 - PAD}" stroke="#22d3ee" stroke-width=".4" opacity=".4"/>`);
    parts.push(`<circle cx="${cx}" cy="${cy}" r="3.2" fill="${inside ? '#22d3ee' : '#f87171'}"/>`);
  }
  svg.innerHTML = parts.join('');
}

function renderMaps(arm, pose) {
  // FROM ABOVE: reach runs up the screen (away from the robot), across runs
  // left-to-right -- and +y is the robot's left, so the map is drawn as seen
  // FROM BEHIND the robot, matching how the arms themselves are named.
  // FROM THE SIDE: reach runs right, height runs up.
  drawMap(document.getElementById(`maptop-${arm}`), arm, 'y', 'x', pose, 'right &lt;- across (y) -&gt; left', 'reach (x)');
  drawMap(document.getElementById(`mapside-${arm}`), arm, 'x', 'z', pose, 'reach (x)', 'height (z)');
}

async function pollArm(arm) {
  if (busy[arm]) return;
  polling[arm] = true;
  try {
    // Sequential, not Promise.all: never have more than one outstanding
    // HTTP request for this arm in flight at once, so the sidecar never
    // runs two handler threads against the same arm's serial bus
    // concurrently (it isn't thread-safe on hardware).
    const jr = await fetchWithTimeout('/skill/read_joints', {method: 'POST', body: JSON.stringify({arm})});
    const joints = await jr.json();
    // Re-check busy[arm] between each bus-touching call: a jog/gripper click
    // can land after this tick already started (busy[arm] is set
    // synchronously at click time), so bail before issuing another request
    // into the same arm's bus while a move/grasp/release is now in flight.
    if (busy[arm]) return;
    const pr = await fetchWithTimeout('/skill/read_arm_pose', {method: 'POST', body: JSON.stringify({arm})});
    const pose = await pr.json();
    if (busy[arm]) return;
    const cr = await fetchWithTimeout('/skill/read_camera', {method: 'POST', body: JSON.stringify({name: arm})});
    const cam = await cr.json();

    document.getElementById(`dot-${arm}`).classList.add('ok');

    const table = document.getElementById(`joints-${arm}`);
    table.innerHTML = joints.names.map((n, i) =>
      `<tr><td>${n}</td><td>${joints.positions[i].toFixed(2)}</td></tr>`).join('');

    const poseEl = document.getElementById(`pose-${arm}`);
    if (pose.ok) {
      // Centimetres: at this arm's scale a 0.01 m jog reads as "1 cm", which is
      // easier to hold in your head than 0.010 m.
      poseEl.innerHTML = `reach ${(pose.x * 100).toFixed(1)} cm &middot; ` +
        `across ${(pose.y * 100).toFixed(1)} cm &middot; height ${(pose.z * 100).toFixed(1)} cm`;
      lastPose[arm] = pose;
      renderMaps(arm, pose);
    } else {
      poseEl.innerHTML = `<span class="unavail">pose unavailable: ${pose.detail || 'n/a'}</span>`;
      lastPose[arm] = null;
      renderMaps(arm, null);
    }

    const camEl = document.getElementById(`camera-${arm}`);
    if (cam.jpeg_b64) {
      camEl.innerHTML = `<img src="data:image/jpeg;base64,${cam.jpeg_b64}">`;
    } else {
      camEl.innerHTML = `<span class="unavail">camera unavailable: ${cam.error || 'no frame'}</span>`;
    }
  } catch (e) {
    document.getElementById(`dot-${arm}`).classList.remove('ok');
    document.getElementById(`pose-${arm}`).innerHTML = `<span class="unavail">stale (last poll failed)</span>`;
    document.getElementById(`camera-${arm}`).innerHTML = `<span class="unavail">stale (last poll failed)</span>`;
    lastPose[arm] = null;
  } finally {
    polling[arm] = false;
  }
  updateButtonStates();
}

let extraPolling = false;

// Head camera + base/wheels telemetry -- both read-only in this UI (no
// commands issued), so unlike pollArm there's no busy[] to coordinate with;
// extraPolling just prevents two overlapping polls if a request runs long.
async function pollExtra() {
  if (extraPolling) return;
  extraPolling = true;
  try {
    const cr = await fetchWithTimeout('/skill/read_camera', {method: 'POST', body: JSON.stringify({name: 'head'})});
    const cam = await cr.json();
    const camEl = document.getElementById('camera-head');
    if (cam.jpeg_b64) {
      camEl.innerHTML = `<img src="data:image/jpeg;base64,${cam.jpeg_b64}">`;
      document.getElementById('dot-head').classList.add('ok');
    } else {
      camEl.innerHTML = `<span class="unavail">camera unavailable: ${cam.error || 'no frame'}</span>`;
      document.getElementById('dot-head').classList.remove('ok');
    }
  } catch (e) {
    document.getElementById('camera-head').innerHTML = `<span class="unavail">stale (last poll failed)</span>`;
    document.getElementById('dot-head').classList.remove('ok');
  }

  try {
    const br = await fetchWithTimeout('/skill/read_base', {method: 'POST', body: '{}'});
    const base = await br.json();
    const baseEl = document.getElementById('base-info');
    if (base.ok === false) {
      baseEl.innerHTML = `<span class="unavail">${base.detail}</span>`;
      document.getElementById('dot-base').classList.remove('ok');
    } else {
      let html = `pose (dead-reckoned): x=${base.x.toFixed(3)} y=${base.y.toFixed(3)} heading=${base.heading.toFixed(3)}`;
      if (base.wheel_temps_c) {
        html += `<br>wheel temps: L=${base.wheel_temps_c.left.toFixed(0)}&deg;C R=${base.wheel_temps_c.right.toFixed(0)}&deg;C`;
      }
      baseEl.innerHTML = html;
      document.getElementById('dot-base').classList.add('ok');
    }
  } catch (e) {
    document.getElementById('base-info').innerHTML = `<span class="unavail">stale (last poll failed)</span>`;
    document.getElementById('dot-base').classList.remove('ok');
  }
  extraPolling = false;
}

function poll() {
  for (const arm of ARMS) {
    if (!polling[arm]) pollArm(arm);
  }
  pollExtra();
}

buildJogControls();
fetchGrant();
poll();
setInterval(poll, 500);
</script>
</body></html>"""


GOVERNANCE_PAGE_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>lex-robot governance</title>
<style>
  :root { --bg:#0a0a1a; --bg2:#0f0f2a; --bg3:#141430; --border:#1e2050;
          --text:#d0d8f0; --muted:#5a6080; --cyan:#22d3ee; --yellow:#fbbf24;
          --lime:#4ade80; --red:#f87171; --violet:#a78bfa; }
  /* Verdict colours are STATUS colours, not a series palette: lime allowed,
     amber clamped, violet denied, red failed, muted unknown. Denied is
     deliberately not red -- a refusal is the envelope working, while red
     means something broke. Every verdict also carries its word and a glyph,
     so none of this is conveyed by colour alone. */
  * { box-sizing:border-box; }
  html,body { margin:0; background:var(--bg); color:var(--text);
              font-family:'Courier New',Courier,monospace; font-size:13px; }
  header { background:var(--bg2); border-bottom:1px solid var(--border);
           padding:10px 16px; display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
  header h1 { font-size:14px; color:var(--cyan); letter-spacing:.08em; margin:0; }
  header a { color:var(--muted); text-decoration:none; }
  header a:hover { color:var(--cyan); }
  header .spacer { margin-left:auto; }
  #notice { background:var(--bg3); border-bottom:1px solid var(--border);
            color:var(--muted); padding:8px 16px; font-size:11px; line-height:1.5; }
  .wrap { padding:14px 16px; max-width:1180px; }
  .panel { background:var(--bg2); border:1px solid var(--border); padding:14px; margin-bottom:14px; }
  h2 { font-size:13px; color:var(--cyan); margin:0 0 10px; letter-spacing:.06em; }
  table { width:100%; border-collapse:collapse; font-size:12px; }
  th { text-align:left; padding:4px 6px; color:var(--muted); font-weight:normal;
       border-bottom:1px solid var(--border); font-size:11px; letter-spacing:.05em; }
  td { text-align:left; padding:4px 6px; border-bottom:1px solid var(--border);
       vertical-align:top; }
  td.num { color:var(--muted); width:44px; }
  .tiles { display:flex; gap:10px; flex-wrap:wrap; margin-bottom:12px; }
  .tile { border:1px solid var(--border); background:var(--bg3); padding:8px 12px; min-width:104px; }
  .tile .n { font-size:20px; line-height:1.1; }
  .tile .k { font-size:11px; color:var(--muted); letter-spacing:.06em; }
  .allowed { color:var(--lime); } .clamped { color:var(--yellow); }
  .denied  { color:var(--violet); } .failed { color:var(--red); }
  .unknown { color:var(--muted); }
  .muted { color:var(--muted); }
  .yes { color:var(--lime); } .no { color:var(--yellow); }
  code { color:var(--text); background:var(--bg3); padding:0 3px; }
  .hash { font-size:11px; color:var(--muted); word-break:break-all; }
  label.inline { color:var(--muted); font-size:11px; }
  .empty { color:var(--muted); font-size:12px; padding:6px; }
  .warn { color:var(--yellow); font-size:11px; margin-top:8px; }
</style></head>
<body>
<header>
  <h1>GOVERNANCE</h1>
  <span id="chainstate" class="muted">chain --</span>
  <span class="spacer"></span>
  <a href="/control">&rarr; arm control</a>
  <a href="/teach">&rarr; teach</a>
  <a href="/governance/trail">&rarr; trail (json)</a>
</header>
<div id="notice">This page <b>observes</b>. It is not an enforcement point: the
  grant is checked in the sidecar's own skill path (a target outside the granted
  workspace is refused there, grip force is clamped there), and this view reads
  the result afterwards. Nothing you can do here changes what the robot is
  allowed to do -- and a software grant is not a safety system either, see
  DESIGN.md &sect;8.</div>

<div class="wrap">
  <div class="panel">
    <h2>GRANT &mdash; <span id="grantsrc" class="muted">loading&hellip;</span></h2>
    <table id="granttable">
      <thead><tr><th>bound</th><th>value</th><th>enforced here</th><th>how</th></tr></thead>
      <tbody id="grantbody"></tbody>
    </table>
    <div id="grantwarn" class="warn"></div>
  </div>

  <div class="panel">
    <h2>DECISIONS</h2>
    <div class="tiles" id="tiles"></div>
    <div style="margin-bottom:8px">
      <label class="inline"><input type="checkbox" id="onlygov"> denials and clamps only</label>
      <span class="muted" id="ledgermeta" style="margin-left:14px"></span>
    </div>
    <table>
      <thead><tr><th>#</th><th>time</th><th>capability</th><th>verdict</th>
                 <th>arguments</th><th>reason</th></tr></thead>
      <tbody id="decisions"></tbody>
    </table>
    <div id="noneyet" class="empty">no authority-exercising calls yet &mdash; drive the arm
      from <a href="/control" style="color:var(--cyan)">/control</a> and they appear here.</div>
  </div>

  <div class="panel">
    <h2>TRAIL</h2>
    <table>
      <tbody>
        <tr><th>events</th><td id="tr-total">--</td></tr>
        <tr><th>retained in memory</th><td id="tr-retained">--</td></tr>
        <tr><th>chain verified</th><td id="tr-verified">--</td></tr>
        <tr><th>head</th><td class="hash" id="tr-head">--</td></tr>
        <tr><th>checkpoint</th><td class="hash" id="tr-checkpoint">--</td></tr>
        <tr><th>appended to</th><td id="tr-path">--</td></tr>
      </tbody>
    </table>
    <div id="tr-warn" class="warn"></div>
    <div class="empty">Event ids are lex-trail's own
      <code>sha256(kind \\x00 parent \\x00 payload \\x00 ts_ms)</code>, so this chain
      replays under <code>lex-trail</code> and reconciles against a lex-os audit
      log with <code>scripts/reconcile_audit.py</code>.</div>
  </div>
</div>

<script>
const $ = id => document.getElementById(id);
const VERDICTS = ['allowed','denied','clamped','failed','unknown'];
const GLYPH = {allowed:'\u2713', denied:'\u2298', clamped:'\u2913', failed:'\u2717', unknown:'?'};
let grantDrawn = false;

function esc(s) {
  return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
}
function fmtBound(v) {
  if (Array.isArray(v)) {
    return v.map(b => (b && typeof b === 'object' && 'min' in b)
                      ? `[${b.min}, ${b.max}]` : JSON.stringify(b)).join(' ');
  }
  return JSON.stringify(v);
}
function fmtTime(ts) {
  const d = new Date(ts * 1000);
  return d.toTimeString().slice(0, 8) + '.' + String(d.getMilliseconds()).padStart(3, '0');
}

function drawGrant(g) {
  $('grantsrc').textContent = g.ok ? (g.source || 'loaded') : (g.detail || 'no grant configured');
  $('grantsrc').className = g.ok ? 'muted' : 'no';
  const rows = g.bounds || [];
  $('grantbody').innerHTML = rows.map(r => `<tr>
      <td>${esc(r.bound)}</td>
      <td class="muted">${esc(fmtBound(r.value))}</td>
      <td class="${r.enforced ? 'yes' : 'no'}">${r.enforced ? '\u2713 yes' : '\u2014 no'}</td>
      <td class="muted">${esc(r.how)}</td></tr>`).join('');
  if (!rows.length) {
    $('grantbody').innerHTML = '<tr><td colspan="4" class="empty">no grant loaded &mdash; '
      + 'nothing here is bounded by one. Set LEX_XLE_GRANT_PATH.</td></tr>';
  }
  const declared = rows.filter(r => !r.enforced).length;
  $('grantwarn').textContent = declared
    ? `${declared} declared bound(s) are NOT checked by this sidecar. They are listed `
      + 'so the gap is visible rather than assumed closed.' : '';
  grantDrawn = true;
}

function drawTiles(counters) {
  $('tiles').innerHTML = VERDICTS.map(v =>
    `<div class="tile"><div class="n ${v}">${GLYPH[v]} ${counters[v] || 0}</div>`
    + `<div class="k">${v.toUpperCase()}</div></div>`).join('');
}

function drawDecisions(decisions) {
  const only = $('onlygov').checked;
  const rows = decisions.filter(d => !only || d.verdict === 'denied' || d.verdict === 'clamped');
  $('noneyet').style.display = rows.length ? 'none' : 'block';
  $('decisions').innerHTML = rows.slice().reverse().map(d => `<tr>
      <td class="num">${d.seq}</td>
      <td class="muted">${fmtTime(d.ts)}</td>
      <td>${esc(d.capability)}</td>
      <td class="${d.verdict}">${GLYPH[d.verdict] || ''} ${d.verdict}</td>
      <td class="muted">${esc(JSON.stringify(d.args))}</td>
      <td class="muted">${esc(d.reason || '')}</td></tr>`).join('');
}

function drawTrail(c) {
  $('tr-total').textContent = c.total_events;
  $('tr-retained').textContent = `${c.retained} (window ${c.window})`;
  const v = c.verified;
  $('tr-verified').innerHTML = v.ok
    ? `<span class="yes">\u2713 ok (${v.checked} events)</span>`
    : `<span class="failed">\u2717 ${esc(v.detail)}</span>`;
  $('tr-head').textContent = c.head || '--';
  $('tr-checkpoint').textContent = c.checkpoint
    ? c.checkpoint + '  (events before this were evicted from memory)' : '-- (nothing evicted)';
  $('tr-path').innerHTML = c.path ? esc(c.path)
    : '<span class="muted">nowhere &mdash; set LEX_XLE_TRAIL_PATH to keep the full chain on disk</span>';
  $('tr-warn').textContent = c.write_error ? `trail write failed: ${c.write_error}` : '';
  $('chainstate').innerHTML = v.ok
    ? `<span class="yes">chain \u2713 ${c.total_events} events</span>`
    : `<span class="failed">chain \u2717 ${esc(v.detail)}</span>`;
}

async function poll() {
  try {
    const r = await fetch('/governance/state?limit=100');
    const s = await r.json();
    if (!grantDrawn) drawGrant(s.grant);   // loaded once at startup; it cannot change under us
    drawTiles(s.counters);
    drawDecisions(s.decisions);
    drawTrail(s.chain);
    $('ledgermeta').textContent =
      `${s.recorded} recorded, ${s.retained} retained`
      + (s.include_reads ? ', including reads' : ', reads not recorded')
      + `, up ${s.uptime_s}s`;
  } catch (e) {
    $('chainstate').innerHTML = '<span class="failed">sidecar unreachable</span>';
  }
}

$('onlygov').onchange = poll;
poll();
setInterval(poll, 1000);
</script>
</body></html>"""


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
        # Best-effort, tier-independent: the same workspace-box/grip-force
        # limits a Lex program's inline grant would enforce, applied here too
        # so a direct caller (the /control page, curl, anything hitting this
        # HTTP API without going through Lex) can't drive the arm outside
        # them either. None if not configured -- move_arm/grasp_arm just
        # skip the check in that case, same as every other optional piece
        # of hardware in this file.
        self._grant = self._load_grant()
        if USE_HW:
            self._bring_up_hardware()

    def _load_grant(self):
        default_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "manifests", "xlerobot.capsule.json")
        path = os.environ.get("LEX_XLE_GRANT_PATH", default_path)
        # Kept for GET /governance: a page that shows which bounds are in force
        # has to be able to say which file they came from, or the reader can't
        # check it against the capsule that was actually installed.
        self._grant_path = path
        self._grant_error = None
        try:
            with open(path) as f:
                capsule = json.load(f)
            return capsule.get("actuation")
        except Exception as e:
            self._grant_error = str(e)
            print(f"[xlerobot] no grant loaded from '{path}': {e}")
            return None

    def _grant_workspace_violation(self, arm, x, y, z):
        """None if there's no grant, the grant doesn't cover this arm, or the
        target is inside its workspace box. Otherwise a detail string
        explaining what's out of bounds -- the caller turns this into a
        `denied` outcome and never sends anything to hardware, matching how
        a Lex program's own grant check refuses an out-of-envelope move
        before it's ever sent (see examples/xlerobot_demo.lex)."""
        if not self._grant:
            return None
        arm_grant = self._grant.get("arms", {}).get(arm)
        bounds = arm_grant.get("workspace_m") if arm_grant else None
        if not bounds or len(bounds) != 3:
            return None
        for val, axis, b in zip((x, y, z), "xyz", bounds):
            if not (b["min"] <= val <= b["max"]):
                return (f"{axis}={val:.3f} outside granted workspace "
                        f"[{b['min']:.2f},{b['max']:.2f}] for {arm} arm")
        return None

    def _grant_max_grip_force(self, arm):
        if not self._grant:
            return None
        g = self._grant.get("grippers", {}).get(arm)
        return g.get("max_grip_force_n") if g else None

    def _base_grant(self):
        """The grant's bound for THIS robot's base, or None.

        Keyed "base" by convention (manifests/xlerobot.capsule.json). A single
        differently-named entry is accepted; two or more is ambiguous -- this
        robot has one base -- and returns None rather than guessing which
        envelope applies, since guessing wrong is guessing a floor box.
        """
        bases = (self._grant or {}).get("bases") or {}
        if "base" in bases:
            return bases["base"]
        return next(iter(bases.values())) if len(bases) == 1 else None

    def _grant_floor_violation(self, x, y):
        """None if there's no grant, no floor box, or the target is inside it.
        Otherwise a detail string -- the caller turns this into a `denied`
        outcome and nothing is ever sent to the wheels.

        Refused, never clamped, for the same reason as the arms' workspace box
        (see _grant_workspace_violation): squeezing a position into an
        envelope invents a destination nobody asked to drive to.
        """
        cfg = self._base_grant()
        bounds = cfg.get("floor_area_m") if cfg else None
        if not bounds or len(bounds) != 2:
            return None
        for val, axis, b in zip((x, y), "xy", bounds):
            if not (b["min"] <= val <= b["max"]):
                return (f"{axis}={val:.3f} outside granted floor area "
                        f"[{b['min']:.2f},{b['max']:.2f}]")
        return None

    def _trajectory_ee_path(self, arm, joints, frames):
        """(ee_positions, None), (None, None) or (None, reason).

        Both grant checks on a taught motion -- WHERE it goes and HOW FAST it
        gets there -- need the same Cartesian path, so it is computed once.

        Three answers, not two. `(None, None)` means there is nothing here to
        bound (no such arm configured); `(None, reason)` means a bound applies
        but cannot be evaluated, which the caller must turn into a refusal
        rather than a pass.
        """
        hw = self._hw_arms.get(arm)
        if hw is None:
            return None, None
        missing = [j for j in ARM_JOINTS if j not in joints]
        if missing:
            # Padding the gap with zeros would be checking a pose the arm
            # never held.
            return None, ("it was recorded without " + ", ".join(missing)
                          + ", which the kinematics model needs")
        path = []
        for frame in frames:
            ee = hw._forward_kinematics_ee({f"{j}.pos": v for j, v in zip(joints, frame)})
            if ee is None:
                return None, ("no forward kinematics available (LEX_XLE_URDF_PATH unset, "
                              "or this lerobot install's kinematics module does not match)")
            path.append(ee)
        return path, None

    def _grant_trajectory_violation(self, arm, joints, frames, ee_path=None):
        """None if a taught pose sequence is safe to drive under the grant.
        Otherwise a detail string -- the caller turns it into `denied` and no
        torque is ever enabled. Used by teach_replay (a whole recording) and
        teach_home_go (a single saved pose, i.e. a one-frame trajectory).

        Replay is joint-space, so the grant's Cartesian workspace box can only
        be applied through forward kinematics: each frame's end-effector
        position must land inside the same envelope move_arm enforces. Without
        this, a recording could be taught anywhere the hand could reach and
        replayed straight out of the granted box -- the collision model and the
        6-degree step smoothing bound HOW the arm moves, but nothing bounded
        WHERE it ended up.

        Checked up front, never mid-replay. A replay stopped halfway leaves the
        arm in an arbitrary pose it was only ever meant to pass through, so the
        honest options are all of it or none of it -- the same never-sent
        semantics move_arm has.

        Refuse, don't downgrade: when a box IS declared but the path cannot be
        computed, the check cannot run, and replaying anyway would be claiming
        an envelope nothing verified.
        """
        if not self._grant:
            return None
        arm_grant = self._grant.get("arms", {}).get(arm) or {}
        bounds = arm_grant.get("workspace_m")
        has_box = bool(bounds) and len(bounds) == 3
        # The gate covers BOTH Cartesian bounds, not just the box. A grant that
        # declares only a speed ceiling still needs the path, and letting the
        # replay through because the box happened to be absent would be the
        # silent downgrade this check exists to prevent -- so the refusal below
        # is what an uncomputable path earns either way.
        if not has_box and arm_grant.get("max_velocity_mps") is None:
            return None
        path, reason = ee_path if ee_path is not None else \
            self._trajectory_ee_path(arm, joints, frames)
        if reason is not None:
            return ("cannot verify this trajectory against the granted envelope: "
                    + reason + ". Replaying anyway would claim an envelope nothing checked.")
        if path is None:
            return None
        if not has_box:
            return None
        for idx, ee in enumerate(path):
            for val, axis, b in zip(ee, "xyz", bounds):
                if not (b["min"] <= val <= b["max"]):
                    return (f"frame {idx} of {len(path)} puts the end effector at "
                            f"{axis}={val:.3f}, outside granted workspace "
                            f"[{b['min']:.2f},{b['max']:.2f}] for the {arm} arm")
        return None

    def _grant_max_arm_speed(self, arm):
        if not self._grant:
            return None
        g = self._grant.get("arms", {}).get(arm)
        return g.get("max_velocity_mps") if g else None

    def _grant_clamp_replay_speed(self, arm, joints, frames, fps, speed, ee_path=None):
        """(speed to actually use, clamp record or None).

        `speed` is a caller-chosen multiplier and the gap between frames is
        `1 / (fps * speed)`, so speed=10 drives the taught path ten times
        faster. Nothing bounded that: the workspace check above constrains
        where the arm goes, and the collision model constrains what it hits,
        but a demonstration recorded at a safe pace could be replayed at any
        pace at all.

        Clamped, not refused -- the same split move_base and grasp_arm use.
        A position cannot be squeezed into an envelope without inventing a
        destination, but a speed can: slowing the replay preserves the taught
        path exactly, frame for frame. Refusing instead would reject a
        perfectly good recording over a number the caller picked.

        The ceiling is the end effector's linear speed, so it is the PEAK
        per-step speed that has to fit: a path is only inside the envelope if
        its fastest moment is.

        NOT covered, and worth knowing: replay_on_bus first drives an
        `approach_path` from wherever the arm currently is to the recording's
        first frame, at the same frame rate. That path depends on live joint
        positions this check has no access to, so neither this ceiling nor the
        workspace box applies to it. It is bounded in joint space (no step
        exceeds max_step_deg) and vetoed by the collision model, but its
        Cartesian speed and destination are unchecked.
        """
        ceiling = self._grant_max_arm_speed(arm)
        if ceiling is None or ceiling <= 0 or fps <= 0 or speed <= 0:
            return speed, None
        path, _reason = ee_path if ee_path is not None else \
            self._trajectory_ee_path(arm, joints, frames)
        if path is None or len(path) < 2:
            return speed, None
        step = max(math.dist(a, b) for a, b in zip(path, path[1:]))
        peak = step * fps * speed
        if peak <= ceiling:
            return speed, None
        return speed * ceiling / peak, {
            "bound": f"arms.{arm}.max_velocity_mps", "source": "grant",
            "requested": round(peak, 4), "ceiling": ceiling,
        }

    def _grant_max_base_speed(self):
        cfg = self._base_grant()
        return cfg.get("max_speed_mps") if cfg else None

    def read_grant(self):
        if not self._grant:
            return {"ok": False, "detail": "no grant configured (LEX_XLE_GRANT_PATH not set or unreadable)"}
        arms = {
            side: {
                "workspace_m": cfg.get("workspace_m"),
                "max_velocity_mps": cfg.get("max_velocity_mps"),
                "max_force_n": cfg.get("max_force_n"),
            }
            for side, cfg in self._grant.get("arms", {}).items()
        }
        grippers = {side: cfg.get("max_grip_force_n") for side, cfg in self._grant.get("grippers", {}).items()}
        # The base bound belongs here for the same reason the arms' does: a
        # governed program can only respect an envelope it is able to read.
        base = self._base_grant()
        out = {"ok": True, "arms": arms, "grippers": grippers}
        if base:
            out["base"] = {"floor_area_m": base.get("floor_area_m"),
                           "max_speed_mps": base.get("max_speed_mps")}
        return out

    def _bring_up_hardware(self):
        left_port = os.environ.get("LEX_XLE_LEFT_PORT")
        right_port = os.environ.get("LEX_XLE_RIGHT_PORT")
        base_port = os.environ.get("LEX_XLE_BASE_PORT")
        # "left" | "right": the base wheels share a physical bus with that
        # arm's own servos rather than having a dedicated port -- see
        # _HwDiffBase's docstring and SIDECAR.md's servo-bus-layout note.
        # Mutually exclusive with LEX_XLE_BASE_PORT (a real dedicated port).
        base_shared_arm = os.environ.get("LEX_XLE_BASE_SHARED_ARM")
        # Each arm slot is optional so a partial build runs during bring-up —
        # one calibrated SO-101 on the bench, or a single-arm second robot
        # (a LeKiwi) — but a hardware sidecar with NO arm at all is almost
        # certainly a misconfiguration, so that still refuses loudly.
        if not left_port and not right_port:
            raise SystemExit(
                "LEX_ROBOT_HW=1 requires at least one of LEX_XLE_LEFT_PORT / "
                "LEX_XLE_RIGHT_PORT (serial port per SO-101 arm) — see SIDECAR.md. "
                "A missing arm stays unavailable (its skills return an honest "
                "error); LEX_XLE_BASE_PORT is likewise optional."
            )
        if base_port and base_shared_arm:
            raise SystemExit(
                "LEX_XLE_BASE_PORT and LEX_XLE_BASE_SHARED_ARM are mutually "
                "exclusive -- the base either has its own dedicated serial "
                "port, or shares an arm's bus, not both."
            )
        max_rel = os.environ.get("LEX_XLE_MAX_REL_TARGET")
        max_rel = float(max_rel) if max_rel else None
        try:
            if left_port:
                self._hw_arms["left"] = _HwArm("left", left_port, os.environ.get("LEX_XLE_LEFT_ID", "xle_left"), max_rel)
            if right_port:
                self._hw_arms["right"] = _HwArm("right", right_port, os.environ.get("LEX_XLE_RIGHT_ID", "xle_right"), max_rel)
            if base_port or base_shared_arm:
                if base_shared_arm and base_shared_arm not in self._hw_arms:
                    raise SystemExit(
                        f"LEX_XLE_BASE_SHARED_ARM={base_shared_arm} but that arm isn't "
                        f"configured -- also set LEX_XLE_{base_shared_arm.upper()}_PORT."
                    )
                if BASE_MODE == "omni":
                    self._hw_base = _HwOmniBase(base_port, os.environ.get("LEX_XLE_BASE_ID", "xle_base"))
                else:
                    self._hw_base = _HwDiffBase(
                        int(os.environ.get("LEX_XLE_BASE_LEFT_ID", "1")),
                        int(os.environ.get("LEX_XLE_BASE_RIGHT_ID", "2")),
                        float(os.environ.get("LEX_XLE_WHEEL_RADIUS_M", "0.05")),
                        float(os.environ.get("LEX_XLE_TRACK_WIDTH_M", "0.30")),
                        port=base_port if base_port else None,
                        shared_bus=self._hw_arms[base_shared_arm].follower.bus if base_shared_arm else None,
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

    def _hw_arm_missing(self, arm):
        """None when the arm is configured; an honest outcome-shaped refusal
        otherwise. A request for a missing arm must never fall through to the
        OTHER physical arm -- moving different metal than the caller named is
        worse than refusing."""
        if arm in self._hw_arms:
            return None
        return {"outcome": "stalled",
                "detail": f"{arm} arm not configured (no LEX_XLE_{arm.upper()}_PORT) -- partial build"}

    def _collision_model(self):
        """The coupled-constraint check, or None if it isn't configured.

        Built once, lazily: it needs the same URDF move_arm's IK already
        requires, plus a geometry file describing where the arms, tower and
        cart actually are. Absent either, move_arm keeps its previous
        behaviour rather than refusing everything -- this is a new guard, and
        a missing config file must not brick a working robot.
        """
        if getattr(self, "_collision", "unset") != "unset":
            return self._collision
        self._collision = None
        if os.environ.get("LEX_XLE_COLLISION", "1") != "1":
            return None
        urdf = os.environ.get("LEX_XLE_URDF_PATH")
        geom = os.environ.get("LEX_XLE_GEOMETRY_PATH",
                              os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                           "robot_geometry.json"))
        if not urdf or not os.path.exists(geom):
            print(f"[xlerobot] collision checking OFF (urdf={'set' if urdf else 'unset'}, "
                  f"geometry={'found' if os.path.exists(geom) else 'missing'})")
            return None
        try:
            from collision import RobotCollisionModel
            self._collision = RobotCollisionModel.from_json(geom, urdf)
            print("[xlerobot] collision checking ON")
        except Exception as e:
            print(f"[xlerobot] collision checking OFF (could not build model: {e})")
        return self._collision

    def _collision_check_for(self, arm):
        """A callable move_to can use to veto a pose before commanding it.

        Closes over the OTHER arm's current joints too, so arm-vs-arm is
        checked -- the constraint neither arm can see on its own.
        """
        model = self._collision_model()
        if model is None:
            return None
        other = "right" if arm == "left" else "left"

        def check(joint_action):
            try:
                q = [float(joint_action[f"{j}.pos"]) for j in ARM_JOINTS[:5]]
            except (KeyError, TypeError, ValueError):
                return []          # cannot read the pose -> do not block on it
            kw = {f"{arm}_joints_deg": q}
            hw_other = self._hw_arms.get(other)
            if hw_other is not None:
                try:
                    obs = hw_other.follower.get_observation()
                    kw[f"{other}_joints_deg"] = [float(obs[f"{j}.pos"]) for j in ARM_JOINTS[:5]]
                except Exception:
                    pass           # other arm unreadable -> check this one alone
            try:
                return model.check(**kw)
            except Exception as e:
                print(f"[xlerobot] collision check failed, allowing move: {e}")
                return []
        return check

    def _hw_base_missing(self):
        """None when the base is configured; an honest refusal otherwise --
        an arms-only build with no base is expected and must not crash."""
        if self._hw_base is not None:
            return None
        return {"ok": False,
                "detail": "base not configured (no LEX_XLE_BASE_PORT / LEX_XLE_BASE_SHARED_ARM) -- partial build"}

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
        # `outcome` is the wire contract every other actuating skill answers on
        # (src/types.lex's Outcome). reset used to return the new state alone,
        # which a Lex caller could only read as Stalled -- a successful reset
        # reported as a failure.
        return {"outcome": "reached", "base": dict(self.base),
                "arms": {k: list(v["positions"]) for k, v in self.arms.items()}}

    # ---- sensing -------------------------------------------------------------
    def read_joints(self, arm):
        if USE_HW:
            if arm in self._hw_arms:
                return self._hw_arms[arm].read_joints()
            fallback = self._hw_arms.get("left") or next(iter(self._hw_arms.values()), None)
            if arm not in ("left", "right") and fallback is not None:
                return fallback.read_joints()
            return {"error": f"{arm} arm not configured (no LEX_XLE_{arm.upper()}_PORT) -- partial build"}
        a = self.arms.get(arm, self.arms["left"])
        return {
            "names": [f"{arm}_{j}" for j in ARM_JOINTS],
            "positions": list(a["positions"]),
            "velocities": [0.0] * 6,
        }

    def read_arm_pose(self, arm):
        if USE_HW:
            if arm in self._hw_arms:
                return self._hw_arms[arm].read_pose()
            fallback = self._hw_arms.get("left") or next(iter(self._hw_arms.values()), None)
            if arm not in ("left", "right") and fallback is not None:
                return fallback.read_pose()
            return {"ok": False, "detail": f"{arm} arm not configured (no LEX_XLE_{arm.upper()}_PORT) -- partial build"}
        a = self.arms.get(arm, self.arms["left"])
        x, y, z = a["positions"][:3]
        return {"ok": True, "x": x, "y": y, "z": z}

    def read_base(self):
        if USE_HW:
            missing = self._hw_base_missing()
            if missing is not None:
                return missing
            result = self._hw_base.read()
            result["ok"] = True
            return result
        return dict(self.base, ok=True)

    def read_camera(self, name, augment=False):
        """A frame, optionally with the bearing scale burned in.

        `augment` is off by default so nothing that already consumes frames
        (episode recording, QR scanning, the /control previews) suddenly gets
        graphics drawn over its data. Only the paths that feed a language
        model ask for it — see scan_ahead.
        """
        if USE_HW:
            cam = self._hw_cameras.get(name)
            if cam is None:
                return {"error": f"camera '{name}' not configured or unavailable"}
            frame = cam.read()
            return _augment_frame(frame) if augment else frame
        return {"width": 640, "height": 480, "jpeg_b64": ""}

    def scan_ahead(self, question=""):
        """What is in front of the robot, and at what bearing.

        The frame is annotated with a bearing scale BEFORE the model sees it
        (sidecar/camera_overlay.py), which is what turns "a chair on the left"
        into a number the base can be commanded with. Measured on this unit:
        the scale halved mean bearing error, 3.8 deg -> 1.2 deg.

        Judgment only. This returns a reading; it moves nothing, and the
        grant still gates whatever the planner proposes afterwards.
        """
        vision_url = os.environ.get("LEX_XLE_VISION_URL", "").rstrip("/")
        if not vision_url:
            return {"obstacles": [], "clear_ahead": "unknown",
                    "detail": "no LEX_XLE_VISION_URL configured — scan_ahead needs the"
                              " split-compute vision service, see deploy/VISION_SPLIT.md"}
        frame = self.read_camera("head", augment=True)
        jpeg = frame.get("jpeg_b64", "") if isinstance(frame, dict) else ""
        if not jpeg:
            return {"obstacles": [], "clear_ahead": "unknown",
                    "detail": "head camera produced no frame"}
        timeout_s = float(os.environ.get("LEX_XLE_VISION_TIMEOUT_S", "60"))
        body = json.dumps({"image_b64": jpeg, "question": question or ""}).encode()
        req = urllib.request.Request(f"{vision_url}/vision/scan", data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout_s) as resp:
                out = json.loads(resp.read())
        except Exception as e:
            # "unknown", never an implicit yes: a planner asking whether it can
            # drive must not read a broken vision service as permission.
            return {"obstacles": [], "clear_ahead": "unknown",
                    "detail": f"vision service unreachable at {vision_url}: {e}"}
        if not isinstance(out, dict):
            return {"obstacles": [], "clear_ahead": "unknown",
                    "detail": "vision service returned non-object JSON"}
        out.setdefault("clear_ahead", "unknown")
        out["augmented"] = True
        return out

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

    def show_report(self, source, items, caption):
        if not source:
            return {"outcome": "stalled", "detail": "show_report needs a non-empty image path or URL"}
        return self.display.set_report(source, items, caption)

    def show_prompt(self, question, options):
        if not question:
            return {"outcome": "stalled", "detail": "show_prompt needs a non-empty question"}
        if not options:
            return {"outcome": "stalled", "detail": "show_prompt needs at least one option"}
        return self.display.set_prompt(question, options)

    def read_touch(self):
        # A real tap from the kiosk page always wins, on every tier -- a
        # browser pointed at the stub's /display is a real touchscreen.
        tap = self.display.take_touch()
        if tap is not None:
            return {"option": tap, "detail": "tap from the display page"}
        if self.display.kind != "prompt":
            # A tap can only answer something shown; without a prompt there
            # is honestly nothing to read, canned or not.
            return {"option": "", "detail": "no prompt on the display"}
        if USE_HW:
            return {"option": "", "detail": "no tap yet"}
        # Tier-1 stub, headless: answer with the canned tap (same convention
        # as `listen`'s CANNED_TRANSCRIPT) so the demos run without a screen.
        opt = CANNED_TOUCH or self.display.options[0]
        if opt not in self.display.options:
            return {"option": "",
                    "detail": f"LEX_XLE_TOUCH '{opt}' is not one of the prompt's options"}
        return {"option": opt, "detail": "(stub, no touchscreen) canned tap"}

    def clear_display(self):
        return self.display.clear()

    # ---- split-compute vision (deploy/VISION_SPLIT.md) -------------------
    # 2D detection: capture a head-camera frame HERE (the [sense] effect
    # stays on the robot), ship the already-captured JPEG to the vision
    # service for judgment, and pass its normalized bounding box through.
    # Deliberately NOT a 3D pose: turning a box into a world position needs
    # depth or calibration this robot doesn't have — locate_object on Tier-3
    # keeps saying so rather than pretending (see that method).
    def detect_object_2d(self, name):
        if not name:
            return {"found": False, "detail": "detect_object needs a non-empty name"}
        vision_url = os.environ.get("LEX_XLE_VISION_URL", "").rstrip("/")
        if vision_url:
            frame = self.read_camera("head")
            jpeg = frame.get("jpeg_b64", "") if isinstance(frame, dict) else ""
            timeout_s = float(os.environ.get("LEX_XLE_VISION_TIMEOUT_S", "15"))
            body = json.dumps({"image_b64": jpeg, "name": name}).encode()
            req = urllib.request.Request(f"{vision_url}/vision/detect", data=body,
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=timeout_s) as resp:
                    out = json.loads(resp.read())
            except Exception as e:
                return {"found": False,
                        "detail": f"vision service unreachable at {vision_url}: {e}"}
            if not isinstance(out, dict):
                return {"found": False, "detail": "vision service returned non-object JSON"}
            out["source"] = "vision_service"
            if not jpeg:
                # The judgment was real but the frame wasn't — say so, don't
                # let a service answer imply the camera worked.
                out["detail"] = (str(out.get("detail", "")) +
                                 " (frame had no jpeg bytes — camera unavailable"
                                 " or Pillow missing)").strip()
            return out
        if USE_HW:
            return {"found": False,
                    "detail": "no LEX_XLE_VISION_URL configured — real-camera detection"
                              " needs the split-compute vision service, see"
                              " deploy/VISION_SPLIT.md"}
        # Tier-1 stub without a service: explicitly-labeled canned detection,
        # same honesty convention as locate_object's canned lookup.
        if name in CANNED_OBJECT_WORLD:
            return {"found": True, "cx": 0.62, "cy": 0.55, "w": 0.18, "h": 0.22,
                    "confidence": 1.0, "source": "stub",
                    "detail": "(stub) canned 2D detection"}
        return {"found": False, "source": "stub",
                "detail": f"(stub) unknown object '{name}' (stub knows: cup)"}

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
        # Grant workspace box: refused outright, same as a Lex program's own
        # grant check -- a position can't be safely "clamped" into an
        # envelope the way a scalar force/speed can, so this is never sent.
        denial = self._grant_workspace_violation(arm, x, y, z)
        if denial is not None:
            return {"outcome": "denied", "detail": denial}
        if USE_HW:
            missing = self._hw_arm_missing(arm)
            if missing is not None:
                return missing
            timeout_s = float(os.environ.get("LEX_XLE_ARM_TIMEOUT_S", "8"))
            tol_m = float(os.environ.get("LEX_XLE_ARM_TOL_M", "0.01"))
            return self._hw_arms[arm].move_to(x, y, z, 0.0, 0.0, 0.0, timeout_s, tol_m,
                                              collision_check=self._collision_check_for(arm))
        a = self.arms[arm]
        a["positions"] = [round(v, 3) for v in [x, y, z, 0.0, 0.0, a["positions"][5]]]
        return {"outcome": "reached", "detail": f"{arm} arm EE at ({x:.2f},{y:.2f},{z:.2f})"}

    def grasp_arm(self, arm, force):
        # Grant grip-force ceiling: clamped, never amplified -- a second,
        # independent layer above the HARD_GRIP_N firmware floor below it,
        # same two-layer defense-in-depth as everywhere else in this file.
        granted_max = self._grant_max_grip_force(arm)
        if granted_max is not None:
            force = min(force, granted_max)
        if force > HARD_GRIP_N:
            return {"outcome": "stalled", "detail": f"grip {force:.0f}N exceeds firmware limit {HARD_GRIP_N:.0f}N"}
        if arm not in ("left", "right"):
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        # Position scales against the granted max when one is configured,
        # not the (usually higher) firmware floor -- otherwise full closure
        # would be mathematically unreachable at any grant-permitted force
        # whenever the grant caps grip force below HARD_GRIP_N.
        scale_max = granted_max if granted_max is not None else HARD_GRIP_N
        if USE_HW:
            missing = self._hw_arm_missing(arm)
            if missing is not None:
                return missing
            return self._hw_arms[arm].grasp(force, scale_max)
        a = self.arms[arm]
        a["holding"] = True
        a["positions"][5] = 1.0
        return {"outcome": "reached", "detail": f"{arm} gripper closed at {force:.1f}N (firmware-capped)"}

    def release_arm(self, arm):
        if arm not in ("left", "right"):
            return {"outcome": "stalled", "detail": f"unknown arm '{arm}' (use left|right)"}
        if USE_HW:
            missing = self._hw_arm_missing(arm)
            if missing is not None:
                return missing
            return self._hw_arms[arm].release()
        a = self.arms[arm]
        was = a["holding"]
        a["holding"] = False
        a["positions"][5] = 0.0
        return {"outcome": "reached", "detail": f"{arm} released (was_holding={was})"}

    def move_base(self, x, y, speed):
        # Grant floor area: refused outright, and nothing reaches the wheels.
        # Until now this bound was declared in the capsule and checked only on
        # the Lex side, so a direct caller (the /control page, curl, the leLab
        # adapter) could drive the base straight out of the granted room. The
        # arms have had this check since the beginning; the base now matches.
        denial = self._grant_floor_violation(x, y)
        if denial is not None:
            return {"outcome": "denied", "detail": denial}
        # Speed is a scalar, so it clamps rather than refusing: the grant's
        # ceiling first, then the firmware floor beneath it -- the same
        # two-layer defense in depth grasp_arm uses, never amplifying either.
        granted_max = self._grant_max_base_speed()
        if granted_max is not None:
            speed = min(speed, granted_max)
        v = min(speed, HARD_SPEED_MPS)
        if USE_HW:
            missing = self._hw_base_missing()
            if missing is not None:
                return {"outcome": "stalled", "detail": missing["detail"]}
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
            "detail": f"base at ({x:.2f},{y:.2f}) after {dist:.2f}m at {v:.2f}m/s (capped)",
        }


class _TeachRecorder:
    """Records a hand-guided demonstration in the background.

    HTTP is request/response, so recording cannot happen inside a handler --
    the browser needs to start it, watch it, and stop it. Each sample takes
    its own arm's port lock, so recording interleaves safely with polling
    rather than corrupting the bus.
    """

    def __init__(self):
        self._thread = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.reset_state()

    def reset_state(self):
        self.traj = None
        self.error = None
        self.started_at = None
        self.arm = None

    @property
    def recording(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self, arm, name, task, tags, fps, seconds, cameras=None, free_gripper=False):
        import teach as _teach
        if self.recording:
            return {"ok": False, "detail": "already recording"}
        hw = ROBOT._hw_arms.get(arm) if USE_HW else None
        if USE_HW and hw is None:
            return {"ok": False, "detail": f"{arm} arm not configured"}
        # Default to the scene camera plus THIS arm's wrist -- the pair a vision
        # policy is normally trained on. Only slots that actually opened are
        # used, so a partial build records what it has instead of failing.
        # Freeing the gripper too means squeezing the finray fingers by hand
        # while also supporting the arm -- workable, and some people prefer it
        # to reaching for the control page mid-demonstration. The caller
        # chooses; the default keeps it powered.
        free = _teach.ARM_JOINTS if free_gripper else _teach.BODY_JOINTS
        if cameras is None:
            cameras = [c for c in ("head", arm) if c in getattr(ROBOT, "_hw_cameras", {})]
        cameras = [c for c in cameras if not USE_HW or c in getattr(ROBOT, "_hw_cameras", {})]
        self.reset_state()
        self._stop.clear()
        self.arm = arm
        self.started_at = time.time()
        self.traj = _teach.Trajectory(
            fps=fps, joints=list(_teach.ARM_JOINTS), name=name, task=task,
            tags=list(tags), arm=arm, cameras=list(cameras),
            created_at=time.strftime("%Y-%m-%dT%H:%M:%S"))
        for c in cameras:
            (self.traj.image_dir() / c).mkdir(parents=True, exist_ok=True)

        def run():
            try:
                if USE_HW:
                    with hold_port(hw.follower.config.port):
                        hw.follower.bus.disable_torque(free)
                deadline = time.time() + seconds
                period = 1.0 / fps
                origin = time.time()
                idx = 0
                while not self._stop.is_set() and time.time() < deadline:
                    t0 = time.time()
                    if USE_HW:
                        # Joints and images under ONE lock acquisition: taking
                        # it twice would let another request move the arm
                        # between the pose and the picture of it.
                        with hold_port(hw.follower.config.port):
                            obs = hw.follower.bus.sync_read("Present_Position")
                            shots = {c: ROBOT._hw_cameras[c].capture()
                                     for c in self.traj.cameras}
                        frame = [float(obs[j]) for j in _teach.ARM_JOINTS]
                        for c, img in shots.items():
                            self._write_jpeg(self.traj.image_path(c, idx), img)
                    else:
                        frame = [0.0] * len(_teach.ARM_JOINTS)
                    with self._lock:
                        self.traj.frames.append(frame)
                        self.traj.timestamps.append(t0 - origin)
                    idx += 1
                    time.sleep(max(0.0, period - (time.time() - t0)))
            except Exception as e:
                self.error = str(e)

        self._thread = threading.Thread(target=run, daemon=True)
        self._thread.start()
        return {"ok": True, "free": list(free), "cameras": list(cameras),
                "detail": f"recording {arm} arm at {fps:.0f} Hz"
                          + (f" with cameras {', '.join(cameras)}" if cameras
                             else " -- NO CAMERAS (state-only dataset)")}

    @staticmethod
    def _write_jpeg(path, image):
        import cv2
        import numpy as np
        arr = np.asarray(image)
        if arr.ndim == 3 and arr.shape[2] == 3:
            arr = cv2.cvtColor(arr, cv2.COLOR_RGB2BGR)   # OpenCVCamera hands back RGB
        cv2.imwrite(str(path), arr, [cv2.IMWRITE_JPEG_QUALITY, 85])

    def status(self):
        with self._lock:
            n = len(self.traj.frames) if self.traj else 0
        return {"recording": self.recording, "frames": n, "error": self.error,
                "arm": self.arm,
                "elapsed_s": round(time.time() - self.started_at, 1) if self.started_at else 0.0,
                "name": self.traj.name if self.traj else ""}

    def stop(self, keep_still=False):
        import teach as _teach
        if self.traj is None:
            return {"ok": False, "detail": "nothing was recorded"}
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5.0)
        with self._lock:
            traj = self.traj
        raw = len(traj.frames)
        if not keep_still:
            # Renumber the surviving images so frame i still means image i --
            # trimming the joints alone would misalign every picture.
            kept = _teach.trim_trajectory(traj)
            for cam in traj.cameras:
                d = traj.image_dir() / cam
                survivors = [(old, d / f"{old:06d}.jpg") for old in kept]
                for old, f in survivors:
                    if f.exists():
                        f.rename(d / f"tmp_{old:06d}.jpg")
                for new, (old, _f) in enumerate(survivors):
                    t = d / f"tmp_{old:06d}.jpg"
                    if t.exists():
                        t.rename(d / f"{new:06d}.jpg")
                for stale in d.glob("[0-9]*.jpg"):
                    if int(stale.stem) >= len(kept):
                        stale.unlink()
        report = _teach.validate(traj)
        path = _teach.library_dir() / (_teach.safe_name(traj.name) + ".json")
        traj.save(str(path))
        self.reset_state()
        return {"ok": True, "saved": path.name, "recorded_frames": raw,
                "detail": f"saved {path.name}", **report}


TEACH = _TeachRecorder()

ROBOT = XLeRobot()

# Every skill call's verdict, and the hash-chained record of the sequence, for
# GET /governance. Read-only: it reads what the grant checks above already
# decided and never decides anything itself (see sidecar/governance.py).
LEDGER = governance.ledger_from_env()


def _stream_sample():
    """One /stream frame: both arms' joints + the base pose.

    Goes through handle_skill rather than calling ROBOT directly, so these reads
    take the same per-port locks every other bus access does. Calling ROBOT
    straight through made /stream the one path that could interleave with
    anything else on the bus.
    """
    return {"joints": {a: handle_skill("read_joints", {"arm": a}) for a in ("left", "right")},
            "base": handle_skill("read_base", {})}


def _governance_state(raw_path):
    """One JSON payload for GET /governance: the grant as loaded, which of its
    bounds this sidecar actually checks, and the ledger + chain."""
    try:
        limit = int(urllib.parse.parse_qs(urllib.parse.urlparse(raw_path).query)
                    .get("limit", ["50"])[0])
    except ValueError:
        limit = 50
    grant = ROBOT._grant
    state = LEDGER.snapshot(limit=max(0, min(limit, 500)))
    state["grant"] = {
        "ok": bool(grant),
        "source": getattr(ROBOT, "_grant_path", None),
        "detail": getattr(ROBOT, "_grant_error", None) or ("" if grant else "no grant configured"),
        "bounds": governance.grant_enforcement(grant),
    }
    return state


# Every hardware skill touches a serial bus that is not thread-safe, and this is
# a ThreadingHTTPServer, so concurrent requests could interleave reads and writes
# on the same port. Serialising that is the server's job, not a well-behaved
# page's -- but HOW it serialises matters, and the first attempt got it wrong.
#
# A single global lock turned a LOCAL failure into a TOTAL one. When the servo
# power dropped mid-transaction, one thread wedged inside a blocking serial read
# while holding the lock; every later request -- both arms, the base, the teach
# recorder -- blocked behind it forever, and the symptom (everything hangs)
# pointed nowhere near the cause (power is off).
#
# So: one lock PER PORT, and never wait forever. Two arms on two ports proceed
# independently, and a wedged port reports itself instead of silently swallowing
# the whole sidecar.
BUS_LOCK_TIMEOUT_S = float(os.environ.get("LEX_XLE_BUS_LOCK_TIMEOUT_S", "20"))
_PORT_LOCKS = {}
_PORT_LOCKS_GUARD = threading.Lock()


def port_lock(port):
    """The lock for one serial port, created on first use."""
    with _PORT_LOCKS_GUARD:
        return _PORT_LOCKS.setdefault(port or "__none__", threading.RLock())


class BusBusy(Exception):
    """A port's lock could not be acquired in time -- almost always another
    operation wedged on that bus, not genuine contention."""


@contextlib.contextmanager
def hold_port(port, timeout=None):
    lock = port_lock(port)
    timeout = BUS_LOCK_TIMEOUT_S if timeout is None else timeout
    if not lock.acquire(timeout=timeout):
        raise BusBusy(
            f"serial port {port} was still busy after {timeout:.0f}s -- another "
            f"operation is wedged on that bus. Check servo power: a transaction "
            f"interrupted mid-flight leaves the port latched, and every later "
            f"call fails with 'Port is in use'.")
    try:
        yield
    finally:
        lock.release()


def _skill_port(name, args):
    """Which port a skill will touch, or None if it touches no bus.

    Deliberately conservative: an unrecognised skill returns None and runs
    unserialised rather than being routed to the wrong port's lock, which would
    give false safety.
    """
    if not USE_HW:
        return None
    arm = args.get("arm") if isinstance(args, dict) else None
    if name in ("teach_start", "teach_replay") and isinstance(args, dict):
        arm = args.get("arm") or arm
    if arm in ("left", "right"):
        hw = ROBOT._hw_arms.get(arm)
        return getattr(getattr(hw, "follower", None), "config", None) and hw.follower.config.port
    if name in ("move_base", "read_base"):
        base = getattr(ROBOT, "_hw_base", None)
        return getattr(getattr(base, "bus", None), "port", None)
    return None


def handle_skill(name, args):
    result = _dispatch_skill(name, args)
    # After the fact, always, including the stalled paths -- a call that wedged
    # on the bus is part of what the robot was asked to do, and a ledger that
    # only showed the successes would be a highlight reel, not an audit.
    LEDGER.record(name, args, result, grant=ROBOT._grant,
                  firmware={"max_grip_n": HARD_GRIP_N, "max_speed_mps": HARD_SPEED_MPS})
    return result


def _dispatch_skill(name, args):
    port = _skill_port(name, args)
    if port is None:
        return _handle_skill(name, args)
    try:
        with hold_port(port):
            return _handle_skill(name, args)
    except BusBusy as e:
        return {"outcome": "stalled", "ok": False, "detail": str(e)}


def _handle_skill(name, args):
    if name == "teach_start":
        return TEACH.start(args.get("arm", "left"), args.get("name", ""),
                           args.get("task", ""), args.get("tags", []),
                           float(args.get("fps", 20)), float(args.get("seconds", 120)),
                           args.get("cameras"), bool(args.get("free_gripper", False)))
    if name in ("teach_free", "teach_hold"):
        import teach as _teach
        arm = args.get("arm", "left")
        if not USE_HW:
            return {"ok": True, "detail": f"(simulated) {arm} arm would be "
                                          f"{'freed' if name == 'teach_free' else 'held'}"}
        hw = ROBOT._hw_arms.get(arm)
        if hw is None:
            return {"ok": False, "detail": f"{arm} arm not configured"}
        # Positioning the arm must NOT require starting a recording -- doing so
        # made every demonstration open with the operator repositioning.
        free = _teach.ARM_JOINTS if args.get("include_gripper") else _teach.BODY_JOINTS
        if name == "teach_free":
            hw.follower.bus.disable_torque(free)
            return {"ok": True, "free": list(free),
                    "detail": f"{arm} arm free -- move it by hand, then Lock or Set home"}
        # Hold WHERE IT IS: sync the goal to the present position first, or
        # enabling torque snaps the arm back to a stale target.
        obs = hw.follower.bus.sync_read("Present_Position")
        hw.follower.bus.sync_write("Goal_Position", obs)
        hw.follower.bus.enable_torque()
        return {"ok": True, "detail": f"{arm} arm holding where it is"}
    if name == "teach_home_set":
        import teach as _teach
        arm = args.get("arm", "left")
        if not USE_HW:
            return {"ok": True, "detail": "(simulated) home not saved without hardware"}
        hw = ROBOT._hw_arms.get(arm)
        if hw is None:
            return {"ok": False, "detail": f"{arm} arm not configured"}
        obs = hw.follower.bus.sync_read("Present_Position")
        d = _teach.save_home(arm, _teach.ARM_JOINTS, [float(obs[j]) for j in _teach.ARM_JOINTS])
        return {"ok": True, "home": d, "detail": f"saved this pose as {arm} home"}
    if name == "teach_home_get":
        import teach as _teach
        h = _teach.load_home(args.get("arm", "left"))
        return {"ok": h is not None, "home": h,
                "detail": "no home saved for this arm" if h is None else "home pose"}
    if name == "teach_home_go":
        import teach as _teach
        arm = args.get("arm", "left")
        h = _teach.load_home(arm)
        if h is None:
            return {"outcome": "refused", "detail": f"no home saved for the {arm} arm -- "
                                                    f"free it, position it, then Set home"}
        if not USE_HW:
            return {"outcome": "reached",
                    "detail": "(simulated) would move to home -- no hardware, so no "
                              "workspace check ran"}
        hw = ROBOT._hw_arms.get(arm)
        if hw is None:
            return {"outcome": "stalled", "detail": f"{arm} arm not configured"}
        denial = ROBOT._grant_trajectory_violation(arm, h["joints"], [h["positions"]])
        if denial is not None:
            return {"outcome": "denied", "detail": denial}
        return _teach.go_to(hw.follower.bus, h["joints"], h["positions"],
                            collision_check=ROBOT._collision_check_for(arm))
    if name == "teach_stop":
        return TEACH.stop(bool(args.get("keep_still", False)))
    if name == "teach_status":
        return TEACH.status()
    if name == "teach_list":
        import teach as _teach
        return {"ok": True, "recordings": _teach.library_list()}
    if name == "teach_delete":
        import teach as _teach
        f = _teach.library_dir() / (_teach.safe_name(args.get("name", "")) + ".json")
        if not f.exists():
            return {"ok": False, "detail": f"no recording named {args.get('name','')!r}"}
        f.unlink()
        return {"ok": True, "detail": f"deleted {f.name}"}
    if name == "teach_replay":
        import teach as _teach
        f = _teach.library_dir() / (_teach.safe_name(args.get("name", "")) + ".json")
        if not f.exists():
            return {"outcome": "refused", "detail": f"no recording named {args.get('name','')!r}"}
        traj = _teach.Trajectory.load(str(f))
        arm = args.get("arm") or traj.arm or "left"
        if not USE_HW:
            # Honest about what "reached" means here: the workspace check below
            # runs through the arm's kinematics model, and Tier 1 has no arm.
            # Nothing moves either, so there is nothing to bound -- but the
            # governance page must not read this as "checked and allowed".
            return {"outcome": "reached",
                    "detail": f"(simulated) would replay {len(traj.frames)} frames on the "
                              f"{arm} arm -- no hardware, so neither the workspace nor the "
                              f"speed check ran"}
        hw = ROBOT._hw_arms.get(arm)
        if hw is None:
            return {"outcome": "stalled", "detail": f"{arm} arm not configured"}
        # Check the frames that will actually be SENT, not the stored ones:
        # smooth_steps interpolates between them at replay time, and a straight
        # line in joint space can bulge outside the box in Cartesian space.
        # Same max_step_deg on both sides, so replay re-derives an identical
        # path -- checking one path and driving another proves nothing.
        step_deg = _teach.MAX_STEP_DEG
        sending = _teach.smooth_steps(traj.frames, step_deg)
        # One forward-kinematics pass, both bounds. A long recording smooths to
        # thousands of frames, and running FK over them twice would put real
        # latency in front of an arm that hasn't moved yet.
        ee_path = ROBOT._trajectory_ee_path(arm, traj.joints, sending)
        denial = ROBOT._grant_trajectory_violation(arm, traj.joints, sending, ee_path=ee_path)
        if denial is not None:
            return {"outcome": "denied", "detail": denial}
        speed, clamp = ROBOT._grant_clamp_replay_speed(
            arm, traj.joints, sending, traj.fps, float(args.get("speed", 1.0)),
            ee_path=ee_path)
        result = _teach.replay_on_bus(hw.follower.bus, traj, speed=speed,
                                      max_step_deg=step_deg,
                                      collision_check=ROBOT._collision_check_for(arm))
        if clamp is not None and isinstance(result, dict):
            # The ledger reads the verdict the sidecar reached rather than
            # re-deriving one, and this ceiling depends on the recording's
            # own kinematics, which governance.py cannot compute. So it is
            # reported here, in the reply, where classify() can read it.
            result = dict(result, clamps=[clamp],
                          detail=(result.get("detail", "") + f" (speed clamped to "
                                  f"{clamp['ceiling']:g} m/s by {clamp['bound']})").strip())
        return result
    if name == "reset":
        return ROBOT.reset()
    if name == "read_joints":
        return ROBOT.read_joints(args.get("arm", "left"))
    if name == "read_arm_pose":
        return ROBOT.read_arm_pose(args.get("arm", "left"))
    if name == "read_grant":
        return ROBOT.read_grant()
    if name == "read_base":
        return ROBOT.read_base()
    if name == "read_camera":
        return ROBOT.read_camera(args.get("name", "head"), bool(args.get("augment", False)))
    if name == "scan_ahead":
        return ROBOT.scan_ahead(args.get("question", ""))
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
    if name == "show_report":
        return ROBOT.show_report(args.get("source", ""), args.get("items", []), args.get("caption", ""))
    if name == "show_prompt":
        return ROBOT.show_prompt(args.get("question", ""), args.get("options", []))
    if name == "read_touch":
        return ROBOT.read_touch()
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
    if name == "detect_object":
        return ROBOT.detect_object_2d(args.get("name", ""))
    if name == "transform_to_arm":
        return ROBOT.transform_to_arm(float(args.get("x", 0.0)), float(args.get("y", 0.0)), float(args.get("z", 0.0)))
    return {"error": f"unknown skill: {name}"}


# ── display status strip ─────────────────────────────────────────────────────
STATUS_TTL_S = float(os.environ.get("LEX_XLE_STATUS_TTL_S", "5"))
_STATUS_CACHE = {"at": 0.0, "value": None}
_STATUS_LOCK = threading.Lock()
_STARTED_AT = time.time()


def _pi_temp_c():
    """Host SoC temperature. Free, and the first thing to look at when a Pi
    starts dropping USB frames -- thermal throttling and bus trouble arrive
    together."""
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except Exception:
        return None


def _battery_status():
    """Whether this robot can actually report a state of charge.

    On this build it cannot, and the display says so rather than implying a
    number. Two independent reasons, either one sufficient:

    1. Nothing on the host exposes a battery. /sys/class/power_supply is empty
       and the pack presents no USB HID Power Device interface, so the OS has
       no charge figure to report.
    2. The pack (an Anker power station) REGULATES its DC output. Servo rail
       voltage therefore sits flat near its nominal value regardless of state
       of charge and falls off a cliff at cutoff -- so deriving a percentage
       from it would read "full" until the robot died mid-task. Measured on
       this unit: 12.1-12.2 V, unchanged across an hour and across all 16
       servos.

    Rail voltage is still worth showing, just as a rail-health signal (is the
    supply present, is it sagging under load) rather than as a fuel gauge.

    If a supply that DOES report charge is fitted later -- a UPS HID pack, or
    an INA226 shunt on I2C -- this is the one place to teach the display about
    it.
    """
    try:
        supplies = [p for p in os.listdir("/sys/class/power_supply")
                    if not p.startswith("_")]
    except Exception:
        supplies = []
    for name in supplies:
        try:
            with open(f"/sys/class/power_supply/{name}/capacity") as f:
                return {"available": True, "percent": int(f.read().strip()), "source": name}
        except Exception:
            continue
    return {"available": False,
            "reason": "no OS battery device; pack regulates its output, so rail "
                      "voltage is not a state-of-charge signal"}


def _build_status():
    arms, notes = [], []
    rail, temps = [], []
    if USE_HW:
        for side, arm in sorted(getattr(ROBOT, "_hw_arms", {}).items()):
            entry = {"side": side}
            try:
                h = arm.read_health()
                entry.update(h)
                entry["ok"] = h.get("joints") == h.get("of")
                if "volts" in h:
                    rail.append(h["volts"])
                if "temp_c" in h:
                    temps.append(h["temp_c"])
                if not entry["ok"]:
                    notes.append(f"{side} arm: only {h.get('joints')}/{h.get('of')} joints answered")
            except BusBusy as e:
                entry.update({"ok": False, "error": "bus busy"})
                notes.append(f"{side} arm: {e}")
            except Exception as e:
                entry.update({"ok": False, "error": type(e).__name__})
                notes.append(f"{side} arm: {type(e).__name__}")
            arms.append(entry)
        for side in ("left", "right"):
            if side not in getattr(ROBOT, "_hw_arms", {}):
                notes.append(f"{side} arm not configured")
    cams = sorted(getattr(ROBOT, "_hw_cameras", {})) if USE_HW else []
    return {
        "ok": all(a.get("ok") for a in arms) if arms else not USE_HW,
        "mode": "hardware" if USE_HW else "stub",
        "uptime_s": int(time.time() - _STARTED_AT),
        "arms": arms,
        "cameras": cams,
        "rail_v": round(sum(rail) / len(rail), 1) if rail else None,
        "servo_temp_c": max(temps) if temps else None,
        "pi_temp_c": _pi_temp_c(),
        "battery": _battery_status(),
        "notes": notes,
    }


def status_snapshot():
    """Cached so the kiosk page polling every second cannot flood the servo
    bus -- the strip is ambient information, not telemetry."""
    now = time.time()
    with _STATUS_LOCK:
        cached = _STATUS_CACHE["value"]
        if cached is not None and (now - _STATUS_CACHE["at"]) < STATUS_TTL_S:
            return cached
    fresh = _build_status()
    with _STATUS_LOCK:
        _STATUS_CACHE["at"], _STATUS_CACHE["value"] = time.time(), fresh
    return fresh


def _perimeter_status():
    """What is actually holding the door, so `/health` answers it rather than
    the reader having to infer it from which env vars they remember setting."""
    return {
        "bind": HOST if SOCKET_PATH is None else f"{HOST} + unix:{SOCKET_PATH}",
        "token_auth": perimeter.configured_token() is not None,
        "peer_allow_list": bool(os.environ.get(perimeter.ALLOW_UIDS_ENV)
                                or os.environ.get(perimeter.ALLOW_GIDS_ENV)),
    }


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

    def _peer_creds(self):
        """Who is on the other end -- only answerable over a unix socket."""
        if self.server.address_family != socket.AF_UNIX:
            return None
        return perimeter.peer_credentials(self.connection)

    def _authorize(self, skill):
        """None when this caller may make this call, else the refusal reason.

        Two independent gates, answering two different questions (microduck,
        architecture.md §2.2): the token says whether the CALLER is known, the
        peer allow-list says whether that uid may CHANGE the robot. Both are
        off unless configured; both ignore read-only skills.
        """
        reason = perimeter.check_token(self.headers.get("Authorization"), skill)
        if reason is not None:
            return reason
        return perimeter.peer_allowed(self._peer_creds(), skill)

    def do_POST(self):
        args = self._body()
        if args is None:
            return self._send(400, {"error": "invalid json"})
        if self.path == "/heartbeat":
            # Arms the base deadman on the first beat and keeps it clear after
            # that (#195). Deliberately NOT a skill: a governed program does
            # not ask permission to still be alive, and gating liveness behind
            # the grant would mean a caller could lose the ability to say so.
            DEADMAN.beat()
            return self._send(200, {"ok": True, "deadman": DEADMAN.status()})
        if self.path.startswith("/skill/"):
            skill = self.path[len("/skill/"):]
            refusal = self._authorize(skill)
            if refusal is not None:
                # 403, and the same `denied` vocabulary the grant uses: this is
                # an envelope saying no, not the arm failing to get there.
                return self._send(403, {"outcome": "denied", "ok": False,
                                        "detail": f"perimeter: {refusal}"})
            # Any skill call is evidence the caller is still there. An explicit
            # /heartbeat is only needed DURING a long move_base, which blocks
            # its own connection -- hence ThreadingHTTPServer.
            DEADMAN.beat_if_armed()
            return self._send(200, handle_skill(skill, args))
        if self.path == "/display/touch":
            # The kiosk page's tap comes back here, NOT through /skill/: a
            # human tapping the screen is input arriving at the sidecar, not
            # a skill the governed program invoked. The program only ever
            # sees it through read_touch, behind its own grant gate.
            return self._send(200, ROBOT.display.record_touch(
                str(args.get("option", "")), args.get("version", -1)))
        return self._send(404, {"error": "not found"})

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/stream":
            # The streaming state channel (SIDECAR.md): joint + base state as
            # WebSocket text frames at LEX_STREAM_HZ, consumed in Lex via
            # net.dial_ws — see examples/stream_demo.lex.
            from sidecar_lib import maybe_stream
            if maybe_stream(self, _stream_sample,
                            hz=float(os.environ.get("LEX_STREAM_HZ", "10")),
                            max_frames=int(os.environ.get("LEX_STREAM_MAX_FRAMES", "0"))):
                return
            return self._send(400, {"error": "/stream requires a WebSocket upgrade"})
        if path == "/health":
            return self._send(200, {"ok": True, "hardware": USE_HW, "base": ROBOT.base,
                                    "deadman": DEADMAN.status(),
                                    "perimeter": _perimeter_status()})
        if path == "/display":
            return self._send_bytes(200, "text/html; charset=utf-8", DISPLAY_PAGE_HTML.encode())
        if path == "/teach":
            return self._send_bytes(200, "text/html; charset=utf-8", TEACH_PAGE_HTML.encode())
        if path == "/control":
            return self._send_bytes(200, "text/html; charset=utf-8", CONTROL_PAGE_HTML.encode())
        if path == "/governance":
            return self._send_bytes(200, "text/html; charset=utf-8", GOVERNANCE_PAGE_HTML.encode())
        if path == "/governance/state":
            return self._send(200, _governance_state(self.path))
        if path == "/governance/trail":
            # The retained window as a lex-trail chain. Whatever LEX_XLE_TRAIL_PATH
            # holds is the complete record; this is what is still in memory.
            return self._send_bytes(200, "application/json; charset=utf-8",
                                    LEDGER.chain.to_json().encode())
        if path == "/display/state":
            return self._send(200, ROBOT.display.to_json())
        if path == "/display/status":
            return self._send(200, status_snapshot())
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


class _UnixHTTPServer(ThreadingHTTPServer):
    """The same Handler, over a unix socket.

    This is where microduck's argument actually lands (architecture.md §2.2):
    filesystem permissions are free authorization, and `SO_PEERCRED` names the
    caller for both the audit and the allow-list. A TCP port on loopback is
    reachable by every process and user on the box; a socket at mode 0660 with
    a dedicated group is not.

    The Lex client cannot use this yet -- `std.http` and `net.*` take an `Int`
    port and lex 0.10.11 has no unix-socket client, which is a lex-lang change
    and a coordinated release (#196). So this serves the local NON-Lex clients:
    the Python tools in this directory, an operator's `curl --unix-socket`, and
    whatever `robotctl` becomes.
    """

    address_family = socket.AF_UNIX

    def server_bind(self):
        # A leftover socket file from a killed process would make bind() fail
        # with EADDRINUSE forever. Only ours is removed: the path is one we
        # were told to own.
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.server_address)
        super().server_bind()
        # Group-readable/writable, world-nothing. This is the "who may TALK to
        # the daemon" layer; the uid allow-list is the "who may CHANGE the
        # robot" layer above it.
        os.chmod(self.server_address, 0o660)

    def get_request(self):
        conn, _addr = self.socket.accept()
        # BaseHTTPRequestHandler wants a (host, port) shaped peer for logging;
        # AF_UNIX has none, so give it something honest instead of ''.
        return conn, ("unix-socket", 0)


def _serve_unix_socket():
    """Start the unix-socket listener in a daemon thread, or return None."""
    if not SOCKET_PATH:
        return None
    srv = _UnixHTTPServer(SOCKET_PATH, Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main():
    mode = "REAL HARDWARE" if USE_HW else "stub (no hardware)"
    # Before anything binds. A robot that actuates on an unauthenticated port
    # must not be one interface-typo away from the network (#196).
    perimeter.assert_loopback(HOST)
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    unix_srv = _serve_unix_socket()
    print(f"lex-robot XLeRobot sidecar [{mode}] on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    if unix_srv is not None:
        print(f"  also on unix:{SOCKET_PATH} (mode 0660; SO_PEERCRED identifies callers)")
    # Say what is and is not holding the door, every start. An operator who
    # believes the token is on when it is not is worse off than one who knows
    # it is off.
    st = _perimeter_status()
    if not st["token_auth"] and not st["peer_allow_list"]:
        print("  perimeter: UNAUTHENTICATED — any local process may drive this robot. "
              "Set LEX_ROBOT_SIDECAR_TOKEN (and/or LEX_ROBOT_SIDECAR_ALLOW_UIDS) to gate "
              "the skills that move it.")
    else:
        print(f"  perimeter: token_auth={st['token_auth']} "
              f"peer_allow_list={st['peer_allow_list']} (mutating skills only)")
    if st["token_auth"]:
        # Said out loud, because the alternative is discovering it as a wave of
        # 403s from a program that looks correct. client.lex cannot send a
        # bearer token without widening every skill's effect row with [env] —
        # see SIDECAR.md, "The perimeter".
        print("  NOTE: Lex programs using src/client.lex do NOT send a bearer token, "
              "so they will be refused on mutating skills while this is set.")
    dm = DEADMAN.status()
    if dm["interval_ms"]:
        print(f"  deadman: {dm['interval_ms']}ms — arms on the first POST /heartbeat, "
              f"then stops base motion if the beats stop. Arm hold is never dropped.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
        if unix_srv is not None:
            unix_srv.shutdown()
            with contextlib.suppress(FileNotFoundError):
                os.unlink(SOCKET_PATH)


if __name__ == "__main__":
    main()
