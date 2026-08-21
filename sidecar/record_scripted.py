"""`lerobot-record` with the scripted teleoperator registered.

draccus resolves --teleop.type from a registry populated at import time, so
the scripted teleop must be imported before argument parsing. This shim does
that, then hands off to lerobot's own record entry point -- the dataset is
written by lerobot, not by us, so the schema is whatever lerobot-train expects.

    python sidecar/record_scripted.py \
      --robot.type=so101_follower \
      --robot.port=/dev/cu.usbmodem5B3D0437151 \
      --robot.id=xle_left \
      --robot.max_relative_target=8 \
      --teleop.type=scripted_arm \
      --teleop.jitter=3.0 \
      --dataset.repo_id=local/xle_pick_place \
      --dataset.single_task="pick and place" \
      --dataset.episode_time_s=20 \
      --dataset.num_episodes=20 \
      --dataset.push_to_hub=false
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import scripted_teleop      # noqa: F401  -- registers "scripted_arm"
import vision_reset_teleop  # noqa: F401  -- registers "vision_reset"

from lerobot.scripts.lerobot_record import main

if __name__ == "__main__":
    main()
