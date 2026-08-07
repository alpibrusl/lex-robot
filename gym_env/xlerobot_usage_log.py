#!/usr/bin/env python3
"""Turn a real, governed rollout's lex-trail (the JSONL
`examples/xlerobot_policy_rollout.lex` writes — the SAME file format
whether the rollout came from the scripted controller or a trained PPO
policy) into a retraining signal for `xlerobot_rl_finetune.py`.

This is "actual usage data": every `execute` event already records exactly
what was proposed, the grant it was checked against, and the real
outcome — `reached` (the command left the box) or `denied: ...` (the grant
caught it before it did). Nothing needs to be added to the trail format;
this just reads what's already there.

The trail encodes pose/force fields as integer milli-units (see
`src/wire.lex` — "structured SkillOutcome"), so `x: 499` means 0.499 m.

Usage:
    python3 gym_env/xlerobot_usage_log.py /tmp/xlerobot_rl_trail.jsonl
    # -> prints a summary: denial rate, which skill/axis was most often
    #    out of bounds and by how much (in metres) — feed that into
    #    xlerobot_rl_finetune.py's --usage-log to weight the retraining
    #    penalty toward the axes real usage actually violated, not a guess.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field

MILLI = 1000.0

# The grant's own bounds, in metres — mirrors examples/xlerobot_policy_rollout.lex's
# arm_grant()/base_grant() exactly, so a violation's magnitude here means the
# same thing it means at replay time.
ARM_BOUNDS = {"x": (0.05, 0.45), "y": (-0.35, 0.35), "z": (0.0, 0.5)}
BASE_BOUNDS = {"x": (0.0, 4.0), "y": (0.0, 3.0)}


@dataclass
class UsageSummary:
    total: int = 0
    denied: int = 0
    # Per (kind, axis) -> list of overshoot magnitudes in metres, one per violation.
    overshoots: dict = field(default_factory=dict)

    def denial_rate(self) -> float:
        return self.denied / self.total if self.total else 0.0

    def axis_weights(self) -> dict:
        """Normalize mean overshoot per axis into penalty-weight multipliers
        (1.0 = baseline; an axis with 3x the mean overshoot of the others
        gets a 3x penalty weight in the governed training env)."""
        means = {k: sum(v) / len(v) for k, v in self.overshoots.items() if v}
        if not means:
            return {}
        base = sum(means.values()) / len(means)
        return {k: (m / base if base > 0 else 1.0) for k, m in means.items()}


def _bounds_for(skill: str):
    if skill == "move_base":
        return BASE_BOUNDS, ("x", "y")
    return ARM_BOUNDS, ("x", "y", "z")  # move_to / move_arm


def summarize(trail_path: str) -> UsageSummary:
    s = UsageSummary()
    with open(trail_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            if event.get("kind") != "execute":
                continue
            payload = json.loads(event["payload_json"])
            skill = payload.get("skill", "")
            if skill == "grasp":
                continue  # force-only; not a spatial bound, out of scope here
            s.total += 1
            outcome = payload.get("outcome", "")
            if not outcome.startswith("denied"):
                continue
            s.denied += 1
            bounds, axes = _bounds_for(skill)
            args = payload.get("args", {})
            for axis in axes:
                lo, hi = bounds[axis]
                v = args.get(axis, 0) / MILLI
                if v < lo:
                    s.overshoots.setdefault((skill, axis), []).append(lo - v)
                elif v > hi:
                    s.overshoots.setdefault((skill, axis), []).append(v - hi)
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trail", help="a trail JSONL from examples/xlerobot_policy_rollout.lex")
    ap.add_argument("--json", action="store_true", help="print machine-readable summary instead of the human report")
    args = ap.parse_args()

    s = summarize(args.trail)
    if args.json:
        print(json.dumps({
            "total": s.total,
            "denied": s.denied,
            "denial_rate": s.denial_rate(),
            "axis_weights": {f"{k[0]}.{k[1]}": w for k, w in s.axis_weights().items()},
        }))
        return 0

    print(f"actions: {s.total}  denied: {s.denied}  denial rate: {s.denial_rate():.0%}")
    if not s.overshoots:
        print("no grant violations recorded — nothing to weight retraining toward")
        return 0
    print("violations by (skill, axis), mean overshoot in metres:")
    for (skill, axis), vals in sorted(s.overshoots.items(), key=lambda kv: -sum(kv[1]) / len(kv[1])):
        print(f"  {skill}.{axis}: {len(vals)} violations, mean overshoot {sum(vals) / len(vals):.3f}m, max {max(vals):.3f}m")
    print("\nsuggested penalty weights for xlerobot_rl_finetune.py (relative, 1.0 = average):")
    for (skill, axis), w in sorted(s.axis_weights().items(), key=lambda kv: -kv[1]):
        print(f"  {skill}.{axis}: {w:.2f}x")
    return 0


if __name__ == "__main__":
    sys.exit(main())
