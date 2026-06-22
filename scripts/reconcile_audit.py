#!/usr/bin/env python3
"""Reconcile the lex-os audit log with the sidecar's lex-trail episode log.

The two are produced independently — the supervisor records each mediated
skill + observed outcome (lex-os audit, hash-chained), and the sidecar records
each executed skill + result (lex-trail, content-addressed). For a boxed run
they must corroborate: same skill sequence, same outcomes. Any divergence is a
sign the effect plane and the control plane disagree.

Usage:
    reconcile_audit.py <lex-os-audit.json> <robot-trail.json>
Exit 0 when the chains corroborate; exit 1 (and print discrepancies) otherwise.
"""
import json
import sys


def skill_sequence_from_audit(entries: list) -> list:
    """(skill, outcome) pairs from a lex-os audit log (list of Entry dicts)."""
    out = []
    for e in entries:
        ev = e.get("event", e)
        if ev.get("kind") == "skill_outcome":
            out.append((ev["command"], ev["outcome"]))
    return out


def skill_sequence_from_trail(events: list) -> list:
    """(skill, result) pairs from cap.completed events in a lex-trail chain."""
    out = []
    for ev in events:
        if ev.get("kind") == "cap.completed":
            p = json.loads(ev["payload_json"])
            out.append((p["capability"], p["result"]))
    return out


def reconcile(audit: list, trail: list) -> list:
    """Return a list of human-readable discrepancies (empty == corroborated)."""
    a = skill_sequence_from_audit(audit)
    t = skill_sequence_from_trail(trail)
    problems = []
    if len(a) != len(t):
        problems.append(f"length mismatch: audit has {len(a)} skill outcomes, trail has {len(t)}")
    for i, (ae, te) in enumerate(zip(a, t)):
        if ae != te:
            problems.append(f"step {i}: audit {ae} != trail {te}")
    return problems


def _load(path: str) -> list:
    with open(path) as f:
        text = f.read()
    text = text.strip()
    if text.startswith("["):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    audit = _load(sys.argv[1])
    trail = _load(sys.argv[2])
    problems = reconcile(audit, trail)
    if problems:
        print("DISCREPANCIES:")
        for p in problems:
            print(" -", p)
        return 1
    print(f"OK: {len(skill_sequence_from_audit(audit))} skill outcomes corroborate across both chains")
    return 0


if __name__ == "__main__":
    sys.exit(main())
