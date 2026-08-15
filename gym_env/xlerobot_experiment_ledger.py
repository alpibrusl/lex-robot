#!/usr/bin/env python3
"""Append-only, git-committed ledger of RL training experiments.

docs/RL_TRAINING.md is the narrative lab notebook — interpretation,
hypotheses, verdicts. This is its machine-readable companion: one JSON
object per line in docs/experiments.jsonl, so the run series is
greppable, diffable, and importable into any tracking tool later
(MLflow et al.), and survives the ephemeral containers training runs
actually happen in — the durable store here is git, not a tracking
server nobody can reach from a sandbox.

Usage:
    # append (entry JSON on stdin; minimal keys validated)
    python3 gym_env/xlerobot_experiment_ledger.py append <<'JSON'
    {"attempt": 11, "trainer": "sidecar/xlerobot_rl_curriculum.py",
     "config": {"timesteps": 3000000}, "results": {"eval_det": "SUCCESS"}}
    JSON

    # summarize the series as a table
    python3 gym_env/xlerobot_experiment_ledger.py show
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LEDGER = Path(__file__).parent.parent / "docs" / "experiments.jsonl"
REQUIRED = ("attempt", "trainer", "config", "results")


def append(path: Path) -> int:
    entry = json.load(sys.stdin)
    missing = [k for k in REQUIRED if k not in entry]
    if missing:
        print(f"error: entry missing required keys: {missing}", file=sys.stderr)
        return 1
    with open(path, "a") as f:
        f.write(json.dumps(entry, separators=(",", ":")) + "\n")
    print(f"appended attempt {entry['attempt']} to {path}")
    return 0


def show(path: Path) -> int:
    if not path.exists():
        print(f"no ledger at {path}", file=sys.stderr)
        return 1
    rows = [json.loads(line) for line in open(path) if line.strip()]
    print(f"{'#':>3}  {'eval_det':>9}  {'denial':>7}  trainer / headline")
    for r in rows:
        res = r.get("results", {})
        denial = res.get("denial_rate")
        denial = f"{denial:.0%}" if isinstance(denial, (int, float)) else "—"
        print(f"{r['attempt']:>3}  {str(res.get('eval_det', '—')):>9}  {denial:>7}  {r.get('headline', r['trainer'])}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("append", "show"))
    ap.add_argument("--file", default=str(LEDGER), help=f"ledger path (default: {LEDGER})")
    args = ap.parse_args()
    return append(Path(args.file)) if args.command == "append" else show(Path(args.file))


if __name__ == "__main__":
    sys.exit(main())
