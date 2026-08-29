#!/usr/bin/env python3
"""The sidecar's perimeter: who may talk to it, who may change the robot, and
what happens when the caller goes quiet.

Everything here is pure-stdlib and importable without `lerobot`, `mujoco` or a
robot attached, so it is unit-tested standalone (`test_perimeter.py`) the same
way `collision.py` and the `clamp`/`diff_drive_wheel_speeds` helpers are.

Three pieces, each ported from a decision in
[pollen-robotics/microduck](https://github.com/pollen-robotics/microduck)
(Apache-2.0) and each solving a hole this sidecar actually has:

**1. The bind guard** (`assert_loopback`) — microduck, `architecture.md` §2.2:

    The wrong-interface bug class stops existing. Binding `0.0.0.0` by typo,
    by config, or by a "make it work from my laptop" patch would expose
    firmware update control to the network. [...] Weighted most heavily — not
    today's threat model, but the failure mode.

`HOST` is a loopback literal today, which is a convention, not an enforcement.
This makes it the latter: binding anything else takes an explicit, loud opt-in.

**2. Two-layer authorization** (`is_mutating`, `check_token`, `peer_allowed`) —
same section:

    the socket's group (mode 0660) decides who may **talk** to the daemon;
    `allow_uids`/`allow_gids` decide who may **change the robot** — mutating
    calls only. [...] Read-only calls are deliberately ungated: support must be
    able to inspect a robot it is not authorised to change.

Both gates default OFF, so every existing demo, test and `curl` in this repo
behaves exactly as before. Configure either and it engages. What is NOT
optional is the direction of the default for an *unknown* skill: it counts as
mutating. A read-only allow-list that someone forgets to extend fails closed
(a new sensor read gets needlessly gated); a mutating deny-list that someone
forgets to extend fails open (a new actuator is ungated). Only one of those is
survivable.

**3. The deadman** (`Deadman`) — microduck, `duck-control/src/safety.rs`:

    if intents stop arriving, the velocity goes to zero. **Stop is not limp** —
    losing comms makes the robot *stand still* [...] Zeroes the *twist* only.
    Head targets are left alone deliberately: a stale head pose is harmless,
    while a stale velocity walks the robot into a wall.

Here `move_base` is the twist and the arm hold is the head pose. `move_base` is
a goal-point command driven synchronously for up to `LEX_XLE_BASE_TIMEOUT_S`
(20 s), so a planner that stalls mid-inference, an HTTP client that is killed,
or a laptop that sleeps leaves the base driving to a goal nobody is waiting for
any more. The arm is deliberately untouched: dropping a hold is worse than
keeping it.
"""

from __future__ import annotations

import ipaddress
import hmac
import os
import socket
import struct
import time

# ── 1. The bind guard ────────────────────────────────────────────────────────

ALLOW_REMOTE_BIND_ENV = "LEX_ROBOT_ALLOW_REMOTE_BIND"


class RemoteBindRefused(RuntimeError):
    """Raised rather than binding a non-loopback address without an opt-in."""


def is_loopback(host: str) -> bool:
    """True for an address that only the local machine can reach.

    Name lookup is deliberately absent: this takes a literal, and a hostname
    that resolves to loopback today can resolve elsewhere tomorrow. Refusing
    what we cannot prove is the same call `lex-os-resolver` makes -- refuse,
    don't downgrade.
    """
    if not host:
        # An empty host means INADDR_ANY to the socket layer -- every
        # interface. That is precisely the mistake being guarded against.
        return False
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == "localhost"


def assert_loopback(host: str, env=None) -> None:
    """Refuse to bind anything the whole network can reach.

    Returns None when the bind is safe (or explicitly authorised); raises
    otherwise. The opt-in is an env var rather than a config field so that
    granting it is visible in the process that did it -- a systemd unit, a
    shell line -- rather than buried in a file nobody re-reads.
    """
    env = os.environ if env is None else env
    if is_loopback(host):
        return
    if env.get(ALLOW_REMOTE_BIND_ENV) == "1":
        return
    raise RemoteBindRefused(
        f"refusing to bind {host!r}: it is reachable from outside this machine, "
        f"and this sidecar actuates a robot with no authentication by default. "
        f"Set {ALLOW_REMOTE_BIND_ENV}=1 to override -- and set "
        f"LEX_ROBOT_SIDECAR_TOKEN too if you do."
    )


# ── 2. Two-layer authorization ───────────────────────────────────────────────

TOKEN_ENV = "LEX_ROBOT_SIDECAR_TOKEN"
TOKEN_FILE_ENV = "LEX_ROBOT_SIDECAR_TOKEN_FILE"
ALLOW_UIDS_ENV = "LEX_ROBOT_SIDECAR_ALLOW_UIDS"
ALLOW_GIDS_ENV = "LEX_ROBOT_SIDECAR_ALLOW_GIDS"

# Skills that only READ. Everything not listed here is treated as mutating --
# see the module docstring for why the default points this way.
#
# Names, not prefixes: `read_touch` reads and `render_qr` does not, so a
# `read_*` rule would be both over- and under-inclusive. A list is a chore to
# extend; guessing from a name is a bug waiting for the skill that breaks the
# pattern.
READ_ONLY_SKILLS = frozenset({
    "read_joints",
    "read_camera",
    "read_arm_pose",
    "read_base",
    "read_grant",
    "read_inlet",
    "read_touch",
    "workpiece_status",
    "locate_object",
    "transform_to_arm",
    "list_visible_items",
    "detect",
    "policy_action",
    "teach_home_get",
    "teach_list",
    "teach_status",
})


def is_mutating(skill: str) -> bool:
    """True when the call can change the robot or the world it is in.

    An unknown skill is mutating. That is the whole point: the set of things
    that move a robot grows every release, and the gate must not be the thing
    that has to be remembered.
    """
    return skill not in READ_ONLY_SKILLS


def configured_token(env=None) -> str | None:
    """The shared secret, or None when token auth is off (the default).

    A file is offered alongside the variable because an env var is visible in
    `/proc/<pid>/environ` to the same uid and lands in shell history; a
    `0600` file is the better home on a shared box.
    """
    env = os.environ if env is None else env
    token = env.get(TOKEN_ENV)
    if token:
        return token
    path = env.get(TOKEN_FILE_ENV)
    if path:
        try:
            with open(path, "r", encoding="utf-8") as f:
                token = f.read().strip()
        except OSError:
            return None
        return token or None
    return None


def check_token(header_value: str | None, skill: str, env=None) -> str | None:
    """None when the call may proceed; otherwise the reason it may not.

    Read-only calls are never gated, per microduck's two-layer rule: support
    must be able to inspect a robot it is not authorised to change.
    """
    expected = configured_token(env)
    if expected is None:
        return None
    if not is_mutating(skill):
        return None
    presented = _bearer(header_value)
    if presented is None:
        return "missing bearer token (this skill mutates the robot)"
    # Constant-time: the comparison is against a secret, and a token is short
    # enough that a naive `==` leaks its prefix to a patient caller.
    if not hmac.compare_digest(presented, expected):
        return "bad bearer token"
    return None


def _bearer(header_value: str | None) -> str | None:
    if not header_value:
        return None
    parts = header_value.split(None, 1)
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1].strip()
    return None


# ── SO_PEERCRED: who is on the other end of a unix socket ────────────────────

# Linux: SO_PEERCRED on SOL_SOCKET yields `struct ucred { pid, uid, gid }`.
# macOS: LOCAL_PEERCRED on SOL_LOCAL yields `struct xucred`, whose first two
# 32-bit fields are a version and the uid. The version must be 0 for the rest
# to mean anything.
_XUCRED_VERSION = 0
_SOL_LOCAL = 0
_LOCAL_PEERCRED = 1


def peer_credentials(conn: socket.socket):
    """(uid, gid) of the process on the other end, or None if unavailable.

    None is not a failure to report as an error -- it is a platform that does
    not offer the answer, and the caller degrades to filesystem permissions
    (which are still real) rather than pretending to an identity it does not
    have.
    """
    try:
        if hasattr(socket, "SO_PEERCRED"):
            raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                  struct.calcsize("3i"))
            _pid, uid, gid = struct.unpack("3i", raw)
            return (uid, gid)
        # macOS / BSD
        raw = conn.getsockopt(_SOL_LOCAL, _LOCAL_PEERCRED, 4 * 4)
        version, uid, _ngroups, gid = struct.unpack("4I", raw[:16])
        if version != _XUCRED_VERSION:
            return None
        return (uid, gid)
    except (OSError, struct.error, AttributeError):
        return None


def _id_set(value: str | None):
    if not value:
        return None
    out = set()
    for part in value.replace(",", " ").split():
        try:
            out.add(int(part))
        except ValueError:
            continue
    return out or None


def peer_allowed(creds, skill: str, env=None, own_uid=None) -> str | None:
    """None when this peer may make this call; otherwise the reason it may not.

    The uid the sidecar itself runs as is always permitted -- it could replace
    the sidecar binary regardless, so refusing it would be theatre. Everyone
    else needs listing, and an unknown peer is denied. Read-only calls are
    ungated, as above.
    """
    env = os.environ if env is None else env
    allow_uids = _id_set(env.get(ALLOW_UIDS_ENV))
    allow_gids = _id_set(env.get(ALLOW_GIDS_ENV))
    if allow_uids is None and allow_gids is None:
        return None
    if not is_mutating(skill):
        return None
    if creds is None:
        return ("peer credentials unavailable on this platform, and an "
                "allow-list is configured -- refusing rather than guessing")
    uid, gid = creds
    own = os.getuid() if own_uid is None else own_uid
    if uid == own:
        return None
    if allow_uids and uid in allow_uids:
        return None
    if allow_gids and gid in allow_gids:
        return None
    return f"uid {uid} (gid {gid}) is not permitted to change this robot"


# ── 3. The deadman ───────────────────────────────────────────────────────────

DEADMAN_MS_ENV = "LEX_XLE_DEADMAN_MS"


class Deadman:
    """Stops base motion when the caller stops saying it is still there.

    Two conditions arm it, and BOTH are required:

      1. an interval is configured, and
      2. at least one beat has arrived.

    (2) is what keeps every existing demo, test and script in this repo
    behaving exactly as it does today: nothing here beats, so nothing here is
    ever stopped. A caller that opts in by beating once has declared it will
    keep doing so, and going quiet after that is the event this exists to
    catch. An armed-from-birth deadman would instead stop the first base move
    of every program that had never heard of it -- which is how a safety
    feature gets switched off for good.

    Disarming is deliberately impossible: once a caller has claimed to be
    alive, it does not get to take that back.
    """

    def __init__(self, interval_ms: float = 0.0, clock=time.monotonic):
        self.interval_s = float(interval_ms) / 1000.0
        self._clock = clock
        self._last_beat = None

    @classmethod
    def from_env(cls, env=None, clock=time.monotonic) -> "Deadman":
        env = os.environ if env is None else env
        try:
            ms = float(env.get(DEADMAN_MS_ENV, "0") or "0")
        except ValueError:
            ms = 0.0
        return cls(ms, clock=clock)

    def beat(self) -> None:
        """Say the caller is alive -- and, on the first one, arm the deadman."""
        self._last_beat = self._clock()

    def beat_if_armed(self) -> None:
        """Refresh an already-armed deadman, but never arm one.

        Any skill call is evidence the caller is still there, so it should
        clear the deadman. It must NOT arm it: arming on ordinary traffic
        would mean the first `move_base` after any other call trips at the
        deadline in every deployment that merely set the interval, which is
        the armed-from-birth failure described in the class docstring.
        Arming stays the explicit act of sending a heartbeat.
        """
        if self.armed:
            self._last_beat = self._clock()

    @property
    def armed(self) -> bool:
        return self.interval_s > 0.0 and self._last_beat is not None

    def age_s(self):
        if self._last_beat is None:
            return None
        return self._clock() - self._last_beat

    def expired(self) -> bool:
        if not self.armed:
            return False
        return (self._clock() - self._last_beat) > self.interval_s

    def status(self) -> dict:
        return {
            "armed": self.armed,
            "interval_ms": round(self.interval_s * 1000.0),
            "age_ms": None if self.age_s() is None else round(self.age_s() * 1000.0),
            "expired": self.expired(),
        }

    def stop_detail(self) -> str:
        age = self.age_s()
        age_ms = "?" if age is None else f"{age * 1000.0:.0f}"
        return (f"deadman: no heartbeat for {age_ms}ms "
                f"(limit {self.interval_s * 1000.0:.0f}ms) -- base stopped. "
                f"Arm hold is untouched.")
