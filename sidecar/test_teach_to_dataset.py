"""Tests for the taught-demonstration -> LeRobotDataset converter.

The pairing rule and the selection/refusal policy are what matter here; writing
the dataset itself is lerobot's job and is exercised end to end separately.
"""
import pytest

import teach
from teach_to_dataset import convert, frames_to_pairs, select


def traj(name="d", task="pick up the cup", arm="left", tags=(), n=10, moving=True):
    frames = [[float(i) if moving else 0.0] * 6 for i in range(n)]
    return teach.Trajectory(fps=20.0, joints=list(teach.ARM_JOINTS), frames=frames,
                            name=name, task=task, arm=arm, tags=list(tags))


# ── the pairing rule ────────────────────────────────────────────────────────

def test_each_frame_is_paired_with_the_next():
    """A taught trajectory has no separate command channel -- the operator's
    hand WAS the command -- so the next recorded pose is the action label."""
    assert frames_to_pairs([[1], [2], [3]]) == [([1], [2]), ([2], [3])]


def test_the_last_frame_is_dropped_having_no_successor():
    assert len(frames_to_pairs([[1], [2], [3], [4]])) == 3


def test_pairing_a_single_frame_yields_nothing():
    assert frames_to_pairs([[1]]) == []
    assert frames_to_pairs([]) == []


# ── selection ───────────────────────────────────────────────────────────────

def test_select_by_arm():
    rs = [traj(name="l", arm="left"), traj(name="r", arm="right")]
    assert [t.name for t in select(rs, arm="right")] == ["r"]


def test_select_by_tag():
    rs = [traj(name="a", tags=["nominal"]), traj(name="b", tags=["recovery"])]
    assert [t.name for t in select(rs, tag="recovery")] == ["b"]


def test_select_by_exact_task_text():
    """Language-conditioned training needs one task string per dataset, so
    selection is exact-match rather than fuzzy."""
    rs = [traj(name="a", task="pick up the cup"), traj(name="b", task="pick up the CUP")]
    assert [t.name for t in select(rs, task="pick up the cup")] == ["a"]


def test_select_with_no_filters_returns_everything():
    rs = [traj(name="a"), traj(name="b")]
    assert len(select(rs)) == 2


# ── refusals ────────────────────────────────────────────────────────────────

def test_a_demonstration_without_a_task_is_skipped_not_defaulted():
    """An empty task silently becomes the text a language-conditioned policy
    trains against; inventing a placeholder would be worse than dropping it."""
    res = convert([traj(task="  ")], "local/x")
    assert res["ok"] is False
    assert res["skipped"][0][0] == "d"
    assert "empty string" in res["skipped"][0][1]


def test_an_unreplayable_demonstration_is_skipped():
    bad = traj(n=2)                       # too few frames to have taught anything
    res = convert([bad], "local/x")
    assert res["ok"] is False and res["skipped"]


def test_mismatched_joint_sets_are_refused_rather_than_merged():
    a = traj(name="a")
    b = traj(name="b"); b.joints = ["only_one"]
    res = convert([a, b], "local/x")
    assert res["ok"] is False and "different joints" in res["detail"]


def test_nothing_usable_reports_clearly():
    res = convert([], "local/x")
    assert res["ok"] is False and res["episodes"] == 0
