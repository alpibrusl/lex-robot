#!/usr/bin/env bash
# Release the left arm's torque — it will sag, so support it first.
cd "$(dirname "$0")/.."
.venv/bin/python - <<'PY'
from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
f=SO101Follower(SO101FollowerConfig(
    port="/dev/serial/by-id/usb-1a86_USB_Single_Serial_5B3D043715-if00", id="xle_left"))
f.bus.connect()
try:
    for j in ("shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"):
        f.bus.write("Torque_Enable", j, 0, normalize=False, num_retry=3)
    print("left arm released")
finally:
    f.bus.disconnect()
PY
