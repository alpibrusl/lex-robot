"""The hebi-py guard suppression must be narrow, and must always be undone.

The value of this seam is entirely in what it does NOT do, so that is what
these pin: one package, one call, restored on the way out including when the
constructor raises.
"""
import types

import pytest

from phone_teleop import _hebi_guard_suppressed, android_phone


def _fake_module():
    """A stand-in for lerobot's teleop_phone, so these tests need no lerobot."""
    m = types.SimpleNamespace(seen=[])

    def require_package(package, *a, **kw):
        m.seen.append(package)
        raise ImportError(f"{package!r} is required but not installed")

    m.require_package = require_package
    return m


def test_only_hebi_is_suppressed():
    m = _fake_module()
    with _hebi_guard_suppressed(m):
        assert m.require_package("hebi-py") is None
        with pytest.raises(ImportError, match="teleop"):
            m.require_package("teleop")


def test_the_guard_is_restored_afterwards():
    m = _fake_module()
    original = m.require_package
    with _hebi_guard_suppressed(m):
        assert m.require_package is not original
    assert m.require_package is original
    with pytest.raises(ImportError, match="hebi-py"):
        m.require_package("hebi-py")


def test_the_guard_is_restored_even_when_the_body_raises():
    # The failure that would matter: an exception inside the constructor
    # leaving every future require_package call permanently defanged.
    m = _fake_module()
    original = m.require_package
    with pytest.raises(RuntimeError):
        with _hebi_guard_suppressed(m):
            raise RuntimeError("constructor blew up")
    assert m.require_package is original


def test_ios_config_is_refused_rather_than_quietly_broken():
    # iOS really does use hebi.Lookup(); suppressing the guard there would
    # trade a clear ImportError for a NameError deep inside connect().
    pytest.importorskip("lerobot")
    from lerobot.teleoperators.phone.config_phone import PhoneConfig, PhoneOS

    with pytest.raises(ValueError, match="hebi-py"):
        android_phone(PhoneConfig(phone_os=PhoneOS.IOS))


def test_builds_lerobots_own_class_without_hebi_installed():
    pytest.importorskip("lerobot")
    pytest.importorskip("teleop")
    if __import__("importlib.util", fromlist=["util"]).find_spec("hebi") is not None:
        pytest.skip("hebi-py IS installed here, so this proves nothing")
    from lerobot.teleoperators.phone.teleop_phone import AndroidPhone

    phone = android_phone()
    assert type(phone) is AndroidPhone          # the real class, not a subclass
    assert not phone.is_connected
    assert "phone.rot" in phone.action_features  # the 6-DoF payload we came for
