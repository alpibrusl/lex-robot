import importlib, os

def test_host_is_configurable(monkeypatch):
    monkeypatch.setenv("LEX_ROBOT_SIDECAR_HOST", "0.0.0.0")
    import gym_sidecar
    importlib.reload(gym_sidecar)
    assert gym_sidecar.HOST == "0.0.0.0"

def test_skill_call_records_trail_event(monkeypatch):
    import gym_sidecar
    importlib.reload(gym_sidecar)
    before = len(gym_sidecar.EPISODE.events)
    gym_sidecar.record_skill_trail("move_to", {"x": 0.3}, {"outcome": "reached"})
    assert len(gym_sidecar.EPISODE.events) == before + 2
    assert gym_sidecar.EPISODE.events[-2]["kind"] == "cap.invoked"
    assert gym_sidecar.EPISODE.events[-1]["kind"] == "cap.completed"
