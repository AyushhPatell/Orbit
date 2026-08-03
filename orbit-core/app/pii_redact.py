from __future__ import annotations

import re

from app.models import Message

# Conservative patterns for outbound cloud payloads only. Local memory stays unchanged.
_EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
_SSN = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")
_PHONE = re.compile(
    r"\b(?:\+?1[-.\s]?)?(?:\([0-9]{3}\)|[0-9]{3})[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}\b"
)
_CARD = re.compile(r"\b(?:\d[ -]*?){13,19}\b")
_IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
_OPENAI_KEY = re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")
_GENERIC_TOKEN = re.compile(
    r"\b(?:api[_-]?key|token|secret|password)\s*[:=]\s*([A-Za-z0-9_\-./+=]{8,})",
    re.IGNORECASE,
)


def redact_text(text: str) -> str:
    """Replace common PII-shaped substrings before sending content to a cloud LLM."""
    if not text:
        return text
    t = _EMAIL.sub("[redacted:email]", text)
    t = _SSN.sub("[redacted:ssn]", t)
    t = _PHONE.sub("[redacted:phone]", t)
    t = _OPENAI_KEY.sub("[redacted:api_key]", t)
    t = _GENERIC_TOKEN.sub(lambda m: m.group(0).replace(m.group(1), "[redacted:secret]"), t)
    # Keep this after secrets so card-like token values in `token=...` are already masked.
    t = _CARD.sub("[redacted:card]", t)
    t = _IPV4.sub("[redacted:ip]", t)
    return t


def redact_messages_copy(messages: list[Message]) -> list[Message]:
    """Return new Message list with redact_text applied to every block (system, user, assistant)."""
    return [Message(role=m.role, content=redact_text(m.content)) for m in messages]
