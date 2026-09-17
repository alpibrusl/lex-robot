"""Vision-driven self-resetting pick-and-place — demonstrations that vary.

`scripted_teleop.ScriptedArmTeleop` replays one fixed trajectory, so a policy
cloned from it learns that trajectory and nothing else. The object has to
start somewhere different each episode, and normally a human moves it.

This closes that loop instead: the robot places the object at a RANDOM target
each episode, so the next episode's detection finds it somewhere new. Nobody
moves anything. Per episode:

    head camera frame -> vision_service /vision/detect -> normalized 2D box
      -> project_to_plane (pinhole, against a calibrated table plane)
      -> world (x, y, z) -> IK -> joint waypoints for THIS episode

Refusal, not guessing. `project_to_plane` is a faithful port of `src/camera.lex`
and refuses a ray parallel to the plane or an intersection behind the camera
(the Lex examples are re-asserted in test_vision_reset_teleop.py). A detection
below `min_confidence`, a refused projection, or a failed IK solve all yield
NO trajectory: the arm holds its home pose for that episode and the reason is
logged. A demonstration built on a guessed position is worse than no episode.

Units: IK returns DEGREES, and lerobot's `use_degrees` defaults to True, so the
default path needs no conversion. Run the robot with `--robot.use_degrees=true`
(the default) when using this teleop.
"""

from __future__ import annotations

import base64
import json
import logging
import random
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from lerobot.teleoperators.config import TeleoperatorConfig

from scripted_teleop import BODY, JOINTS, ScriptedArmTeleop, ScriptedArmTeleopConfig

logger = logging.getLogger(__name__)


# ── pinhole projection: a port of src/camera.lex ────────────────────────────

@dataclass
class CameraModel:
    """Calibration data: where the camera sits and how it looks at the world.

    Orientation is supplied as world-frame basis vectors (no trig — calibration
    provides them), exactly as in src/camera.lex.
    """
    pos: tuple[float, float, float]
    right: tuple[float, float, float]
    down: tuple[float, float, float]
    forward: tuple[float, float, float]
    fx: float
    fy: float
    cx0: float
    cy0: float
    # Brown-Conrady lens distortion, zero for an ideal lens. Default to zero so
    # a calibration written before these existed loads unchanged and behaves
    # exactly as it used to.
    k1: float = 0.0
    k2: float = 0.0
    k3: float = 0.0
    p1: float = 0.0
    p2: float = 0.0

    @staticmethod
    def from_json(path: str) -> "CameraModel":
        d = json.loads(Path(path).read_text())
        return CameraModel(
            pos=tuple(d["pos"]), right=tuple(d["right"]), down=tuple(d["down"]),
            forward=tuple(d["forward"]), fx=float(d["fx"]), fy=float(d["fy"]),
            cx0=float(d["cx0"]), cy0=float(d["cy0"]),
            k1=float(d.get("k1", 0.0)), k2=float(d.get("k2", 0.0)),
            k3=float(d.get("k3", 0.0)), p1=float(d.get("p1", 0.0)),
            p2=float(d.get("p2", 0.0)),
        )

    def undistort(self, xd: float, yd: float) -> tuple[float, float]:
        """Inverse Brown-Conrady, by the standard fixed-point iteration.

        Must stay in lockstep with src/camera.lex's `undistort` -- same model,
        same eight steps, same results. Matched against OpenCV's
        `undistortPoints` on this camera's measured coefficients to better than
        1e-8. Ignoring distortion costs a median 3.0 px and up to 8.4 px on this
        unit, ~9 mm of world error at 400 mm of reach.
        """
        if self.k1 == self.k2 == self.k3 == self.p1 == self.p2 == 0.0:
            return xd, yd
        x, y = xd, yd
        for _ in range(8):
            r2 = x * x + y * y
            radial = 1.0 + self.k1 * r2 + self.k2 * r2 * r2 + self.k3 * r2 * r2 * r2
            dx = 2.0 * self.p1 * x * y + self.p2 * (r2 + 2.0 * x * x)
            dy = self.p1 * (r2 + 2.0 * y * y) + 2.0 * self.p2 * x * y
            x, y = (xd - dx) / radial, (yd - dy) / radial
        return x, y

    def ray_direction(self, u: float, v: float) -> tuple[float, float, float]:
        ru, dv = self.undistort((u - self.cx0) / self.fx, (v - self.cy0) / self.fy)
        return tuple(
            self.forward[i] + self.right[i] * ru + self.down[i] * dv for i in range(3)
        )

    def project_to_plane(self, u: float, v: float, plane_z: float) -> tuple[float, float, float]:
        """Intersect the (u, v) pixel ray with the horizontal plane z = plane_z.

        Raises ValueError rather than returning a guessed point — the same
        contract as src/camera.lex's Result[Vec3, Str].
        """
        d = self.ray_direction(u, v)
        if d[2] == 0.0:
            raise ValueError("pixel ray is parallel to the calibrated plane")
        t = (plane_z - self.pos[2]) / d[2]
        if t <= 0.0:
            raise ValueError("the calibrated plane is behind the camera ray")
        return tuple(self.pos[i] + d[i] * t for i in range(3))


# ── the teleoperator ────────────────────────────────────────────────────────

@TeleoperatorConfig.register_subclass("vision_reset")
@dataclass
class VisionResetTeleopConfig(ScriptedArmTeleopConfig):
    """Config for the vision-driven self-resetting expert.

    Attributes:
        waypoints_path: anchor-based timing template (see
            sidecar/waypoints_vision_reset.json) — phases, durations and
            gripper values; the xyz comes from vision.
        camera_calib_path: CameraModel JSON. Required — there is no sane
            default for where your camera is.
        urdf_path: SO-101 URDF for IK. Required.
        vision_url: vision_service base URL.
        object_name: what to ask /vision/detect for.
        plane_z: height of the work surface in the arm frame (metres).
        min_confidence: detections below this are refused, not used.
        ik_tolerance_m: how close the solved pose must put the end-effector.
        ik_max_iters: give up (and drop the episode) after this many
            differential IK steps.
        place_region: [[x0,x1],[y0,y1]] box the object is dropped into,
            sampled per episode. This is what makes the loop self-resetting.
        camera_index: OpenCV index of the head camera.
    """

    camera_calib_path: str = ""
    urdf_path: str = ""
    vision_url: str = "http://127.0.0.1:8901"
    object_name: str = "cup"
    plane_z: float = 0.0
    min_confidence: float = 0.6
    place_region: list[list[float]] = field(default_factory=lambda: [[0.18, 0.32], [-0.12, 0.12]])
    camera_index: int = 0
    vision_timeout_s: float = 60.0
    target_frame: str = "gripper_frame_link"
    ik_tolerance_m: float = 0.002
    ik_max_iters: int = 40


class VisionResetTeleop(ScriptedArmTeleop):
    config_class = VisionResetTeleopConfig
    name = "vision_reset"

    def __init__(self, config: VisionResetTeleopConfig):
        super().__init__(config)
        self.config = config
        if not config.camera_calib_path:
            raise ValueError("vision_reset needs --teleop.camera_calib_path (a CameraModel JSON)")
        if not config.urdf_path:
            raise ValueError("vision_reset needs --teleop.urdf_path (the SO-101 URDF, for IK)")
        self.camera = CameraModel.from_json(config.camera_calib_path)
        self._kin = None
        self._home = {j: float(self._steps[0]["pose"][j]) for j in JOINTS}
        self._last_place: tuple[float, float, float] | None = None
        self._grabber = None      # injectable for tests: () -> frame

    # -- lazily-built collaborators, so tests can construct without hardware --

    def _kinematics(self):
        if self._kin is None:
            from lerobot.model.kinematics import RobotKinematics
            self._kin = RobotKinematics(
                urdf_path=self.config.urdf_path,
                target_frame_name=self.config.target_frame,
                joint_names=BODY,
            )
        return self._kin

    def _grab_frame(self):
        if self._grabber is not None:
            return self._grabber()
        import cv2
        cap = cv2.VideoCapture(self.config.camera_index, cv2.CAP_AVFOUNDATION)
        ok, frame = cap.read()
        cap.release()
        if not ok or frame is None:
            raise RuntimeError(f"head camera index {self.config.camera_index} gave no frame")
        return frame

    # -- the vision -> world -> joints chain ---------------------------------

    def detect_world_pose(self) -> tuple[float, float, float]:
        """Where the object is, in the arm frame. Raises rather than guessing."""
        import cv2

        frame = self._grab_frame()
        ok, buf = cv2.imencode(".jpg", frame)
        if not ok:
            raise RuntimeError("could not JPEG-encode the head camera frame")
        payload = json.dumps({
            "image_b64": base64.b64encode(buf.tobytes()).decode(),
            "name": self.config.object_name,
        }).encode()
        req = urllib.request.Request(
            f"{self.config.vision_url.rstrip('/')}/vision/detect",
            data=payload, headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=self.config.vision_timeout_s) as r:
            det = json.loads(r.read())

        if not det.get("found"):
            raise ValueError(f"{self.config.object_name!r} not found in frame")
        conf = float(det.get("confidence", 0.0))
        if conf < self.config.min_confidence:
            raise ValueError(
                f"detection confidence {conf:.2f} below floor {self.config.min_confidence:.2f}"
            )
        # cx/cy are the box centre, normalized 0..1 — vision_service's contract.
        return self.camera.project_to_plane(
            float(det["cx"]), float(det["cy"]), self.config.plane_z
        )

    def solve_joints(self, xyz, seed_deg) -> dict[str, float]:
        """Position-only IK, iterated to convergence.

        lerobot's `RobotKinematics.inverse_kinematics` calls placo's
        `solver.solve()` exactly ONCE, and placo is a differential IK solver —
        one call is a single descent step, not a solution. A single call
        leaves the seed essentially untouched (~8 cm of error on a 5 cm move).
        Feeding the result back converges in a handful of iterations.

        orientation_weight=0 keeps the problem well-posed: a 5-DOF arm cannot
        generally reach an arbitrary orientation, so only position is
        constrained. Raises if it does not converge — the caller drops the
        episode rather than commanding a pose that misses the object.
        """
        kin = self._kinematics()
        pose = np.eye(4)
        pose[:3, 3] = np.asarray(xyz, dtype=float)
        q = np.asarray(seed_deg, dtype=float)
        for _ in range(self.config.ik_max_iters):
            q = kin.inverse_kinematics(q, pose, position_weight=1.0, orientation_weight=0.0)
            err = float(np.linalg.norm(kin.forward_kinematics(q)[:3, 3] - pose[:3, 3]))
            if err <= self.config.ik_tolerance_m:
                return {j: float(q[i]) for i, j in enumerate(BODY)}
        raise ValueError(
            f"IK did not converge for {tuple(round(v, 4) for v in xyz)}: "
            f"{err:.4f} m > {self.config.ik_tolerance_m} m after "
            f"{self.config.ik_max_iters} iterations (target likely out of reach)"
        )

    # -- one episode's waypoints --------------------------------------------

    def _poses_for_cycle(self, cycle: int) -> list[dict[str, float]]:
        rng = random.Random(self.config.seed + cycle)
        try:
            pick = self.detect_world_pose()
        except Exception as e:
            logger.warning("episode %d: no trajectory — %s; holding home pose", cycle, e)
            return [dict(self._home) for _ in self._steps]

        (x0, x1), (y0, y1) = self.config.place_region
        place = (rng.uniform(x0, x1), rng.uniform(y0, y1), self.config.plane_z)

        anchors = {"pick": pick, "place": place, "home": None}
        seed = [self._home[j] for j in BODY]
        poses: list[dict[str, float]] = []
        for step in self._steps:
            anchor = step.get("anchor", "home")
            if anchor == "home":
                pose = dict(self._home)
            else:
                base = anchors[anchor]
                target = (base[0], base[1], base[2] + float(step.get("dz", 0.0)))
                try:
                    pose = self.solve_joints(target, seed)
                except Exception as e:
                    logger.warning(
                        "episode %d: IK failed at %r %s — holding home pose", cycle, step.get("name"), e
                    )
                    return [dict(self._home) for _ in self._steps]
                seed = [pose[j] for j in BODY]
            pose["gripper"] = float(step["pose"]["gripper"])
            poses.append(pose)

        self._last_place = place
        logger.info(
            "episode %d: pick (%.3f, %.3f, %.3f) -> place (%.3f, %.3f, %.3f)",
            cycle, *pick, *place,
        )
        return poses
