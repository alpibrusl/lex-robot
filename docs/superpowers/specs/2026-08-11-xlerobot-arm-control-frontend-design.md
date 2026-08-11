# XLeRobot arm control frontend

Date: 2026-08-11
Status: design approved, ready for implementation plan

## Problem

`sidecar/xlerobot_sidecar.py` exposes arm control (`read_joints`, `move_arm`,
`grasp_arm`, `release_arm`) over its localhost HTTP skill API, and this
session hand-verified all of it against a real dual-arm XLeRobot rig via
one-off Python scripts. There's no way to drive or watch the arms from a
browser — every test this session required writing and running a throwaway
script. This spec covers a small browser control panel for the two arms,
served directly by the sidecar.

## Scope

In scope:
- One new skill, `read_arm_pose`, reporting Cartesian end-effector position.
- One new route, `GET /control`, serving an inline HTML+JS control panel.
- Live joint + EE-pose readout for both arms.
- Cartesian X/Y/Z jogging via the existing `move_arm` skill.
- Gripper open/close via the existing `grasp_arm`/`release_arm` skills.
- A client-side "enable control" gate on all actuating buttons.

Out of scope (explicitly deferred, not because they're hard, but to keep this
change small and reviewable):
- Per-joint jogging (would need a new `move_joint` skill — the existing skill
  surface only does Cartesian moves; see DESIGN.md's XLeRobot section).
- Base drive controls.
- Any new physical safety mechanism (e-stop skill, etc.) — this UI is a
  convenience layer on top of the sidecar's existing defense-in-depth
  (`LEX_XLE_MAX_REL_TARGET` clamp, Lex grants, hardware e-stop), not a
  replacement for it.

(The camera feed was originally deferred too, but see the amendment below —
the user connected two cameras mid-implementation and asked for them to be
shown on the page, so this is now in scope.)

## Backend change: `read_arm_pose`

`move_arm` takes an *absolute* Cartesian target, but on real hardware
`read_joints` returns joint-space degrees (`shoulder_pan`, `elbow_flex`, …),
not the end-effector's X/Y/Z — there's currently no way for a caller to know
where the gripper actually is in Cartesian space. Jogging needs that, to
compute `current + delta` for each nudge.

Add:

```
read_arm_pose  {"arm":"left|right"}  →  {"ok": bool, "x","y","z", "detail"?}
```

- Hardware tier: calls the arm's existing `_HwArm._forward_kinematics_ee`
  helper (already used internally by `move_to`'s settle check) — no new
  kinematics logic, just a new entry point onto what's already computed.
  `ok:false` with a `detail` string when no URDF/`placo` is configured,
  mirroring how `move_to` already degrades in that case.
- Stub tier: echoes `self.arms[arm]["positions"][0:3]`, consistent with how
  the stub's `move_arm` already treats `positions[0:3]` as the simulated
  Cartesian position.
- Registered in `handle_skill()` next to `read_joints`, and documented in
  SIDECAR.md's skill table.

## Frontend: `GET /control`

Served the same way `GET /display` already serves `DISPLAY_PAGE_HTML` — an
inline HTML+JS string constant in `xlerobot_sidecar.py`, returned by the
`Handler`. Same origin as `/skill/*`, so plain `fetch()` calls, no CORS setup,
no build step, no separate process. Works unmodified against any tier the
sidecar happens to be running (stub, MuJoCo sim, or real hardware) since it
only talks to the existing skill API.

### Layout

Dark monospace control-panel style, matching `examples/*_web.html`'s existing
look in this repo (dark background, monospace font, cyan/lime/amber status
accents, bordered panels with small-caps titles) — visually consistent with
this project's other robot dashboards.

Two side-by-side panels, **Left Arm** / **Right Arm**. Each panel has:
- A connection-state dot (green = last poll succeeded, red = failed).
- The 6 joint readouts (name + value) from `read_joints`.
- The EE pose (x / y / z) from `read_arm_pose`, or a "pose unavailable —
  <detail>" line when `ok:false`.
- X/Y/Z jog controls: a `±` button pair per axis, plus a step-size input
  (default 0.01 m). Pressing `+`/`-` computes `current_axis_value ± step`
  from the last-read pose and calls `move_arm` with the full updated
  `{x,y,z}` (the other two axes unchanged).
- Gripper **Open** / **Close** buttons (`release_arm` / `grasp_arm`; a small
  numeric input sets the force passed to `grasp_arm`, default 10 N).
- A one-line status readout showing the most recent command's
  `outcome`/`detail`.

A single page-level **"Enable control"** checkbox, unchecked on load. All
jog/gripper buttons are `disabled` (and visibly greyed out) until it's
checked — pure client-side gate, no backend involvement. A short static
notice under the checkbox states plainly that this gate is a UI convenience,
not a safety system, and that the sidecar's own clamps/grants/e-stop remain
the real safety boundary.

### Polling & error handling

Every 500ms, poll `read_joints` and `read_arm_pose` for both arms (four
`fetch()` calls per tick). A failed fetch (sidecar down/restarting) flips
that arm's connection dot red and the loop just retries next tick — same
fail-soft pattern `/display/state`'s poll loop already uses. Jog/gripper
button clicks are independent one-shot `fetch()` calls, not part of the poll
loop; while one is in flight for a given arm, that arm's buttons disable to
prevent stacking overlapping commands.

## Testing

No new pure-logic to unit-test (this is I/O + DOM, unlike the existing
`test_xlerobot_hw.py` helpers). Verification is: exercise `read_arm_pose`
against the real connected arms directly (same way every other hardware
change this session was verified), then manually drive the `/control` page
in a browser against the live sidecar (both arms, jog on a few axes, open/
close gripper, reload mid-session to confirm the poll loop and the disabled-
by-default gate both behave) before calling it done.

## Amendment 2026-08-11: multi-camera support

The user connected two USB cameras (via a hub, alongside the two arms) mid-
implementation and asked for their images to be shown on the control page.
XLeRobot's canonical hardware has up to three cameras (left arm, right arm,
head/center); this rig has left+right physically connected now (confirmed
working: `/dev/video4` and `/dev/video6`, both real UVC capture nodes —
`/dev/video5`/`/dev/video7` are secondary nodes on the same two physical
cameras, not separate cameras), no head camera yet.

This is a genuine scope change from the original design, not an extension of
something already planned — the original brainstorming Q&A explicitly chose
"arms only" and deferred the camera. It's accepted here because the user
asked for it directly and it fits naturally into the same page.

**A real gap this surfaces:** the sidecar currently supports exactly one
camera. `self._hw_camera` is built unconditionally from a single
`LEX_XLE_CAMERA_INDEX` env var (default `"0"`) at hardware connect time —
if that index can't open, the whole sidecar fails to start, not just the
camera skill. `read_camera`'s `name` argument is accepted but completely
ignored; it always returns that one camera regardless of what name was
asked for. Supporting left/right (and future head) requires fixing this,
not just adding an `<img>` tag.

### Backend change: multi-camera slots

Replace the single eager `self._hw_camera` with per-slot, best-effort
construction — matching the pattern `_HwArm._make_kinematics()` already
uses for degrading gracefully instead of crashing sidecar startup:

- Three optional env vars: `LEX_XLE_CAMERA_HEAD_INDEX`,
  `LEX_XLE_CAMERA_LEFT_INDEX`, `LEX_XLE_CAMERA_RIGHT_INDEX`. None are
  required. `LEX_XLE_CAMERA_INDEX` (the old single-camera var) is kept as a
  fallback alias for `LEX_XLE_CAMERA_HEAD_INDEX`, for backward compatibility
  with anyone already setting it.
- `self._hw_cameras: dict[str, _HwCamera]`, populated only for slots whose
  env var is actually set. A slot whose camera fails to open is logged and
  skipped (best-effort), not a fatal error — one bad/missing camera must not
  prevent the arms (or the other cameras) from working. This is a real
  behavior change from today's "camera index 0 required or startup fails" —
  worth calling out explicitly since it's a correctness fix riding along
  with the feature, not purely additive.
- `XLeRobot.read_camera(name)` dispatches to `self._hw_cameras.get(name)`.
  Unknown/unconfigured/unavailable name returns `{"error": "camera '<name>'
  not configured or unavailable"}` — reusing this file's existing
  `{"error": ...}` convention (already used for unknown skill names in
  `handle_skill`) rather than inventing a new response shape. The success
  shape (`{"width","height","jpeg_b64"}`) is unchanged.
- Stub tier is unchanged (already ignores `name` and returns a fixed
  placeholder — consistent with the honest-simulation pattern used
  elsewhere at this tier; no per-camera distinction needed there).

### Frontend change: camera panels

Each arm panel on `/control` gains a small image element showing that
camera's most recent frame (`<img>` with a `data:image/jpeg;base64,...`
src), polled at the same 500ms cadence as `read_joints`/`read_arm_pose` for
that arm. If `read_camera` returns `{"error": ...}` (camera not connected —
expected for "head", always, on this rig), the panel shows that detail
as text instead of a broken image, the same fail-soft spirit as the
connection dot. This does not add a third "head" panel — only left/right
are wired into the page layout for now; head can be added later the same
way once that camera exists.
