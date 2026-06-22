import json
from reconcile_audit import skill_sequence_from_audit, skill_sequence_from_trail, reconcile

def test_extracts_and_matches_sequences(tmp_path):
    audit = [
        {"event": {"kind": "command_allowed", "command": "move_to"}},
        {"event": {"kind": "skill_outcome", "command": "move_to", "outcome": "reached", "observation": "{}"}},
        {"event": {"kind": "command_allowed", "command": "grasp"}},
        {"event": {"kind": "skill_outcome", "command": "grasp", "outcome": "stalled", "observation": "{}"}},
    ]
    trail = [
        {"kind": "cap.invoked", "payload_json": json.dumps({"capability": "move_to"})},
        {"kind": "cap.completed", "payload_json": json.dumps({"capability": "move_to", "result": "reached"})},
        {"kind": "cap.invoked", "payload_json": json.dumps({"capability": "grasp"})},
        {"kind": "cap.completed", "payload_json": json.dumps({"capability": "grasp", "result": "stalled"})},
    ]
    assert skill_sequence_from_audit(audit) == [("move_to", "reached"), ("grasp", "stalled")]
    assert skill_sequence_from_trail(trail) == [("move_to", "reached"), ("grasp", "stalled")]
    assert reconcile(audit, trail) == []

def test_detects_divergence():
    audit = [{"event": {"kind": "skill_outcome", "command": "move_to", "outcome": "reached", "observation": "{}"}}]
    trail = [{"kind": "cap.completed", "payload_json": json.dumps({"capability": "move_to", "result": "timeout"})}]
    assert reconcile(audit, trail)
