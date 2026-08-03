from __future__ import annotations

import json

from app.audit_log import append_chat_audit_event


def test_append_chat_audit_event_writes_jsonl(tmp_path) -> None:
    p = tmp_path / "chat_audit.jsonl"
    append_chat_audit_event(
        path=p,
        status="ok",
        session_id="session-123",
        route="local",
        route_hint="local",
        model="test-model",
        msg_chars=42,
        tooling_chars=0,
        cloud_redact=False,
        duration_ms=120,
        error=None,
    )
    raw = p.read_text(encoding="utf-8").strip()
    row = json.loads(raw)
    assert row["status"] == "ok"
    assert row["route"] == "local"
    assert row["model"] == "test-model"
    assert row["msg_chars"] == 42
    assert row["error"] == ""


def test_append_chat_audit_event_none_path_noop() -> None:
    append_chat_audit_event(
        path=None,
        status="error",
        session_id="s",
        route="cloud",
        route_hint="cloud",
        model=None,
        msg_chars=1,
        tooling_chars=0,
        cloud_redact=True,
        duration_ms=1,
        error="x",
    )


def test_audit_log_rotation(tmp_path) -> None:
    p = tmp_path / "chat_audit.jsonl"
    # Force rotation quickly.
    for i in range(12):
        append_chat_audit_event(
            path=p,
            status="ok",
            session_id=f"s{i}",
            route="local",
            route_hint="local",
            model="m",
            msg_chars=999,
            tooling_chars=0,
            cloud_redact=False,
            duration_ms=10,
            max_bytes=300,
            backup_count=2,
        )
    assert p.exists()
    assert p.with_suffix(".jsonl.1").exists()
