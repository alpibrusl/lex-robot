"""What the grant actually did — a read-only ledger over the sidecar's skill calls.

The `/control` and `/teach` pages show the robot. This module backs the page
that shows the *envelope*: which capability was invoked, what the grant did
about it (allowed / refused outright / clamped to a ceiling), and a
hash-chained record of the sequence that `lex-trail` can replay.

**This module observes. It never decides.** The grant is enforced in exactly
one place per bound — `XLeRobot._grant_workspace_violation` refuses an
out-of-box target, `XLeRobot._grant_max_grip_force` clamps grip force — and
this ledger reads the *result* of those decisions after the fact. Adding an
enforcement branch here would be the thing lex-os's CLAUDE.md forbids: a
second, independent source of authority. `classify()` therefore never returns
a verdict the sidecar didn't already reach; when it can't tell what happened,
it says `unknown` rather than guessing.

Two consequences of that posture worth stating plainly, because a governance
page that overclaims is worse than none:

- A bound the sidecar declares but does not check is reported as *declared*,
  not as enforced. `arms.*.max_velocity_mps` and `arms.*.max_force_n` are in
  the capsule and nothing here checks them; `grant_enforcement()` says so.
  (`bases.*.floor_area_m` and `max_speed_mps` used to be in that list too --
  `move_base` now enforces both, which is what the honest column was for.)
- A clamp is only reported where the sidecar really clamps. Grip force clamps
  against the grant; base speed clamps against the grant and, beneath it, the
  `LEX_XLE_HARD_SPEED_MPS` firmware floor -- attributed to whichever ceiling
  actually bound the request. Nothing else is, so nothing else is claimed.
"""
from __future__ import annotations

import json
import os
import threading
import time
from collections import deque
from typing import Callable, Optional

from trail import compute_id

# ---------------------------------------------------------------------------
# What kind of thing each skill is.
#
# The ledger is about *authority*, and polling is not authority: `/control`
# calls read_joints and read_arm_pose four times a second, and recording those
# would bury every real decision under thousands of reads. So sense-class calls
# are skipped by default (LEX_XLE_LEDGER_READS=1 includes them, for the rare
# case where you're auditing what a program was allowed to *see*).
#
# An unrecognised skill is "unknown" and IS recorded: a new capability nobody
# taught this table about is exactly the thing an audit should surface, and
# silently dropping it would make the ledger quietly incomplete.
# ---------------------------------------------------------------------------
CATEGORIES = {
    "actuate": (
        "move_arm", "move_to", "grasp_arm", "grasp", "release_arm", "move_base",
        "teach_replay", "teach_home_go", "teach_free", "teach_hold",
        "run_policy", "reset",
    ),
    "sense": (
        "read_joints", "read_arm_pose", "read_base", "read_camera", "read_grant",
        "read_touch", "policy_status", "teach_status", "teach_list",
        "teach_home_get", "detect_object", "locate_object", "transform_to_arm",
        "scan_qr", "listen",
    ),
    "present": (
        "show_text", "show_image", "show_video", "show_url", "show_report",
        "show_prompt", "render_qr", "clear_display", "speak",
    ),
    "teach": (
        "teach_start", "teach_stop", "teach_delete", "teach_home_set",
    ),
}
_CATEGORY_OF = {name: cat for cat, names in CATEGORIES.items() for name in names}

# Categories whose calls the ledger records. `sense` is added when
# LEX_XLE_LEDGER_READS is set — see the note above.
AUTHORITY_CATEGORIES = ("actuate", "teach", "present", "unknown")

VERDICTS = ("allowed", "denied", "clamped", "failed", "unknown")

# Arg keys never worth showing on the page, and in two cases actively harmful
# to spill there: a transcript is a recording of somebody speaking in the room.
_REDACTED_ARGS = ("jpeg_b64", "image_b64", "transcript")
_MAX_ARG_CHARS = 120


def category(name: str) -> str:
    return _CATEGORY_OF.get(name, "unknown")


def is_authority(name: str, include_reads: bool = False) -> bool:
    cat = category(name)
    return cat in AUTHORITY_CATEGORIES or (include_reads and cat == "sense")


def summarize_args(args) -> dict:
    """A display-safe copy of a skill's arguments.

    Truncated and redacted, never parsed for meaning — the ledger records what
    was asked for, and a base64 frame or a room transcript is not something a
    governance page should be putting on a screen.
    """
    if not isinstance(args, dict):
        return {}
    out = {}
    for k, v in args.items():
        if k in _REDACTED_ARGS:
            out[k] = f"<{k} redacted>"
            continue
        if isinstance(v, str) and len(v) > _MAX_ARG_CHARS:
            out[k] = v[:_MAX_ARG_CHARS] + "…"
        elif isinstance(v, (list, tuple)) and len(v) > 8:
            out[k] = list(v[:8]) + [f"…+{len(v) - 8}"]
        else:
            out[k] = v
    return out


def base_entry(bases: Optional[dict]):
    """`(name, bound)` for the one base this robot has, or `(None, None)`.

    Mirrors XLeRobot._base_grant: keyed "base" by convention, a lone
    differently-named entry accepted, two or more ambiguous. Kept in step with
    the sidecar deliberately -- a ledger that resolved the bound differently
    from the code enforcing it would be reporting on an envelope nothing
    applies."""
    bases = bases or {}
    if "base" in bases:
        return "base", bases["base"]
    if len(bases) == 1:
        return next(iter(bases.items()))
    return None, None


def _num(value) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def clamps(name: str, args: dict, grant: Optional[dict], firmware: Optional[dict]) -> list:
    """Ceilings that really reduced this request, as the sidecar applies them.

    Only bounds the sidecar actually enforces appear here. Each entry is
    `{"bound", "source", "requested", "ceiling"}` — `source` being which of the
    two independent layers did it, the Lex grant or the firmware floor beneath
    it (see `xlerobot_sidecar.py`'s "defense in depth" note).
    """
    if not isinstance(args, dict):
        return []
    found = []
    grant = grant or {}
    firmware = firmware or {}

    if name in ("grasp_arm", "grasp"):
        requested = _num(args.get("force"))
        arm = args.get("arm", "left")
        gripper = (grant.get("grippers") or {}).get(arm) or {}
        ceiling = _num(gripper.get("max_grip_force_n"))
        if requested is not None and ceiling is not None and requested > ceiling:
            found.append({"bound": f"grippers.{arm}.max_grip_force_n", "source": "grant",
                          "requested": requested, "ceiling": ceiling})

    if name == "move_base":
        requested = _num(args.get("speed"))
        base_name, base = base_entry(grant.get("bases"))
        # Grant first, firmware second -- the order move_base applies them, so
        # a tie is attributed to the grant, which is the one a reader can change.
        ceilings = [(_num((base or {}).get("max_speed_mps")),
                     f"bases.{base_name}.max_speed_mps", "grant"),
                    (_num(firmware.get("max_speed_mps")),
                     "LEX_XLE_HARD_SPEED_MPS", "firmware")]
        ceilings = [c for c in ceilings if c[0] is not None]
        if requested is not None and ceilings:
            ceiling, bound, source = min(ceilings, key=lambda c: c[0])
            if requested > ceiling:
                found.append({"bound": bound, "source": source,
                              "requested": requested, "ceiling": ceiling})
    return found


def classify(name: str, args: dict, result: dict, grant: Optional[dict] = None,
             firmware: Optional[dict] = None) -> dict:
    """Read the verdict the sidecar already reached out of its own reply.

    Never re-derives one: if the reply doesn't say, the answer is `unknown`.
    """
    if not isinstance(result, dict):
        return {"verdict": "unknown", "reason": "skill returned a non-dict result", "clamps": []}

    outcome = result.get("outcome")
    detail = str(result.get("detail") or result.get("error") or "")
    applied = clamps(name, args, grant, firmware)

    if outcome == "denied":
        # The one verdict that means the grant refused: move_arm's workspace
        # box, which is never clamped (a position can't be safely squeezed
        # into an envelope the way a scalar can) — so it is refused instead.
        return {"verdict": "denied", "reason": detail or "refused by grant", "clamps": applied}

    if "error" in result or result.get("ok") is False or outcome in ("stalled", "timeout"):
        return {"verdict": "failed", "reason": detail or str(outcome or "error"), "clamps": applied}

    if not result:
        return {"verdict": "unknown", "reason": "empty result", "clamps": applied}

    if applied:
        c = applied[0]
        return {"verdict": "clamped",
                "reason": f"{c['bound']} {c['requested']:g} → {c['ceiling']:g} ({c['source']})",
                "clamps": applied}

    return {"verdict": "allowed", "reason": detail, "clamps": []}


def grant_enforcement(grant: Optional[dict]) -> list:
    """Every bound the loaded grant declares, and whether THIS sidecar checks it.

    The honest column. A dashboard that lists a declared bound as if it were
    enforced is worse than no dashboard, because it manufactures confidence
    the code doesn't back — so each row says which function does the checking,
    or that nothing here does.
    """
    rows = []
    if not grant:
        return rows
    for side, cfg in (grant.get("arms") or {}).items():
        if cfg.get("workspace_m"):
            rows.append({"bound": f"arms.{side}.workspace_m", "value": cfg["workspace_m"],
                         "enforced": True, "how": "move_arm refuses (outcome=denied)",
                         "where": "_grant_workspace_violation"})
        if cfg.get("max_velocity_mps") is not None:
            rows.append({"bound": f"arms.{side}.max_velocity_mps", "value": cfg["max_velocity_mps"],
                         "enforced": False, "how": "declared only — no arm-velocity check here",
                         "where": None})
        if cfg.get("max_force_n") is not None:
            rows.append({"bound": f"arms.{side}.max_force_n", "value": cfg["max_force_n"],
                         "enforced": False,
                         "how": "declared only — grip force is capped by grippers.*, not this",
                         "where": None})
    for side, cfg in (grant.get("grippers") or {}).items():
        if cfg.get("max_grip_force_n") is not None:
            rows.append({"bound": f"grippers.{side}.max_grip_force_n", "value": cfg["max_grip_force_n"],
                         "enforced": True, "how": "grasp_arm clamps (never amplifies)",
                         "where": "_grant_max_grip_force"})
    bases = grant.get("bases") or {}
    _bound_name, bound_base = base_entry(bases)
    for side, cfg in bases.items():
        # Only the entry that actually binds this robot's base is enforced; a
        # second one is listed as unenforced rather than implied to apply.
        applies = cfg is bound_base
        if cfg.get("floor_area_m"):
            rows.append({"bound": f"bases.{side}.floor_area_m", "value": cfg["floor_area_m"],
                         "enforced": applies,
                         "how": "move_base refuses (outcome=denied)" if applies else
                                "declared only — ambiguous which base this binds",
                         "where": "_grant_floor_violation" if applies else None})
        if cfg.get("max_speed_mps") is not None:
            rows.append({"bound": f"bases.{side}.max_speed_mps", "value": cfg["max_speed_mps"],
                         "enforced": applies,
                         "how": "move_base clamps (never amplifies)" if applies else
                                "declared only — ambiguous which base this binds",
                         "where": "_grant_max_base_speed" if applies else None})
    return rows


class Chain:
    """A hash-chained event log with a bounded in-memory window.

    Same event ids as `trail.Trail` (and so as lex-trail's own `event.lex`), but
    a long-lived sidecar can't hold an unbounded chain in RAM. Evicted events
    are not silently forgotten: the id of the last one leaves as `checkpoint`,
    and `verify()` checks the retained window links back to it. Set
    LEX_XLE_TRAIL_PATH to append every event to a JSONL file first, so the
    full chain survives eviction on disk where `lex-trail` can replay it.
    """

    def __init__(self, window: int = 2000, path: Optional[str] = None) -> None:
        self.window = max(1, window)
        self.path = path
        self.events: deque = deque()
        self.head: Optional[str] = None
        self.checkpoint: Optional[str] = None   # id of the newest EVICTED event
        self.total = 0
        self.write_error: Optional[str] = None
        # The sidecar is a ThreadingHTTPServer: two skill calls can complete at
        # once. Reading `head`, hashing against it and storing the new one is
        # not atomic, and two threads interleaving there would give two events
        # the same parent -- a chain that is broken on arrival, which is worse
        # than no chain. Every read and write of the chain takes this.
        self._lock = threading.RLock()

    def emit(self, kind: str, payload: dict, ts_ms: int) -> dict:
        payload_json = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        with self._lock:
            evt = {"id": compute_id(kind, self.head, payload_json, ts_ms), "kind": kind,
                   "parent": self.head, "payload_json": payload_json, "ts_ms": ts_ms}
            self.head = evt["id"]
            self.total += 1
            self._persist(evt)
            self.events.append(evt)
            while len(self.events) > self.window:
                self.checkpoint = self.events.popleft()["id"]
        return evt

    def _persist(self, evt: dict) -> None:
        if not self.path:
            return
        try:
            with open(self.path, "a") as f:
                f.write(json.dumps(evt, separators=(",", ":")) + "\n")
        except OSError as e:
            # Never let an audit write take the robot down — but never let it
            # fail silently either: the page shows this string.
            self.write_error = str(e)

    def verify(self) -> dict:
        with self._lock:
            prev, events = self.checkpoint, list(self.events)
        for e in events:
            if e["parent"] != prev:
                return {"ok": False, "detail": f"broken link at {e['id'][:12]}",
                        "checked": len(events)}
            if e["id"] != compute_id(e["kind"], e["parent"], e["payload_json"], e["ts_ms"]):
                return {"ok": False, "detail": f"id mismatch at {e['id'][:12]}",
                        "checked": len(events)}
            prev = e["id"]
        return {"ok": True, "detail": "", "checked": len(events)}

    def to_json(self) -> str:
        with self._lock:
            return json.dumps(list(self.events), indent=2)


class Ledger:
    """The recorded decisions, plus the chain that makes the sequence evident."""

    def __init__(self, max_decisions: int = 200, window: int = 2000,
                 path: Optional[str] = None, include_reads: bool = False,
                 clock: Optional[Callable[[], float]] = None) -> None:
        self.decisions: deque = deque(maxlen=max(1, max_decisions))
        self.chain = Chain(window=window, path=path)
        self.include_reads = include_reads
        self.counters = {v: 0 for v in VERDICTS}
        self.by_capability: dict = {}
        self.started_at = (clock or time.time)()
        self._clock = clock or time.time
        self._seq = 0
        self._last_ts = 0
        # Held across a whole record(): the invoked/completed pair for one call
        # must land adjacent in the chain, or reading the trail means guessing
        # which completion belongs to which invocation.
        self._lock = threading.RLock()

    def _next_ts(self) -> int:
        # Strictly increasing: two calls inside the same millisecond would
        # otherwise produce events whose order the timestamps don't show.
        ts = int(self._clock() * 1000)
        self._last_ts = max(ts, self._last_ts + 1)
        return self._last_ts

    def record(self, name: str, args, result, grant: Optional[dict] = None,
               firmware: Optional[dict] = None) -> Optional[dict]:
        """Record one completed skill call. Returns the decision, or None if
        the call was a read and reads aren't being recorded."""
        if not is_authority(name, self.include_reads):
            return None
        verdict = classify(name, args if isinstance(args, dict) else {}, result, grant, firmware)
        shown_args = summarize_args(args)
        with self._lock:
            return self._append(name, verdict, shown_args)

    def _append(self, name: str, verdict: dict, shown_args: dict) -> dict:
        self._seq += 1
        decision = {
            "seq": self._seq,
            "ts": round(self._clock(), 3),
            "capability": name,
            "category": category(name),
            "args": shown_args,
            "verdict": verdict["verdict"],
            "reason": verdict["reason"],
            "clamps": verdict["clamps"],
        }
        ts_ms = self._next_ts()
        invoked = self.chain.emit("cap.invoked", {"capability": name, "args": shown_args}, ts_ms)
        completed = self.chain.emit(
            "cap.completed",
            {"capability": name, "verdict": verdict["verdict"], "reason": verdict["reason"]},
            self._next_ts())
        decision["invoked_id"] = invoked["id"]
        decision["completed_id"] = completed["id"]

        self.counters[verdict["verdict"]] = self.counters.get(verdict["verdict"], 0) + 1
        per = self.by_capability.setdefault(name, {v: 0 for v in VERDICTS})
        per[verdict["verdict"]] += 1
        self.decisions.append(decision)
        return decision

    def snapshot(self, limit: int = 50) -> dict:
        with self._lock:
            recent = list(self.decisions)[-max(0, limit):] if limit else []
            counters = dict(self.counters)
            per_cap = {k: dict(v) for k, v in sorted(self.by_capability.items())}
            recorded, retained = self._seq, len(self.decisions)
        return {
            "counters": counters,
            "by_capability": per_cap,
            "recorded": recorded,
            "retained": retained,
            "include_reads": self.include_reads,
            "uptime_s": round(self._clock() - self.started_at, 1),
            "decisions": recent,
            "chain": {
                "total_events": self.chain.total,
                "window": self.chain.window,
                "retained": len(self.chain.events),
                "head": self.chain.head,
                "checkpoint": self.chain.checkpoint,
                "path": self.chain.path,
                "write_error": self.chain.write_error,
                "verified": self.chain.verify(),
            },
        }


def ledger_from_env(env=None) -> Ledger:
    env = os.environ if env is None else env
    return Ledger(
        max_decisions=int(env.get("LEX_XLE_LEDGER_MAX", "200")),
        window=int(env.get("LEX_XLE_TRAIL_WINDOW", "2000")),
        path=env.get("LEX_XLE_TRAIL_PATH") or None,
        include_reads=env.get("LEX_XLE_LEDGER_READS", "") not in ("", "0"),
    )
