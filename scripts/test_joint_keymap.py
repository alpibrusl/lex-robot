"""The keyboard layouts, checked without a robot or a keyboard.

    .venv/bin/python -m pytest scripts/test_joint_keymap.py
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import joint_keyboard_teleop as J  # noqa: E402


def test_web_is_the_default_layout(monkeypatch):
    monkeypatch.delenv("LEX_KEY_LAYOUT", raising=False)
    assert J.base_keymap() is J.WEB_KEYS


def test_rows_layout_is_still_available(monkeypatch):
    monkeypatch.setenv("LEX_KEY_LAYOUT", "rows")
    assert J.base_keymap() is J.KEYS


def test_unknown_layout_falls_back_to_web(monkeypatch):
    monkeypatch.setenv("LEX_KEY_LAYOUT", "dvorak")
    assert J.base_keymap() is J.WEB_KEYS


def test_web_layout_uses_the_web_letters_for_wrist_and_gripper():
    assert J.WEB_KEYS["i"] == ("wrist_flex", +1) and J.WEB_KEYS["k"] == ("wrist_flex", -1)
    assert J.WEB_KEYS["l"] == ("wrist_roll", +1) and J.WEB_KEYS["j"] == ("wrist_roll", -1)
    assert J.WEB_KEYS["o"] == ("gripper", +1) and J.WEB_KEYS["c"] == ("gripper", -1)


def test_web_layout_never_uses_a_key_lerobot_record_owns():
    assert not (J.RESERVED & J.WEB_KEYS.keys())
    assert "r" not in J.WEB_KEYS          # height-up moved to E for this reason


def test_web_layout_does_not_take_the_arm_switch_keys():
    assert not ({"1", "2"} & J.WEB_KEYS.keys())


def test_web_layout_drives_every_joint_both_ways():
    signs = {}
    for motor, sign in J.WEB_KEYS.values():
        signs.setdefault(motor, set()).add(sign)
    assert signs == {m: {+1, -1} for m in J.STEPS}


def test_the_keys_actually_move_through_the_default_layout(monkeypatch):
    monkeypatch.delenv("LEX_KEY_LAYOUT", raising=False)
    monkeypatch.delenv("LEX_KEYMAP", raising=False)
    d = J.deltas_from_keys({"o", "w"}, J.load_keymap(J.base_keymap()), 1.0)
    assert d["gripper"] > 0 and d["shoulder_lift"] > 0
    assert all(v == 0 for m, v in d.items() if m not in ("gripper", "shoulder_lift"))


def test_a_one_line_flip_works_over_the_web_layout(monkeypatch, tmp_path):
    f = tmp_path / "flip.json"
    f.write_text(json.dumps({"a": ["shoulder_pan", 1], "d": ["shoulder_pan", -1]}))
    monkeypatch.setenv("LEX_KEYMAP", str(f))
    monkeypatch.delenv("LEX_KEY_LAYOUT", raising=False)
    m = J.load_keymap(J.base_keymap())
    assert m["a"] == ("shoulder_pan", 1) and m["d"] == ("shoulder_pan", -1)
    assert m["o"] == ("gripper", 1)       # the rest of the layout survives


def test_help_describes_the_map_in_use():
    lines = J.describe_keymap(J.WEB_KEYS)
    assert lines[0].startswith("d / a") and "shoulder_pan" in lines[0]
    assert any(l.startswith("o / c") and "gripper" in l for l in lines)
