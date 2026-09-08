#!/usr/bin/env python3
"""Phone teleoperation on Android, without dragging in `hebi-py`.

WHY THIS FILE EXISTS

`lerobot`'s phone teleoperator turns a phone into a 6-DoF motion controller --
it reports `phone.pos` AND `phone.rot`, so unlike lerobot's generic `gamepad`
teleoperator (three translation deltas plus a gripper, no wrist orientation) it
can demonstrate a full pose. On Android it does that over WebXR, served from
this machine; nothing is bought and nothing is worn.

The obstacle is a dependency that is not actually a dependency.
`AndroidPhone.__init__` calls `require_package("hebi-py")`, but **`hebi` is used
in exactly one place in that whole module** -- `hebi.Lookup()` inside
`IOSPhone.connect()`. The Android class never touches it: it drives
`teleop.Teleop()` on a background thread and reads poses from a callback. The
guard is copied from the iOS class and never exercised.

That copy is not harmless here. `hebi-py` declares `numpy<2.0`, so installing it
DOWNGRADES numpy 2.2.6 -> 1.26.4, and this machine's `cv2`, `torch` and
`lerobot` are built against numpy 2.x. Verified with `pip install --dry-run`
before anything was installed: `teleop` alone touches no numpy at all.

WHAT THIS DOES, AND WHAT IT REFUSES TO DO

It suppresses that one guard, for that one package, for the duration of one
constructor call, and restores it afterwards even if the constructor raises.
It does NOT patch site-packages (global, shared, lost on reinstall) and does NOT
reimplement `AndroidPhone.__init__` (which would silently rot the day lerobot
changes it).

The proper fix is upstream: drop the line from `AndroidPhone.__init__`. Until
that lands this is the seam, and it is deliberately narrow -- if lerobot ever
starts genuinely using `hebi` on the Android path, the import inside the
constructor fails loudly here rather than being papered over.
"""
from __future__ import annotations

import contextlib

_HEBI = "hebi-py"


@contextlib.contextmanager
def _hebi_guard_suppressed(module):
    """Neutralise `require_package("hebi-py")` in `module`, and only that.

    Every other package keeps its real guard, so a genuinely missing dependency
    still raises the same ImportError it always did.
    """
    original = module.require_package

    def guard(package, *args, **kwargs):
        if package == _HEBI:
            return None
        return original(package, *args, **kwargs)

    module.require_package = guard
    try:
        yield
    finally:
        module.require_package = original


def android_phone(config=None):
    """An `AndroidPhone` teleoperator, built without `hebi-py` installed.

    Returns lerobot's own class -- not a subclass -- so it stays a drop-in for
    anything that takes a Teleoperator.

    `connect()` starts a WebXR server (default https://<this-host>:4443) and
    then BLOCKS in calibration until the phone sends a capture trigger. The
    certificate is self-signed, so the phone will warn; WebXR needs Chrome on
    Android. iPhones take lerobot's other path, which really does need
    `hebi-py` and the HEBI Mobile I/O app.
    """
    import lerobot.teleoperators.phone.teleop_phone as teleop_phone
    from lerobot.teleoperators.phone.config_phone import PhoneConfig, PhoneOS

    if config is None:
        config = PhoneConfig(phone_os=PhoneOS.ANDROID)
    if config.phone_os is not PhoneOS.ANDROID:
        raise ValueError(
            f"android_phone() is for Android; got phone_os={config.phone_os}. "
            "The iOS path genuinely uses hebi.Lookup(), so it needs hebi-py."
        )
    with _hebi_guard_suppressed(teleop_phone):
        return teleop_phone.AndroidPhone(config)
