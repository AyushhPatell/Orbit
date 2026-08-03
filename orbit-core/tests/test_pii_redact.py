from __future__ import annotations

from app.models import Message
from app.pii_redact import redact_messages_copy, redact_text


def test_redact_email() -> None:
    assert "@" not in redact_text("Reach me at user@example.com thanks")
    assert "[redacted:email]" in redact_text("user@example.com")


def test_redact_phone_and_ssn() -> None:
    t = redact_text("Call 415-555-0100 or SSN 123-45-6789")
    assert "[redacted:phone]" in t
    assert "[redacted:ssn]" in t


def test_redact_keys_cards_and_ip() -> None:
    src = (
        "key sk-1234567890abcdefghijklmnop "
        "token=abcDEF1234567890 "
        "card 4242 4242 4242 4242 "
        "host 10.0.0.8"
    )
    t = redact_text(src)
    assert "[redacted:api_key]" in t
    assert "[redacted:secret]" in t
    assert "[redacted:card]" in t
    assert "[redacted:ip]" in t


def test_redact_messages_copy_preserves_roles() -> None:
    src = [
        Message(role="system", content="sys user@test.com"),
        Message(role="user", content="hello"),
    ]
    out = redact_messages_copy(src)
    assert out[0].role == "system"
    assert "[redacted:email]" in out[0].content
    assert out[1].content == "hello"
