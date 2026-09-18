#!/bin/zsh
# Record grasping demonstrations with the keyboard, to train a policy.
#
#   ./record_demos.sh               the left arm (default)
#   ARM=right ./record_demos.sh     the other one
#
# ONE SKILL PER DATASET. Do not chain pick -> place -> release -> pick again in
# a single episode: imitation learning is built for a single task and gets
# unreliable on long multi-stage takes, even when every stage is a skill it
# learns fine on its own. An episode is one attempt at one skill, cut as soon
# as it succeeds. "Pick up the star" is already a complete policy; putting it
# in the box is a different dataset.
#
# The TOWER angle must not change between recording and running -- the XLeRobot
# guide is blunt: if it changes, the policy degrades or stops working. Fixed
# here so it can be restored:  pan 1508, tilt 3386. `scripts/preflight.py`
# checks it before you start.
#
# Keys: JOINT control, one servo per key pair. Top row adds, home row
# subtracts, left to right from the base to the gripper:
#
#     w / s   rotate the base      y / h   wrist up/down
#     e / d   shoulder             u / j   rotate the wrist
#     t / g   elbow                i / k   open/close the gripper
#
#   q, r, n, esc and the arrows are not used: they belong to lerobot-record
#   (next episode, re-record, quit) and both listeners receive every key.
#
#   They combine when pressed together (e+t raises shoulder and elbow in the
#   same frame). Shift = quarter speed, for fine grasping.
#
# Why not lerobot's Cartesian keyboard (keyboard_ee): it emits x/y/z deltas and
# the arm only understands `<motor>.pos` keys. Nobody translates in between, so
# the dict reaches the bus empty and it dies (StopIteration in sync_write). The
# translator exists but needs a URDF that is not shipped, and it gives 4
# controls for 5 joints: the wrist would be chosen by inverse kinematics, not
# by you. See scripts/joint_keyboard_teleop.py.
set -a; source deploy/mac/xlerobot.env.example; set +a
P=/Users/alfonso/Workspace/alpibrusl/lex-robot/.venv/bin

# Calibration profiles are CROSSED with respect to the physical side, on
# purpose: `xle_right` is the LEFT arm's profile. They are lookup keys; what
# matters is each port getting the profile of its own servos' EEPROM. The side
# is recognized by the bus auxiliaries: tower (ids 7,8) = left, wheels (9,10) =
# right.
ARM=${ARM:-left}
case $ARM in
  left)  PORT=/dev/cu.usbmodem5B610332201; PROFILE=xle_right; WRIST=1 ;;
  right) PORT=/dev/cu.usbmodem5B3D0437151; PROFILE=xle_left;  WRIST=2 ;;
  *) echo "ARM must be 'left' or 'right', not '$ARM'" >&2; exit 1 ;;
esac

EPISODES=${EPISODES:-5}
SECONDS_PER=${SECONDS_PER:-25}
TASK=${TASK:-"pick up the wooden star"}
# The left arm keeps the original name: that is where the recorded episodes are.
if [ "$ARM" = "left" ]; then DATASET=${DATASET:-xle_estrella}
else DATASET=${DATASET:-xle_estrella_right}; fi

echo "Arm $ARM ($PORT, profile $PROFILE, wrist on camera $WRIST)"
echo "Dataset: $HOME/lex-robot-datasets/$DATASET   $EPISODES episodes of $SECONDS_PER s"

$P/python scripts/record_with_keyboard.py \
  --robot.type=so101_follower \
  --robot.port=$PORT \
  --robot.id=$PROFILE \
  --robot.max_relative_target=12.0 \
  --robot.cameras="{ head: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 15}, wrist: {type: opencv, index_or_path: $WRIST, width: 640, height: 480, fps: 15} }" \
  --teleop.type=joint_keyboard \
  --display_data=false \
  --dataset.repo_id=local/$DATASET \
  --dataset.root=$HOME/lex-robot-datasets/$DATASET \
  --dataset.single_task="$TASK" \
  --dataset.num_episodes=$EPISODES \
  --dataset.episode_time_s=$SECONDS_PER \
  --dataset.push_to_hub=false
