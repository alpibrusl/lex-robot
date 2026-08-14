# XLeRobot 0.4.0 — assembly, bring-up, and calibration

This is the path from "the parts are printed" to "the arms and base are
calibrated and lex-robot's Tier‑3 hardware sidecar can drive them." It
covers **mechanical assembly**, **software setup on Linux and macOS**,
**port/ID discovery**, and **calibration** — then hands off to
`SIDECAR.md` ("Real hardware — XLeRobot Tier 3") for the environment
variables that wire the calibrated robot into `lex-robot` itself.

Target hardware: [XLeRobot 0.4.0](https://github.com/Vector-Wangel/XLeRobot)
(WowRobo kit) — two 5‑DOF SO‑101 arms (STS3215 servos) on a dual‑wheel
differential base, head RGB camera, optional mic + speaker. Everything
below was originally verified against `lerobot` 0.4.4's actual calibration/
setup scripts (`lerobot-find-port`, `lerobot-setup-motors`,
`lerobot-calibrate`) and the arm bring‑up code in `lerobot.robots.so_follower`,
plus this repo's `sidecar/xlerobot_sidecar.py`; the CLI tools and API shapes
were re-checked against `lerobot` 0.6.1 and the sidecar updated where they'd
moved (Cartesian IK/FK now needs `LEX_XLE_URDF_PATH` + `placo` — see §6). It
has **not** been run against a physical XLeRobot in this repo's CI (see
`SIDECAR.md`) — treat each step as a starting point to validate on your own
unit, at low torque, no load.

## 0. Safety first — read before powering anything

- **A software grant is not physical safety.** `lex-robot`'s grants
  (workspace box, force clamp, speed clamp) and the sidecar's firmware
  floors (`LEX_XLE_HARD_GRIP_N`, `LEX_XLE_HARD_SPEED_MPS`) are a
  *logical* boundary, not a physical one — see `DESIGN.md` §8 and
  `SIDECAR.md` "Defense in depth." The physical floor is **firmware
  joint/current limits you configure on the servos themselves, plus a
  hardware e‑stop** wired inline with motor power, independent of any
  software.
- **First power-on, and every calibration session, is low‑torque,
  no‑load, hand on the e‑stop.** Don't run a governed demo against real
  hardware until you've moved each joint by hand through calibration at
  least once and are confident the mechanical range of motion matches
  what you expect.
- **Grasp force here is position-based, not force-closed-loop**
  (`SIDECAR.md`) — don't rely on the gripper to "feel" an obstruction.

## 1. Beyond the printed parts

3D printing gets you the frame, arm links, mounts, and (if you're using
0.4.0's finray fingers) the gripper tooling. You still need, per the
[official XLeRobot 0.4.0 BOM](https://github.com/Vector-Wangel/XLeRobot):

- **2× SO‑101 arm kits** — 6 STS3215 servos each (`shoulder_pan`,
  `shoulder_lift`, `elbow_flex`, `wrist_flex`, `wrist_roll`, `gripper` —
  the same names as `ARM_JOINTS` in `sidecar/xlerobot_sidecar.py`).
- **2× STS3215 drive servos** for the differential base's wheels.
- **A Feetech/Waveshare servo driver board per motor bus** (one for the
  left arm, one for the right arm, one for the base) — each exposes a
  USB‑serial connection to the host. Three separate USB cables, three
  separate `/dev/tty*` ports.
- **A head RGB camera** — any USB webcam works (`LEX_XLE_CAMERA_INDEX`
  picks it by OpenCV index); a RealSense works too if you use LeRobot's
  RealSense camera config instead.
- **Mic + speaker**, only if you want the `listen`/`speak` voice skills
  on real hardware — any USB or built-in device `sounddevice` can open.
- **A hardware e‑stop switch** in the motor power line. Not optional.
- **Power supply** sized for 12–14 servos under load (check the SO‑101
  and base BOM for the exact rail voltage/current your kit expects).

Mechanical assembly itself (frame, arm links, base chassis) is
kit-specific and best followed step by step from the
[Vector-Wangel/XLeRobot](https://github.com/Vector-Wangel/XLeRobot)
build guide — this document picks up once the frame is together and the
servo chains are wired, and covers the part that's the same regardless
of which printed variant you built: bringing the electronics up through
LeRobot and calibrating them.

## 2. Assembly order that avoids rework

1. Base frame + the 2 drive wheel servos.
2. Torso/arm mounts onto the base.
3. Each SO‑101 arm, servo-to-servo, in daisy-chain order:
   `shoulder_pan → shoulder_lift → elbow_flex → wrist_flex → wrist_roll → gripper`.
   Leave the chain **unpowered** — motor IDs get assigned next, one
   servo at a time, and that's easiest before final cable dressing.
4. Camera mount, mic/speaker mount.
5. Route and label all three USB‑serial cables now (**Left arm** /
   **Right arm** / **Base**) — you will tell them apart by unplug/replug
   in §4, and mislabeling here is the most common source of confusion
   later (`LEX_XLE_LEFT_PORT` driving what you thought was the right
   arm, etc.).
6. Strain-relief the cables at every joint that moves.

## 3. Software setup

### 3.1 Common to both platforms

```sh
git clone https://github.com/alpibrusl/lex-robot.git
cd lex-robot
python3 -m venv .venv && source .venv/bin/activate
pip install "lerobot[feetech]"      # SOFollower + FeetechMotorsBus + the CLI tools below
pip install sounddevice faster-whisper pillow   # listen + camera JPEG encoding
pip install kokoro                  # only if you want `speak` on real hardware (pulls torch)
```

Python **3.10+** is required (`lerobot`'s own floor). Then install the
`lex` toolchain — prebuilt binaries for Linux/macOS on
[lex-lang releases](https://github.com/alpibrusl/lex-lang/releases):

```sh
V=v0.10.10; T=aarch64-apple-darwin   # or x86_64-apple-darwin / x86_64-unknown-linux-gnu / aarch64-unknown-linux-gnu
curl -fsSL "https://github.com/alpibrusl/lex-lang/releases/download/$V/lex-$V-$T.tar.gz" | tar -xz
sudo mv "lex-$V-$T/lex" /usr/local/bin/ && lex version
```

### 3.2 Linux

- Serial ports show up as `/dev/ttyACM0`, `/dev/ttyACM1`, ... (or
  `/dev/ttyUSB*` depending on the driver board's USB‑serial chip).
- Your user needs permission to open them:

  ```sh
  sudo usermod -aG dialout $USER
  # log out and back in (or `newgrp dialout` for the current shell) for it to take effect
  ```

- Most common USB‑serial chips (CH340/CH341, CP210x) have in‑kernel
  drivers on any recent distro — nothing extra to install. If a port
  never appears, `dmesg | tail` after plugging in will name the chip
  lerobot couldn't see.

### 3.3 macOS

- Serial ports show up as `/dev/tty.usbmodem*` or `/dev/tty.wchusbserial*`
  (naming depends on the driver board's chip). No `dialout`-equivalent
  group is needed — ports under your own user are accessible by default.
- If the port never appears, the board's USB‑serial chip needs a driver:
  CH340/CH341/CH343-based boards need the
  [WCH driver](https://www.wch-ic.com/downloads/CH34XSER_MAC_ZIP.html);
  CP210x-based boards need
  [Silicon Labs' CP210x VCP driver](https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers).
  After installing, **System Settings → Privacy & Security** will show a
  blocked-extension prompt the first time — allow it, then replug the
  board.
- Apple Silicon vs Intel doesn't matter for this step; `lerobot` and its
  serial deps are pure Python + `pyserial`.

## 4. Find ports and assign motor IDs

Do this **one bus at a time** (left arm, then right arm, then base) —
plugging in more than one new/unconfigured device at once makes the
"which port is which" step ambiguous.

### 4.1 Identify the port

```sh
lerobot-find-port
```

It snapshots `/dev/tty*` (or COM ports on Windows), asks you to unplug
the cable you're identifying, snapshots again, and reports the port
that disappeared. Run it once per bus; note the three ports (left arm /
right arm / base) — you'll need them for both ID assignment below and
the `LEX_XLE_*_PORT` env vars in §6.

### 4.2 Assign each arm's motor IDs

Every STS3215 ships with the same factory ID, so before an arm's servos
can share one bus they each need a **unique** ID. `lerobot-setup-motors`
walks the chain one motor at a time:

```sh
lerobot-setup-motors --robot.type=so101_follower --robot.port=/dev/ttyACM0
```

(swap the port for whichever one §4.1 found for that arm). It prompts,
per motor, in this order — **connect only that one motor to the
controller board when prompted**, nothing else in the chain yet:

```
Connect the controller board to the 'gripper' motor only and press enter.
'gripper' motor id set to 6
Connect the controller board to the 'wrist_roll' motor only and press enter.
...
Connect the controller board to the 'shoulder_pan' motor only and press enter.
'shoulder_pan' motor id set to 1
```

(it walks the chain gripper → shoulder_pan, i.e. the reverse of the
physical order in §2 — that's fine, IDs are independent of wiring
order.) Repeat the whole command — same `--robot.port`, same one-motor-
at-a-time dance — for the second arm.

### 4.3 Assign the base's wheel motor IDs

The 0.4.0 differential base has **no `lerobot` Robot class** (only the
older 3‑omni‑wheel LeKiwi base does); `xlerobot_sidecar.py` talks to its
two wheel servos directly over `FeetechMotorsBus`. There's no
arm‑style CLI for it, but the same underlying `setup_motor` call works —
run this with only one wheel servo connected at a time (default target
IDs match `LEX_XLE_BASE_LEFT_ID`/`_RIGHT_ID`'s defaults, 1 and 2; adjust
if you want different IDs):

```sh
python3 - <<'EOF'
from lerobot.motors import Motor, MotorNormMode
from lerobot.motors.feetech import FeetechMotorsBus

port = "/dev/ttyACM2"          # the base's port from §4.1
target_id = 1                  # 1 for wheel_left, then re-run with 2 for wheel_right
bus = FeetechMotorsBus(port=port, motors={"wheel": Motor(target_id, "sts3215", MotorNormMode.RANGE_M100_100)})
bus.connect(handshake=False)
bus.setup_motor("wheel")
print("wheel motor id set to", bus.motors["wheel"].id)
bus.disconnect()
EOF
```

Run it twice — once with only `wheel_left` connected and `target_id=1`,
once with only `wheel_right` connected and `target_id=2` — then wire
both back onto the shared base bus.

## 5. Calibrate the arms

The base's wheels run in continuous velocity mode and need **no**
position calibration — ID assignment (§4.3) is the whole story for
them. The arms do:

```sh
lerobot-calibrate --robot.type=so101_follower --robot.port=/dev/ttyACM0 --robot.id=xle_left
```

`--robot.id` is the name this calibration gets saved under — use
`xle_left` / `xle_right` to match `LEX_XLE_LEFT_ID`/`_RIGHT_ID`'s
defaults in `sidecar/xlerobot_sidecar.py` (or pick your own and set
those env vars to match in §6). It walks you through:

1. **"Move `SO101Follower` to the middle of its range of motion and
   press ENTER"** — with torque disabled, physically center every
   joint, then hit enter. This sets the homing offsets.
2. **"Move all joints except `wrist_roll` sequentially through their
   entire ranges of motion. Recording positions. Press ENTER to
   stop..."** — slowly walk `shoulder_pan`, `shoulder_lift`,
   `elbow_flex`, `wrist_flex`, and `gripper` through their full
   mechanical range by hand (one at a time is easiest), then press
   enter. `wrist_roll` is a full continuous rotation and is skipped —
   its range is fixed, not recorded.
3. It saves the result and prints where to:
   `Calibration saved to ~/.cache/huggingface/lerobot/calibration/robots/so101_follower/xle_left.json`
   (that default path — `$HF_HOME/lerobot/calibration/...` — is the
   same on Linux and macOS; override with `HF_LEROBOT_CALIBRATION` if
   you need it elsewhere).

Repeat for the right arm with `--robot.id=xle_right`. Re-running
`lerobot-calibrate` later reuses the saved file unless you type `c` at
the first prompt to redo it from scratch.

## 6. Wire the calibrated robot into lex-robot

`sidecar/xlerobot_sidecar.py` connects with `calibrate=False` — it
expects the calibration from §5 to already be on disk under the id you
give it. Set the environment variables `SIDECAR.md` documents in full;
the ones you now have concrete values for:

```sh
export LEX_XLE_LEFT_PORT=/dev/ttyACM0    export LEX_XLE_LEFT_ID=xle_left
export LEX_XLE_RIGHT_PORT=/dev/ttyACM1   export LEX_XLE_RIGHT_ID=xle_right
export LEX_XLE_BASE_PORT=/dev/ttyACM2    # LEX_XLE_BASE_LEFT_ID/_RIGHT_ID default to 1/2, matching §4.3
export LEX_XLE_CAMERA_INDEX=0            # adjust if you have more than one camera
```

(macOS ports will look like `/dev/tty.usbmodemXXXX` instead of
`/dev/ttyACMx` — use whatever §4.1 found on your machine.)

If you want voice I/O, list your mic/speaker devices first —
`sounddevice` can enumerate them without any hardware-specific setup:

```sh
python3 -m sounddevice
```

— then set `LEX_XLE_MIC_DEVICE` / `LEX_XLE_SPEAKER_DEVICE` to the index
or name you want (defaults to the system default device if unset).

## 7. First bring-up — low torque, hand on the e-stop

Start the sidecar against real hardware:

```sh
LEX_ROBOT_HW=1 python3 sidecar/xlerobot_sidecar.py
```

It fails loudly at connect time if your installed `lerobot` version's
API doesn't match what this sidecar was written against (see
`SIDECAR.md`) — that's a signal to check your `lerobot` version, not to
work around the error. Once it's up, in a second terminal, run the same
governed demo you'd run against the stub sidecar — the Lex side doesn't
change:

```sh
lex run --allow-effects net,sense,actuate,io examples/xlerobot_demo.lex run
```

Watch the very first `move_arm`/`move_base` command happen at low
speed, near the workspace boundary the demo's grant defines, with your
hand on the e-stop. If it moves the way you expect, you're bench-verified;
if not, stop and re-check calibration (§5) before trying again.

From here, everything else in the main `README.md`'s XLeRobot section —
`make xlerobot-find` (vision-grounded fetch), `make xlerobot-llm-mock`
(scripted LLM planner), `make xlerobot-llm` (a real OpenCode-backed plan,
needs `OPENCODE_API_KEY`) — runs the same way: start
`sidecar/xlerobot_sidecar.py` with `LEX_ROBOT_HW=1` and the env vars
above instead of letting the `make` target spin up its own stub.

## 8. Attaching a screen: the kiosk display

The XLeRobot 0.4.0 BOM has no display, so once you've picked one (any
panel with HDMI in works — see the project's own notes on why touch/
resolution barely matter for this), wiring it up is a software step, not
a hardware integration:

1. Connect the screen's HDMI to whatever runs `xlerobot_sidecar.py` (the
   Raspberry Pi/mini PC, or your laptop on the bench).
2. Point any browser at it in fullscreen/kiosk mode, at whatever host
   and port the sidecar is listening on (`LEX_ROBOT_SIDECAR_PORT`,
   default `8900`):

   ```sh
   chromium --kiosk --incognito "http://127.0.0.1:8900/display"
   # or, on a Pi running a minimal X session:
   chromium-browser --kiosk "http://127.0.0.1:8900/display"
   ```

3. That's it — the page polls the sidecar once a second and renders
   whatever the robot last set: `render_qr`'s bootstrap code, or
   `show_image`/`show_video`/`show_url`/`show_text` (a picture, a video,
   a webpage, or plain status text), until `clear_display` blanks it.
   No restart needed when the robot changes what it's showing.

This is tier-independent — it works identically against the stub
sidecar (no `LEX_ROBOT_HW` needed) or the real one, since none of it
depends on servos or the camera; only a browser needs to actually be
pointed at the URL, which is this step, not something the sidecar can
verify on its own. See `sidecar/xlerobot_sidecar.py`'s "Display" section
for the full skill list and the `/display/content` MIME-serving details.

## 9. Troubleshooting

- **`lerobot-find-port` reports 0 or 2+ ports changed.** Something else
  changed state at the same time (another USB device, a Bluetooth
  reconnect). Close other apps that might be enumerating serial ports
  and retry with only the one cable you're identifying connected.
- **`setup_motor`/`calibrate` can't find the motor.** Check the servo is
  getting power (separate from the USB signal line on most boards) and
  that only the intended motor is on the bus for `setup_motors`.
- **Port permission denied (Linux).** You're not in `dialout` yet, or
  didn't log out/in after `usermod`. `newgrp dialout` fixes it for the
  current shell without a full logout.
- **Port never appears (macOS).** Missing USB‑serial driver for your
  board's chip (§3.3), or it's pending approval in **System Settings →
  Privacy & Security**.
- **`connect()` fails naming a missing `lerobot` API** (e.g.
  `robot_kinematic_processor` or `SOFollowerConfig` import errors). Your
  installed `lerobot` version doesn't expose what this sidecar expects —
  check `pip show lerobot` against what `SIDECAR.md`/this doc were
  verified against, and check `lerobot`'s own changelog for the module
  in question.
- **Base drifts off target.** Expected — the diff base is dead-reckoned
  with no encoder/localization feedback (`SIDECAR.md`), not a bug to
  chase in software; `reached` on `move_base` is an estimate.

## See also

- `SIDECAR.md` — the full sidecar protocol, and "Real hardware — XLeRobot
  Tier 3" for every `LEX_XLE_*` environment variable.
- `DESIGN.md` §8 — the honest constraints on what a software grant does
  and doesn't guarantee physically.
- `README.md` — the XLeRobot governance demos (stub → MuJoCo → hardware
  tiers) and the LLM-planner / voice-skill quickstarts.
