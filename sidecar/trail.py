"""Content-addressed event log — a Python mirror of lex-trail/src/event.lex.

Each event id is sha256(join([kind, parent_or_empty, payload_json, ts_ms], " ")),
and events chain via `parent` = the previous event's id. This lets the boxed
run emit a genuine lex-trail chain that lex-trail's replay/export can read and
that scripts/reconcile_audit.py can corroborate against the lex-os audit log.
"""
import hashlib
from typing import Optional


def compute_id(kind: str, parent: Optional[str], payload_json: str, ts_ms: int) -> str:
    # Field delimiter is NUL (\x00), matching lex-trail/src/event.lex's
    # `str.join([kind, p, payload_json, to_str(ts_ms)], "\x00")`. (A NUL can't
    # appear in any field value, so it can't be spoofed — that's why lex-trail
    # uses it.) Producing the same canonical string here means the ids validate
    # under lex-trail's own `is_valid`/replay.
    p = parent if parent is not None else ""
    canonical = "\x00".join([kind, p, payload_json, str(ts_ms)])
    return hashlib.sha256(canonical.encode()).hexdigest()


class Trail:
    def __init__(self) -> None:
        self.events: list[dict] = []

    def emit(self, kind: str, payload_json: str, ts_ms: int) -> dict:
        parent = self.events[-1]["id"] if self.events else None
        evt = {
            "id": compute_id(kind, parent, payload_json, ts_ms),
            "kind": kind,
            "parent": parent,
            "payload_json": payload_json,
            "ts_ms": ts_ms,
        }
        self.events.append(evt)
        return evt

    def verify(self) -> bool:
        prev = None
        for e in self.events:
            if e["parent"] != prev:
                return False
            if e["id"] != compute_id(e["kind"], e["parent"], e["payload_json"], e["ts_ms"]):
                return False
            prev = e["id"]
        return True

    def to_json(self) -> str:
        import json
        return json.dumps(self.events, indent=2)
