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
- Per-joint jogging, base controls, and the camera feed are explicitly out of scope — don't add them.

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

### Task 3: `/control` page

**Files:**
- Modify: `sidecar/xlerobot_sidecar.py` — add `CONTROL_PAGE_HTML` constant (near `DISPLAY_PAGE_HTML`, currently defined at line 737), add the `/control` route in `Handler.do_GET` (near line 1108-1109).

**Interfaces:**
- Consumes: `read_joints`, `read_arm_pose` (Tasks 1-2), `move_arm`, `grasp_arm`, `release_arm` (existing skills) — all via `POST /skill/<name>`, same-origin `fetch()`.
- Produces: `GET /control` — serves the page. No other code depends on this.

- [ ] **Step 1: Add the `CONTROL_PAGE_HTML` constant**

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
    const [jr, pr] = await Promise.all([
      fetch('/skill/read_joints', {method: 'POST', body: JSON.stringify({arm})}),
      fetch('/skill/read_arm_pose', {method: 'POST', body: JSON.stringify({arm})}),
    ]);
    const joints = await jr.json();
    const pose = await pr.json();

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

- [ ] **Step 2: Register the route**

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

- [ ] **Step 3: Syntax-check**

Run: `python3 -c "import ast; ast.parse(open('sidecar/xlerobot_sidecar.py').read())" && echo OK`
Expected: `OK`

- [ ] **Step 4: Smoke-test the route against the stub tier**

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot && source .venv/bin/activate
cd sidecar && python3 xlerobot_sidecar.py &
SIDECAR_PID=$!
sleep 1
curl -s http://127.0.0.1:8900/control | grep -o '<title>[^<]*</title>'
curl -s http://127.0.0.1:8900/control | grep -c 'id="enable"'
curl -s -X POST http://127.0.0.1:8900/skill/read_arm_pose -d '{"arm":"left"}'
curl -s -X POST http://127.0.0.1:8900/skill/move_arm -d '{"arm":"left","x":0.3,"y":0.0,"z":0.2}'
kill $SIDECAR_PID
```

Expected:
- `<title>lex-robot arm control</title>`
- `1` (the enable checkbox is present exactly once)
- `{"ok":true,"x":0.0,"y":0.0,"z":0.0}` (fresh stub robot, arm never moved)
- `{"outcome":"reached","detail":"left arm EE at (0.30,0.00,0.20)"}`

- [ ] **Step 5: Verify against real hardware, with the user watching**

This is the one step that needs the user physically present, same as every other hardware test this session — do not run it unattended. Start the sidecar in hardware mode:

```bash
cd /home/alpibru/workspace/alpibrusl/lex-robot && source .venv/bin/activate
LEX_XLE_LEFT_PORT=/dev/ttyACM0 LEX_XLE_RIGHT_PORT=/dev/ttyACM1 \
  LEX_XLE_URDF_PATH=/home/alpibru/.cache/lex-robot/so-arm100/Simulation/SO101/so101_new_calib.urdf \
  LEX_XLE_MAX_REL_TARGET=10 \
  LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py
```

(`LEX_XLE_BASE_PORT` is required by the module's arg parsing even though the base isn't in scope here — check whether it errors without one; if so, this step needs a placeholder/dummy value or the base wiring needs a quick look. Note this explicitly when running the step rather than silently working around it.)

Have the user open `http://127.0.0.1:8900/control`, confirm both connection dots go green, joint values update live, then check "Enable control" and try one jog button and one gripper button on each arm while watching the physical arms — same "did you see it move" confirmation loop used throughout this session.

- [ ] **Step 6: Commit**

```bash
git add sidecar/xlerobot_sidecar.py
git commit -m "xlerobot: add /control page for browser-based arm jogging"
```

---

### Task 4: Docs

**Files:**
- Modify: `SIDECAR.md` — add `read_arm_pose` to the skill table, mention `GET /control` alongside the existing `GET /display` writeup.
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

- [ ] **Step 2: Update `SIDECAR.md`'s skill table**

In the `| POST /skill/... | body | response |` table, add a row after `read_joints`:
```
| `read_arm_pose` | `{ "arm": "left\|right" }` | `{ "ok": bool, "x","y","z", "detail"? }` |
```

- [ ] **Step 3: Document `/control` in `SIDECAR.md`**

In the "Real hardware — XLeRobot Tier 3" section's "Arms" bullet, or as a new short bullet, add a sentence noting `GET /control` serves a browser jog/monitor page for both arms (same pattern as `GET /display`), gated behind a client-side "Enable control" toggle that is explicitly not a safety mechanism.

- [ ] **Step 4: Commit**

```bash
git add SIDECAR.md sidecar/xlerobot_sidecar.py
git commit -m "docs: document read_arm_pose skill and /control page"
```

## Self-Review Notes

- **Spec coverage:** `read_arm_pose` (Tasks 1-2), `/control` page with joints/pose/jog/gripper/gate (Task 3), docs (Task 4) — all spec sections have a task. Out-of-scope items (per-joint jog, base, camera, new safety mechanisms) are explicitly excluded, not silently dropped.
- **Placeholder scan:** clean — no TBD/TODO; the one open question (whether `LEX_XLE_BASE_PORT` is required by arg parsing even though the base is out of scope) is called out explicitly as something to check during Task 3 Step 5, not glossed over.
- **Type consistency:** `read_arm_pose` returns `{"ok": bool, "x","y","z"}` or `{"ok": False, "detail": str}` consistently across the stub (Task 1), hardware (Task 2), and frontend (Task 3, which checks `pose.ok` and reads `pose.detail`). `_HwArm.read_pose()` and `XLeRobot.read_arm_pose()` names match what Task 1's stub branch calls (`self._hw_arms[...].read_pose()`).
