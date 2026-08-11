# XLeRobot Arm Control Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a browser control panel, served directly by `sidecar/xlerobot_sidecar.py`, to watch and jog both XLeRobot arms in real time.

**Architecture:** One new skill (`read_arm_pose`, stub + hardware branches) exposes the Cartesian end-effector position the existing `read_joints` skill doesn't provide. One new route (`GET /control`) serves a self-contained inline HTML+JS page — same pattern the file already uses for `GET /display` — that polls `read_joints`/`read_arm_pose` and drives `move_arm`/`grasp_arm`/`release_arm`.

**Tech Stack:** Python 3 stdlib (`http.server`) on the backend, no new dependencies. Vanilla HTML/CSS/JS on the frontend, no build step, no framework.

## Global Constraints

- No CORS setup, no separate server process, no build step — the page is an inline string constant served by the existing `Handler`, exactly like `DISPLAY_PAGE_HTML`/`GET /display`.
- Skill JSON responses stay compact (`json.dumps(..., separators=(",", ":"))`) — this is existing `Handler._send` behavior; don't change it.
- `read_arm_pose` must work on all three tiers the sidecar supports (stub, and hardware — MuJoCo sim isn't part of this file, so only those two matter here).
- The page's "Enable control" checkbox is a **client-side-only** convenience gate, not a safety system — the page must say so explicitly in visible text. It must not be implemented as, or described as, a substitute for the sidecar's existing `LEX_XLE_MAX_REL_TARGET` clamp, Lex grants, or hardware e-stop.
- Docs (`SIDECAR.md`, the module docstring) are updated last, after the code is written and verified — not before (this repo's established convention: code first, then docs, no aspirational doc edits).
- Per-joint jogging and base controls are explicitly out of scope — don't add them.
- **Amendment 2026-08-11** (see the spec's "Amendment" section): the camera
  feed, originally deferred, is now in scope — the user connected left/right
  cameras mid-implementation and asked for them on the page. This added
  Task 3 (multi-camera backend) below and expanded what's now Task 4 (the
  page) to include camera panels; the rest of the plan is unchanged.

---

### Task 1: `read_arm_pose` skill — stub tier

**Files:**
- Modify: `sidecar/xlerobot_sidecar.py` — add `XLeRobot.read_arm_pose` method (near `XLeRobot.read_joints`, currently at line 855), register in `handle_skill()` (near line 1027-1028).
- Test: `sidecar/test_xlerobot_hw.py`

**Interfaces:**
- Produces: `XLeRobot.read_arm_pose(self, arm: str) -> dict` — returns `{"ok": True, "x": float, "y": float, "z": float}` on the stub tier, or (once Task 2 lands) delegates to `_HwArm.read_pose()` on hardware. Unknown `arm` values fall back to `"left"`, matching `read_joints`'s existing behavior at line 857.
- Consumes: `self.arms[arm]["positions"]` (already set by `move_arm`, see line 978) on the stub tier.

- [ ] **Step 1: Add the stub-tier method**

In `sidecar/xlerobot_sidecar.py`, right after the existing `read_joints` method (ends at line 863, right before `def read_base(self):` at line 865), add:

```python
    def read_arm_pose(self, arm):
        if USE_HW:
            return self._hw_arms[arm if arm in self._hw_arms else "left"].read_pose()
        a = self.arms.get(arm, self.arms["left"])
        x, y, z = a["positions"][:3]
        return {"ok": True, "x": x, "y": y, "z": z}
```

(`self._hw_arms[...].read_pose()` doesn't exist yet — that's Task 2. This is fine to write now; it's only reached when `USE_HW` is true, which the stub-tier tests below never trigger.)

- [ ] **Step 2: Register the skill**

In `handle_skill()`, right after:
```python
    if name == "read_joints":
        return ROBOT.read_joints(args.get("arm", "left"))
```
add:
```python
    if name == "read_arm_pose":
        return ROBOT.read_arm_pose(args.get("arm", "left"))
```

- [ ] **Step 3: Write the failing tests**

In `sidecar/test_xlerobot_hw.py`, add (near the other `XLeRobot()`-based tests, e.g. after `test_stub_scan_qr_before_any_render_is_empty`):

```python
def test_read_arm_pose_stub_matches_last_moved_position():
    robot = XLeRobot()
    robot.move_arm("left", 0.3, 0.1, 0.2)
    assert robot.read_arm_pose("left") == {"ok": True, "x": 0.3, "y": 0.1, "z": 0.2}


def test_read_arm_pose_stub_unknown_arm_falls_back_to_left():
    robot = XLeRobot()
    robot.move_arm("left", 0.25, 0.05, 0.15)
    assert robot.read_arm_pose("nonsense") == {"ok": True, "x": 0.25, "y": 0.05, "z": 0.15}


def test_read_arm_pose_stub_defaults_to_origin_before_any_move():
    robot = XLeRobot()
    assert robot.read_arm_pose("right") == {"ok": True, "x": 0.0, "y": 0.0, "z": 0.0}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `cd sidecar && python3 -m pytest test_xlerobot_hw.py -v -k read_arm_pose`
Expected: 3 passed (the method already exists from Step 1, so this confirms correctness, not just presence — if it fails, re-check Step 1's slicing/fallback logic).

- [ ] **Step 5: Run the full existing suite to confirm no regressions**

Run: `cd sidecar && python3 -m pytest test_xlerobot_hw.py -v`
Expected: all tests pass (17 pre-existing + 3 new = 20).

- [ ] **Step 6: Commit**

```bash
git add sidecar/xlerobot_sidecar.py sidecar/test_xlerobot_hw.py
git commit -m "xlerobot: add read_arm_pose skill (stub tier)"
```

---

### Task 2: `read_arm_pose` skill — hardware tier

**Files:**
- Modify: `sidecar/xlerobot_sidecar.py` — add `_HwArm.read_pose` method.

**Interfaces:**
- Consumes: `self._forward_kinematics_ee(joints)` (existing method on `_HwArm`, returns `(x, y, z)` tuple or `None`), `self.follower.get_observation()` (existing lerobot call), `ARM_JOINTS` (existing module-level list).
- Produces: `_HwArm.read_pose(self) -> dict` — `{"ok": True, "x": float, "y": float, "z": float}` or `{"ok": False, "detail": str}`. Called by `XLeRobot.read_arm_pose` from Task 1.

- [ ] **Step 1: Add the method**

In `sidecar/xlerobot_sidecar.py`, in the `_HwArm` class, right after `read_joints` (ends at line 319, right before `def move_to(self, x, y, z, rx, ry, rz, timeout_s, tol_m):` at line 321), add:

```python
    def read_pose(self):
        obs = self.follower.get_observation()
        joints = {f"{j}.pos": obs[f"{j}.pos"] for j in ARM_JOINTS}
        ee = self._forward_kinematics_ee(joints)
        if ee is None:
            return {
                "ok": False,
                "detail": "no Cartesian FK available (URDF/placo not configured, or this "
                          "lerobot install's kinematics module doesn't match)",
            }
        x, y, z = ee
        return {"ok": True, "x": x, "y": y, "z": z}
```

- [ ] **Step 2: Syntax-check**

Run: `python3 -c "import ast; ast.parse(open('sidecar/xlerobot_sidecar.py').read())" && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify against real hardware**

This can't be unit-tested (it's a thin wrapper over live hardware I/O already exercised by `move_to`'s settle check). Verify directly against the connected arms, same pattern used earlier this session:

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot && source .venv/bin/activate
LEX_XLE_URDF_PATH=/home/alpibru/.cache/lex-robot/so-arm100/Simulation/SO101/so101_new_calib.urdf \
python3 - <<'EOF'
import sys
sys.path.insert(0, "sidecar")
import xlerobot_sidecar as xs

for side, port, robot_id in [("left", "/dev/ttyACM0", "xle_left"), ("right", "/dev/ttyACM1", "xle_right")]:
    arm = xs._HwArm(side, port, robot_id, max_relative_target=None)
    print(side, arm.read_pose())
    arm.follower.disconnect()
EOF
```

Expected: both arms print `{'ok': True, 'x': <float>, 'y': <float>, 'z': <float>}` with plausible values (consistent with the FK readings already seen this session, e.g. left arm x≈0.35-0.4, not `ok: False` and not a crash).

- [ ] **Step 4: Run the full test suite to confirm no regressions**

Run: `cd sidecar && python3 -m pytest test_xlerobot_hw.py -v`
Expected: all 20 tests still pass (this task adds no new stub-testable behavior, just the hardware branch).

- [ ] **Step 5: Commit**

```bash
git add sidecar/xlerobot_sidecar.py
git commit -m "xlerobot: add read_arm_pose skill (hardware tier)"
```

---

### Task 3: Multi-camera backend

**Files:**
- Modify: `sidecar/xlerobot_sidecar.py` — replace the single eager `self._hw_camera` with per-slot best-effort cameras; fix `read_camera` to dispatch by name.

**Interfaces:**
- Consumes: `_HwCamera` (existing class, unchanged — `_HwCamera(index)` raises on failure, `.read()` returns `{"width","height","jpeg_b64"}`, `.disconnect()`).
- Produces: `XLeRobot.read_camera(self, name) -> dict` — `{"width","height","jpeg_b64"}` on success, `{"error": str}` when `name` isn't a configured/available camera. Consumed by Task 4's frontend.

Amendment 2026-08-11 (see spec's "Amendment" section): this task exists
because the user connected two real cameras and the existing single-camera
code can't address them by name. This also fixes a latent fragility: today,
hardware-tier startup unconditionally tries to open camera index 0 and
crashes the whole sidecar if it fails — camera construction becomes
best-effort per slot instead.

- [ ] **Step 1: Replace the single-camera construction with per-slot best-effort construction**

Find where `self._hw_camera` is currently built unconditionally (search for `self._hw_camera = _HwCamera(int(os.environ.get("LEX_XLE_CAMERA_INDEX", "0")))` — inside the `USE_HW` branch of `XLeRobot.__init__`, alongside where `self._hw_arms` and `self._hw_base` are built). Replace it with:

```python
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
```

Find every other reference to `self._hw_camera` in the file (there is a disconnect path and a `scan_qr` path that use it — search for `_hw_camera` to find them) and update each: the disconnect path should iterate `self._hw_cameras.values()` calling `.disconnect()` on each; the `scan_qr` path (`_hw_scan_qr(self._hw_camera, ...)`) should use a specific named camera — use `self._hw_cameras.get("head")` there, and if that's `None`, return the same "not available" outcome shape `_hw_scan_qr` already returns when the camera itself fails (check `_hw_scan_qr`'s existing signature and current error handling before wiring this — match its existing conventions rather than inventing a new one).

- [ ] **Step 2: Fix `read_camera` to dispatch by name**

Find:
```python
    def read_camera(self, name):
        if USE_HW:
            return self._hw_camera.read()
        return {"width": 640, "height": 480, "jpeg_b64": ""}
```

Replace with:
```python
    def read_camera(self, name):
        if USE_HW:
            cam = self._hw_cameras.get(name)
            if cam is None:
                return {"error": f"camera '{name}' not configured or unavailable"}
            return cam.read()
        return {"width": 640, "height": 480, "jpeg_b64": ""}
```

- [ ] **Step 3: Add the new env vars to the module docstring**

Near the existing `LEX_XLE_CAMERA_INDEX` line in the module docstring, document the three new/renamed env vars (`LEX_XLE_CAMERA_HEAD_INDEX`, `LEX_XLE_CAMERA_LEFT_INDEX`, `LEX_XLE_CAMERA_RIGHT_INDEX`) and note `LEX_XLE_CAMERA_INDEX` still works as an alias for `LEX_XLE_CAMERA_HEAD_INDEX`.

- [ ] **Step 4: Syntax-check**

Run: `python3 -c "import ast; ast.parse(open('sidecar/xlerobot_sidecar.py').read())" && echo OK`
Expected: `OK`

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `cd sidecar && python3 -m pytest test_xlerobot_hw.py -v`
Expected: all pre-existing + Task 1's tests still pass (this task doesn't add stub-tier-testable behavior — the stub branch of `read_camera` is untouched).

- [ ] **Step 6: Verify against the real cameras**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot && source .venv/bin/activate
sg video -c "bash -c '
LEX_XLE_LEFT_PORT=/dev/ttyACM0 LEX_XLE_RIGHT_PORT=/dev/ttyACM1 \
  LEX_XLE_URDF_PATH=/home/alpibru/.cache/lex-robot/so-arm100/Simulation/SO101/so101_new_calib.urdf \
  LEX_XLE_CAMERA_LEFT_INDEX=4 LEX_XLE_CAMERA_RIGHT_INDEX=6 \
  LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py &
SIDECAR_PID=\$!
sleep 2
curl -s -X POST http://127.0.0.1:8900/skill/read_camera -d \"{\\\"name\\\":\\\"left\\\"}\" | head -c 200
echo
curl -s -X POST http://127.0.0.1:8900/skill/read_camera -d \"{\\\"name\\\":\\\"right\\\"}\" | head -c 200
echo
curl -s -X POST http://127.0.0.1:8900/skill/read_camera -d \"{\\\"name\\\":\\\"head\\\"}\"
kill \$SIDECAR_PID
'"
```

Expected: `left` and `right` each return `{"width":640,"height":480,"jpeg_b64":"..."}` with a long non-empty base64 string; `head` returns `{"error":"camera '"'"'head'"'"' not configured or unavailable"}` (no `LEX_XLE_CAMERA_HEAD_INDEX` set on this rig — expected, not a bug). Note the `sg video -c` wrapper: this shell session's process predates the `video` group being added to this user, so camera opens need the `sg video` wrapper (or a fresh terminal) exactly like the diagnostic session earlier — plain `bash -c` without it will fail with `Permission denied` on `/dev/video4`/`/dev/video6`, not a code problem.

- [ ] **Step 7: Commit**

```bash
git add sidecar/xlerobot_sidecar.py
git commit -m "xlerobot: multi-camera support (head/left/right slots, fix read_camera dispatch)"
```

---

### Task 4: `/control` page

**Files:**
- Modify: `sidecar/xlerobot_sidecar.py` — make `LEX_XLE_BASE_PORT` optional in `_bring_up_hardware` (see Step 1), add `CONTROL_PAGE_HTML` constant (near `DISPLAY_PAGE_HTML`, currently defined at line 737), add the `/control` route in `Handler.do_GET` (near line 1108-1109).

**Interfaces:**
- Consumes: `read_joints`, `read_arm_pose` (Tasks 1-2), `read_camera` (Task 3 — called with `{"name": arm}`, i.e. `"left"`/`"right"`, matching the camera slot names Task 3 wires up), `move_arm`, `grasp_arm`, `release_arm` (existing skills) — all via `POST /skill/<name>`, same-origin `fetch()`.
- Produces: `GET /control` — serves the page. No other code depends on this.

Amendment 2026-08-11: Task 3's implementer confirmed a real, previously-flagged
risk — `_bring_up_hardware` unconditionally requires `LEX_XLE_BASE_PORT`, and
this rig has no base motor controller attached at all (only the two arm
serial ports exist), so the sidecar cannot start in hardware mode without
Step 1 below. This is the one place in the whole plan that genuinely needs a
live running server (Step 7 has the user open a real browser against it) —
unlike Tasks 2-3, there's no direct-component-testing substitute for that.

- [ ] **Step 1: Make `LEX_XLE_BASE_PORT` optional**

Base drive/control stays out of scope for this plan either way (per Global
Constraints) — this only stops a missing base from blocking sidecar startup,
matching the same best-effort pattern Task 3 already applied to cameras.
`read_base`/`move_base` still assume `self._hw_base` is set and will raise
`AttributeError` if called with no base configured — that's a pre-existing,
known, still-open gap this step does not fix (out of scope), not something
to silently paper over.

In `sidecar/xlerobot_sidecar.py`, find `_bring_up_hardware` (currently around
line 825). Change:

```python
        left_port = os.environ.get("LEX_XLE_LEFT_PORT")
        right_port = os.environ.get("LEX_XLE_RIGHT_PORT")
        base_port = os.environ.get("LEX_XLE_BASE_PORT")
        if not left_port or not right_port or not base_port:
            raise SystemExit(
                "LEX_ROBOT_HW=1 requires LEX_XLE_LEFT_PORT, LEX_XLE_RIGHT_PORT and "
                "LEX_XLE_BASE_PORT (serial ports for the two SO-101 arms + the base) "
                "— see SIDECAR.md."
            )
```

to:

```python
        left_port = os.environ.get("LEX_XLE_LEFT_PORT")
        right_port = os.environ.get("LEX_XLE_RIGHT_PORT")
        base_port = os.environ.get("LEX_XLE_BASE_PORT")
        if not left_port or not right_port:
            raise SystemExit(
                "LEX_ROBOT_HW=1 requires LEX_XLE_LEFT_PORT and LEX_XLE_RIGHT_PORT "
                "(serial ports for the two SO-101 arms) — see SIDECAR.md. "
                "LEX_XLE_BASE_PORT is optional; without it, the base is unavailable "
                "(read_base/move_base will fail if called)."
            )
```

Then find where `self._hw_base` gets constructed a few lines below (the
`if BASE_MODE == "omni": ... else: ...` block) and wrap it in
`if base_port:` so it's skipped entirely when no base port is configured:

```python
            if base_port:
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
```

(`self._hw_base` already defaults to `None` in `__init__`, before
`_bring_up_hardware` runs — confirm this before assuming it, since the fix
relies on that existing default rather than setting one here.)

- [ ] **Step 2: Syntax-check and re-run the test suite**

Run: `python3 -c "import ast; ast.parse(open('sidecar/xlerobot_sidecar.py').read())" && echo OK`
Run: `cd sidecar && python3 -m pytest test_xlerobot_hw.py -v`
Expected: `OK`, and all 20 tests still passing (this change isn't exercised by any stub-tier test, so the count shouldn't move).

- [ ] **Step 3: Add the `CONTROL_PAGE_HTML` constant**

In `sidecar/xlerobot_sidecar.py`, right after the `DISPLAY_PAGE_HTML = """..."""` constant closes (line 778), add:

```python
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
  #arms { display:grid; grid-template-columns:1fr 1fr; gap:1px; background:var(--border); }
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
  .camera { width:100%; aspect-ratio:4/3; background:var(--bg3); border:1px solid var(--border);
            margin-bottom:12px; display:flex; align-items:center; justify-content:center;
            overflow:hidden; }
  .camera img { width:100%; height:100%; object-fit:contain; display:block; }
  .camera .unavail { color:var(--muted); font-size:11px; padding:8px; text-align:center; }
</style></head>
<body>
<header>
  <h1>XLEROBOT ARM CONTROL</h1>
  <div id="gate"><input type="checkbox" id="enable"><label for="enable">Enable control</label></div>
</header>
<div id="notice">"Enable control" only gates this page's buttons -- it is not a
  safety system. The sidecar's own joint clamp, Lex grants, and the hardware
  e-stop are the real safety boundary.</div>
<div id="arms">
  <div class="panel" data-arm="left">
    <h2><span class="dot" id="dot-left"></span>LEFT ARM</h2>
    <div class="camera" id="camera-left"><span class="unavail">camera: --</span></div>
    <table class="joints" id="joints-left"></table>
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
<script>
const ARMS = ["left", "right"];
const AXES = ["x", "y", "z"];
let enabled = false;
let lastPose = {left: null, right: null};
let busy = {left: false, right: false};

document.getElementById('enable').addEventListener('change', (e) => {
  enabled = e.target.checked;
  updateButtonStates();
});

function updateButtonStates() {
  for (const arm of ARMS) {
    const disable = !enabled || busy[arm] || !lastPose[arm];
    document.querySelectorAll(`#jog-${arm} button`).forEach(b => b.disabled = disable);
    document.getElementById(`open-${arm}`).disabled = !enabled || busy[arm];
    document.getElementById(`close-${arm}`).disabled = !enabled || busy[arm];
  }
}

function buildJogControls() {
  for (const arm of ARMS) {
    const container = document.getElementById(`jog-${arm}`);
    for (const axis of AXES) {
      const row = document.createElement('div');
      row.className = 'axis-row';
      row.innerHTML = `<label>${axis}</label>` +
        `<button data-axis="${axis}" data-dir="-1" disabled>-</button>` +
        `<button data-axis="${axis}" data-dir="1" disabled>+</button>`;
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
    const r = await fetch('/skill/move_arm', {
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
    const r = await fetch(`/skill/${skill}`, {method: 'POST', body: JSON.stringify(body)});
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
}

async function pollArm(arm) {
  try {
    const [jr, pr, cr] = await Promise.all([
      fetch('/skill/read_joints', {method: 'POST', body: JSON.stringify({arm})}),
      fetch('/skill/read_arm_pose', {method: 'POST', body: JSON.stringify({arm})}),
      fetch('/skill/read_camera', {method: 'POST', body: JSON.stringify({name: arm})}),
    ]);
    const joints = await jr.json();
    const pose = await pr.json();
    const cam = await cr.json();

    document.getElementById(`dot-${arm}`).classList.add('ok');

    const table = document.getElementById(`joints-${arm}`);
    table.innerHTML = joints.names.map((n, i) =>
      `<tr><td>${n}</td><td>${joints.positions[i].toFixed(2)}</td></tr>`).join('');

    const poseEl = document.getElementById(`pose-${arm}`);
    if (pose.ok) {
      poseEl.innerHTML = `pose: x=${pose.x.toFixed(3)} y=${pose.y.toFixed(3)} z=${pose.z.toFixed(3)}`;
      lastPose[arm] = pose;
    } else {
      poseEl.innerHTML = `<span class="unavail">pose unavailable: ${pose.detail || 'n/a'}</span>`;
      lastPose[arm] = null;
    }

    const camEl = document.getElementById(`camera-${arm}`);
    if (cam.jpeg_b64) {
      camEl.innerHTML = `<img src="data:image/jpeg;base64,${cam.jpeg_b64}">`;
    } else {
      camEl.innerHTML = `<span class="unavail">camera unavailable: ${cam.error || 'no frame'}</span>`;
    }
  } catch (e) {
    document.getElementById(`dot-${arm}`).classList.remove('ok');
    lastPose[arm] = null;
  }
  updateButtonStates();
}

function poll() {
  for (const arm of ARMS) pollArm(arm);
}

buildJogControls();
poll();
setInterval(poll, 500);
</script>
</body></html>"""
```

- [ ] **Step 4: Register the route**

In `Handler.do_GET`, right after:
```python
        if path == "/display":
            return self._send_bytes(200, "text/html; charset=utf-8", DISPLAY_PAGE_HTML.encode())
```
add:
```python
        if path == "/control":
            return self._send_bytes(200, "text/html; charset=utf-8", CONTROL_PAGE_HTML.encode())
```

- [ ] **Step 5: Syntax-check**

Run: `python3 -c "import ast; ast.parse(open('sidecar/xlerobot_sidecar.py').read())" && echo OK`
Expected: `OK`

- [ ] **Step 6: Smoke-test the route against the stub tier**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot && source .venv/bin/activate
cd sidecar && python3 xlerobot_sidecar.py &
SIDECAR_PID=$!
sleep 1
curl -s http://127.0.0.1:8900/control | grep -o '<title>[^<]*</title>'
curl -s http://127.0.0.1:8900/control | grep -c 'id="enable"'
curl -s -X POST http://127.0.0.1:8900/skill/read_arm_pose -d '{"arm":"left"}'
curl -s -X POST http://127.0.0.1:8900/skill/move_arm -d '{"arm":"left","x":0.3,"y":0.0,"z":0.2}'
curl -s -X POST http://127.0.0.1:8900/skill/read_camera -d '{"name":"left"}'
kill $SIDECAR_PID
```

Expected:
- `<title>lex-robot arm control</title>`
- `1` (the enable checkbox is present exactly once)
- `{"ok":true,"x":0.0,"y":0.0,"z":0.0}` (fresh stub robot, arm never moved)
- `{"outcome":"reached","detail":"left arm EE at (0.30,0.00,0.20)"}`
- `{"width":640,"height":480,"jpeg_b64":""}` (stub tier's fixed placeholder — empty `jpeg_b64` is correct here, not a bug; the stub never encodes a real image)

- [ ] **Step 7: Verify against real hardware, with the user watching**

This is the one step that needs the user physically present, same as every other hardware test this session — do not run it unattended. Start the sidecar in hardware mode. This shell session's process predates the `video` group being added to this user (same issue as Task 3 Step 6) — wrap the whole thing in `sg video -c '...'`, or a fresh terminal works too:

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot && source .venv/bin/activate
sg video -c "bash -c '
LEX_XLE_LEFT_PORT=/dev/ttyACM0 LEX_XLE_RIGHT_PORT=/dev/ttyACM1 \
  LEX_XLE_URDF_PATH=/home/alpibru/.cache/lex-robot/so-arm100/Simulation/SO101/so101_new_calib.urdf \
  LEX_XLE_MAX_REL_TARGET=10 \
  LEX_XLE_CAMERA_LEFT_INDEX=4 LEX_XLE_CAMERA_RIGHT_INDEX=6 \
  LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py
'"
```

(`LEX_XLE_BASE_PORT` is required by the module's arg parsing even though the base isn't in scope here — check whether it errors without one; if so, this step needs a placeholder/dummy value or the base wiring needs a quick look. Note this explicitly when running the step rather than silently working around it.)

Have the user open `http://127.0.0.1:8900/control`, confirm both connection dots go green, joint values update live, both camera panels show a live image (not the "camera unavailable" placeholder), then check "Enable control" and try one jog button and one gripper button on each arm while watching the physical arms — same "did you see it move" confirmation loop used throughout this session.

- [ ] **Step 8: Commit**

```bash
git add sidecar/xlerobot_sidecar.py
git commit -m "xlerobot: add /control page for browser-based arm jogging + camera view"
```

---

### Task 5: Docs

**Files:**
- Modify: `SIDECAR.md` — add `read_arm_pose` to the skill table, mention `GET /control` alongside the existing `GET /display` writeup, document the new camera env vars.
- Modify: `sidecar/xlerobot_sidecar.py` — update the module docstring's skill list (lines 16-26) to include `read_arm_pose`.

**Interfaces:** None — doc-only, no code interfaces produced or consumed.

- [ ] **Step 1: Update the module docstring**

In `sidecar/xlerobot_sidecar.py`, in the skill list near line 18-19:
```
    read_joints {}                                     → { "names": [...], "positions": [...], "velocities": [...] }
```
add directly after it:
```
    read_arm_pose {"arm":"left|right"}                 → { "ok": bool, "x","y","z", "detail"? }
```

(The `LEX_XLE_CAMERA_HEAD_INDEX`/`LEX_XLE_CAMERA_LEFT_INDEX`/`LEX_XLE_CAMERA_RIGHT_INDEX` env vars were already documented in Task 3 Step 3 — confirm they're present rather than re-adding them.)

- [ ] **Step 2: Update `SIDECAR.md`'s skill table**

In the `| POST /skill/... | body | response |` table, add a row after `read_joints`:
```
| `read_arm_pose` | `{ "arm": "left\|right" }` | `{ "ok": bool, "x","y","z", "detail"? }` |
```

Update the existing `read_camera` row's body column from `{ "name": "wrist" }` to reflect the real slot names now in use — `{ "name": "head\|left\|right" }` — since Task 3 made `name` an actual dispatch key instead of an ignored parameter.

- [ ] **Step 3: Document `/control` and multi-camera in `SIDECAR.md`**

In the "Real hardware — XLeRobot Tier 3" section's "Arms" bullet, or as a new short bullet, add a sentence noting `GET /control` serves a browser jog/monitor page for both arms — including each arm's live camera view — same pattern as `GET /display`, gated behind a client-side "Enable control" toggle that is explicitly not a safety mechanism.

In the existing "Camera" bullet, update it to describe the head/left/right multi-camera slots from Task 3 (each optional, best-effort — a missing/failed camera no longer prevents sidecar startup) instead of the old single always-required camera.

- [ ] **Step 4: Commit**

```bash
git add SIDECAR.md sidecar/xlerobot_sidecar.py
git commit -m "docs: document read_arm_pose skill, multi-camera slots, and /control page"
```

## Self-Review Notes

- **Spec coverage:** `read_arm_pose` (Tasks 1-2), multi-camera backend (Task 3, added by the 2026-08-11 amendment), `/control` page with joints/pose/camera/jog/gripper/gate (Task 4), docs (Task 5) — all spec sections, including the amendment, have a task. Out-of-scope items (per-joint jog, base, new safety mechanisms) are explicitly excluded, not silently dropped. Camera was originally out of scope and is now in via the amendment — the plan's Global Constraints and this note both say so rather than silently absorbing the change.
- **Placeholder scan:** clean — no TBD/TODO. The `LEX_XLE_BASE_PORT` question flagged in the original plan turned out to be a real blocker (confirmed by Task 3's implementer: this rig has no base attached, so the sidecar couldn't start in hardware mode at all) — resolved by Task 4 Step 1, not left as an unresolved "check this" note.
- **Type consistency:** `read_arm_pose` returns `{"ok": bool, "x","y","z"}` or `{"ok": False, "detail": str}` consistently across the stub (Task 1), hardware (Task 2), and frontend (Task 4, which checks `pose.ok` and reads `pose.detail`). `_HwArm.read_pose()` and `XLeRobot.read_arm_pose()` names match what Task 1's stub branch calls (`self._hw_arms[...].read_pose()`). `read_camera` returns `{"width","height","jpeg_b64"}` on success or `{"error": str}` on failure, reusing this file's existing error-shape convention rather than inventing a new one; Task 4's frontend checks `cam.jpeg_b64` truthiness and falls back to `cam.error`, consistent with that shape.
- **New in this amendment:** Task 3 (multi-camera backend) is a real behavior change, not purely additive — hardware-tier startup no longer hard-fails if a configured camera can't open (best-effort per slot, matching the existing kinematics degrade pattern). Task 4 Step 1 extends the same "don't hard-fail startup" treatment to the base port specifically to unblock real hardware verification on this rig. Both are called out explicitly, not slipped in silently. `read_base`/`move_base` still assume a base is configured and will `AttributeError` if called with none — a pre-existing, now-slightly-more-reachable gap, explicitly named as out of scope rather than fixed here.
