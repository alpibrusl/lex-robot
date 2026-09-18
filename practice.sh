#!/bin/zsh
# Practice with the keyboard WITHOUT recording. Safe to leave running.
#
#   ./practice.sh                both arms, switch with 1 and 2
#   ./practice.sh left           only that one
#   ./practice.sh right
#
#     w / s   rotate the base      y / h   wrist up/down
#     e / d   shoulder             u / j   rotate the wrist
#     t / g   elbow                i / k   open/close the gripper
#
#     1 / 2   switch arm (left / right)
#
#   They combine when pressed together. Shift = quarter speed.
#   Esc or Ctrl-C to quit. The arms stay held, they do not collapse.
#   The inactive arm keeps its torque too: it stays where you left it.
#
# No cameras and no dataset: this does not record, it only moves.
# When you finish, to leave the servos loose:  python scripts/release_arms.py
#
# RUN IT FROM YOUR TERMINAL. The Accessibility permission belongs to Terminal,
# not to Claude's process; if you launch it from there, the script will say so.
cd "$(dirname "$0")"
exec /Users/alfonso/Workspace/alpibrusl/lex-robot/.venv/bin/python scripts/practice.py "$@"
