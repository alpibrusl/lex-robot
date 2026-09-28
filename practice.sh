#!/bin/zsh
# Practice with the keyboard WITHOUT recording. Safe to leave running.
#
#   ./practice.sh                both arms, one at a time, switch with 1 and 2
#   ./practice.sh --both         both arms AT ONCE, one hand each
#   ./practice.sh left           only that one
#
#     w / s   rotate the base      y / h   wrist up/down
#     e / d   shoulder             u / j   rotate the wrist
#     t / g   elbow                i / k   open/close the gripper
#
#     1 / 2   switch arm (left / right)
#
#   With --both, each hand drives one arm at the same time:
#
#     left arm    w/s base   e/d shoulder   t/g elbow
#                 a/z wrist  f/v roll       c/x gripper
#     right arm   y/h base   u/j shoulder   i/k elbow
#                 o/l wrist  p/ñ roll       ./, gripper
#
#   Do not like the layout? Do not edit code: point LEX_KEYMAP at a JSON file
#   of {"key": ["motor", 1 or -1]} (or {"left": {...}, "right": {...}}). It is
#   merged over the default, so list only what you want to change:
#
#     echo '{"left": {"1": ["gripper", 1], "2": ["gripper", -1]}}' > keys.json
#     LEX_KEYMAP=keys.json ./practice.sh --both
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
