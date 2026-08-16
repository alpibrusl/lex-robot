# Demo day: what you need, and the order that shows the story

The checklist and script for demonstrating lex-robot on a real XLeRobot —
what to have on the table, what to have installed, and the demo sequence
that builds from "it moves" to "it refuses, verifiably."

## Hardware checklist

**On the robot:**
- XLeRobot 0.4.0, assembled and calibrated (docs/XLEROBOT_SETUP.md §1–5) —
  both SO-101 arms, dual-wheel base, three cameras mounted (head/left/right).
  A partial build demos too: each arm slot is optional, and a missing arm's
  skills answer with an honest error instead of crashing the sidecar.
- Raspberry Pi 5 (or a bench laptop) running the sidecar; serial adapters
  for the arm and base buses; power per the setup doc's BOM notes (§1).
- 7-inch HDMI touchscreen + USB touch, in a kiosk browser on `/display` —
  the consent-prompt demo needs it (a phone browser pointed at the Pi works
  in a pinch, and a mouse works where touch doesn't).
- USB mic + speaker `sounddevice` can open — the voice demo needs them.
- **E-stop in reach, low torque configured, clear floor** for base moves —
  the base and force-grasp are the least-proven paths (SIDECAR.md); treat
  their first public run as a bench test with an audience.
- Props: a cup, a table, floor tape marking the granted workspace box — the
  tape makes the *denial* legible to the audience: the arm stops where the
  tape says.

**Off the robot (the GPU box):**
- Mac Studio (or any GPU host) on the same LAN: Ollama with a vision model
  pulled (`ollama pull qwen2.5vl:7b`), the vision service running
  (`make vision-serve`, or the launchd/systemd units in `deploy/`).
- Solid LAN — wired if possible; Wi-Fi jitter is where remote judgment
  stutters.

**Optional second robot (the A2A stranger demo):**
- Anything with a screen, a webcam, and Python — a laptop is a fine
  stall-robot. Mobility (a LeKiwi) makes physical-arrival real, but the
  handshake itself needs no wheels.

**Software prep (both machines, before the audience arrives):**
- `lex` toolchain at the repo's pinned version; repo cloned on both.
- Pi: `pip install "lerobot[feetech,kinematics]" sounddevice faster-whisper
  kokoro pillow "qrcode[pil]"`; the SO-101 URDF on disk (`LEX_XLE_URDF_PATH`).
- `bash scripts/smoke.sh` green on the Pi the night before — it exercises
  every demo below in stub mode, so a red line is a config problem you fix
  without an audience.
- Set the hardware env vars (SIDECAR.md) in `deploy/pi/xlerobot-sidecar.service`
  and start it; `curl :8900/health` from the Mac proves the LAN path.

## The sequence — each step earns the next

1. **It's real** — `GET /control` on a laptop: live joints, pose, three
   camera views; one gentle jog. Establishes working hardware in a minute.
2. **It refuses** — the grant demo (`make xlerobot` pointed at hardware):
   command a reach past the floor tape; the arm is *denied, never sent*.
   The thesis in one motion. Show the same denial in the trail.
3. **It asks first** — touch demo on the robot's own screen: "Fetch the
   cup?" [yes] [no]; a tap from the audience answers it; the ask-only grant
   then shows the refusal to even read the tap.
4. **It hears** — voice demo: a spoken goal becomes the run's goal locally
   (no cloud); the mic-less grant is refused at the capability layer.
5. **It sees, elsewhere** — vision-split with real frames: hold the cup in
   front of the head camera, the Mac answers the bounding box; kill the
   vision service and show `detect_object` failing *honestly* instead of
   pretending.
6. **Strangers meet** — QR bootstrap between the robot and the laptop
   stall-robot: card verify, consent, session. No pre-shared keys.
7. **The evidence** — end on the ledger: the run's hash-chained trail, the
   grant-gate replay, `notebooklab verify` re-deriving the numbers. The
   demo's claims are checkable after everyone goes home.

Steps 1–5 need only the robot + Mac; 6 adds the laptop; 7 is a terminal.
Every step has a stub-mode rehearsal (`make xlerobot / xlerobot-touch /
xlerobot-voice / vision-split`), so the whole sequence can be dry-run on any
machine, then repointed at metal.
