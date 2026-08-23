#!/usr/bin/env bash
# Start the XLeRobot sidecar on the Raspberry Pi with this unit's environment.
#
#   scripts/run_pi_sidecar.sh              # both arms
#   scripts/run_pi_sidecar.sh --left-only  # skip the right arm and the base
#
# Refuses to start if one is already running. That guard is not politeness:
# two sidecars racing for the same serial port wedges the CH340 at the USB
# level, and recovering needs a USBDEVFS_RESET (root) or a physical replug.
# Stop the running one with SIGTERM and let it release the bus cleanly --
# never SIGKILL a sidecar mid-transaction.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE="deploy/pi/xlerobot.env.example"
PY=".venv/bin/python"

# Match the interpreter running the script, not merely any command line that
# mentions it -- a bare `-f xlerobot_sidecar.py` also matches the shell you
# typed the pkill into, which kills your own session instead.
SIDECAR_PAT='python[0-9.]*[[:space:]]+.*xlerobot_sidecar\.py'
if pgrep -af "$SIDECAR_PAT" > /dev/null; then
  echo "A sidecar is already running:" >&2
  pgrep -af "$SIDECAR_PAT" >&2
  echo "Stop it first:  pkill -TERM -f '$SIDECAR_PAT'" >&2
  exit 1
fi

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
[ -x "$PY" ] || { echo "missing $PY -- create the venv first" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# The URDF path in the env file uses ${HOME}; expand it here so a bare
# `source` under a different HOME cannot leave IK silently disabled.
export LEX_XLE_URDF_PATH="${LEX_XLE_URDF_PATH:-$HOME/.local/share/so-arm100/Simulation/SO101/so101_new_calib.urdf}"
if [ ! -f "$LEX_XLE_URDF_PATH" ]; then
  echo "WARNING: URDF not found at $LEX_XLE_URDF_PATH" >&2
  echo "         move_arm's IK and the collision guard will be absent." >&2
fi

if [ "${1:-}" = "--left-only" ]; then
  # The base rides the right arm's bus, so dropping the right arm drops it too.
  unset LEX_XLE_RIGHT_PORT LEX_XLE_BASE LEX_XLE_BASE_SHARED_ARM
  echo "left arm only (right arm and base disabled)"
fi

for var in LEX_XLE_LEFT_PORT LEX_XLE_RIGHT_PORT; do
  path="${!var:-}"
  [ -n "$path" ] && [ ! -e "$path" ] && echo "WARNING: $var=$path does not exist" >&2
done

echo "starting sidecar on port ${LEX_ROBOT_SIDECAR_PORT:-8900} (hw=${LEX_ROBOT_HW:-0})"
exec "$PY" sidecar/xlerobot_sidecar.py
