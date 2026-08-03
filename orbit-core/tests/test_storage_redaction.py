from __future__ import annotations

from app.main import content_for_storage


def test_content_for_storage_redacts_when_enabled() -> None:
    src = "email me at user@example.com and token=abcd1234secret"
    out = content_for_storage(src, redact_local_storage=True)
    assert "[redacted:email]" in out
    assert "[redacted:secret]" in out


def test_content_for_storage_passthrough_when_disabled() -> None:
    src = "plain text"
    assert content_for_storage(src, redact_local_storage=False) == src
