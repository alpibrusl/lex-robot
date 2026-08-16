# Split-compute vision: the Pi drives, a GPU box sees

Two processes, two machines, one seam:

| machine | process | role |
|---|---|---|
| Raspberry Pi 5 (on the robot) | `sidecar/xlerobot_sidecar.py` | servos, cameras, display/touch — the only thing that touches hardware. Captures frames; **the `[sense]` effect stays on the robot.** |
| GPU box (Mac Studio, Jetson, any LAN host) | `sidecar/vision_service.py` | judgment on already-captured frames — `detect_object` boxes and `list_visible_items` descriptions, answered by a VLM. |

The split follows the line the codebase already draws (README, fridge-report
demo): reading the camera is sensing; interpreting a photo already in hand is
`[net]`-only judgment on existing data, so it can honestly run off-robot.
Only the JPEG crosses the LAN — this is the **vision** analogue of what
`listen` deliberately does *not* do with raw audio (that contract keeps
transcription on the robot; see SIDECAR.md).

Try the whole thing on one machine first — no models, canned mock answers:

```sh
make vision-split
```

## The model endpoint: one surface, your whole LLM stack

The vision service makes a single **OpenAI-compatible chat-completions** call
with the frame attached as a `data:` URL. That one surface covers the stack
you already run:

- **Ollama, natively** (default): `LEX_VISION_LLM_URL=http://127.0.0.1:11434/v1`
  ```sh
  ollama pull qwen2.5vl:7b        # or llava, minicpm-v — any vision model tag
  ```
- **Anything behind LiteLLM** (OpenAI, vLLM, opencode-served models, …):
  point `LEX_VISION_LLM_URL` at the proxy and set `LEX_VISION_API_KEY` if the
  proxy uses virtual keys:
  ```yaml
  # litellm config.yaml route the service will call as "vision"
  model_list:
    - model_name: vision
      litellm_params: { model: "ollama/qwen2.5vl:7b" }
  ```
  ```sh
  LEX_VISION_LLM_URL=http://127.0.0.1:4000/v1 LEX_VISION_MODEL=vision ...
  ```

## GPU box (Mac Studio) — the vision service

```sh
git clone https://github.com/alpibrusl/lex-robot && cd lex-robot
ollama pull qwen2.5vl:7b
LEX_VISION_MODEL=qwen2.5vl:7b make vision-serve     # http://0.0.0.0:8901
```

Sanity checks from any machine on the LAN:

```sh
curl -s http://mac-studio.local:8901/health
curl -s -X POST http://mac-studio.local:8901/vision/detect \
  -d '{"image_b64": "'"$(base64 -i some_photo.jpg)"'", "name": "cup"}'
```

To keep it running across logins, install the launchd job (edit the paths and
model in the plist first):

```sh
cp deploy/mac/com.lex-robot.vision.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.lex-robot.vision.plist
```

On a Jetson or any Linux GPU box, use the systemd unit instead:

```sh
sudo cp deploy/linux/lex-vision.service /etc/systemd/system/
sudo systemctl enable --now lex-vision
```

## Raspberry Pi — the sidecar, pointed at the service

One env var joins the two machines:

```sh
export LEX_XLE_VISION_URL=http://mac-studio.local:8901
python3 sidecar/xlerobot_sidecar.py     # plus the usual LEX_ROBOT_HW=1 vars
```

For boot persistence, install the systemd unit (edit ports/env first —
the hardware env vars from SIDECAR.md go in the same `Environment=` block):

```sh
sudo cp deploy/pi/xlerobot-sidecar.service /etc/systemd/system/
sudo systemctl enable --now xlerobot-sidecar
```

With the URL set, the sidecar's `detect_object` skill captures a head-camera
frame locally and ships the JPEG to the service; without it, Tier-3 says so
honestly (`"no LEX_XLE_VISION_URL configured"`) rather than pretending to see.

## Running the Lex program on the Mac instead of the Pi

The sidecar protocol is deliberately **localhost-only, no auth** — don't bind
it to the LAN. Bridge it with an SSH tunnel, which preserves that trust model
unchanged:

```sh
ssh -L 8900:localhost:8900 pi@robot.local
# now, on the Mac: lex run ... examples/vision_split_demo.lex run
```

## Trust, stated plainly

The vision service binds `0.0.0.0` **by design** — it exists to be reached
across the LAN — and carries no auth of its own. Run it on a network you own
(the same posture as the sidecar, one step wider). If the LAN isn't yours,
front it with the Caddyfile pattern in this directory or keep everything on
one host. Whatever answers come back, actuation still passes the grant gate
on the robot: a wrong (or malicious) detection can misdirect a *permitted*
motion, but it cannot mint authority the grant never gave.

## Honest limits

- `detect_object` returns a **2D normalized bounding box**, not a world pose.
  Turning a box into a position needs depth or camera calibration; Tier-3
  `locate_object` keeps saying "not implemented" rather than faking that
  geometry. When a depth camera or calibration lands, the box from this
  service is the input to that math — nothing here will need to change.
- Latency is LAN + VLM inference (tens of ms to seconds depending on model) —
  right for discrete skills ("find the cup", "what's in the fridge"), wrong
  for closed-loop control at rate. The workload that eventually wants compute
  physically on the robot is `run_policy` — that's the Jetson conversation.
