from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def append_chat_audit_event(
    *,
    path: Optional[Path],
    status: str,
    session_id: str,
    route: str,
    route_hint: Optional[str],
    model: Optional[str],
    msg_chars: int,
    tooling_chars: int,
    cloud_redact: bool,
    duration_ms: int,
    error: Optional[str] = None,
    max_bytes: int = 2_000_000,
    backup_count: int = 4,
) -> None:
    """
    Appends one JSONL row for observability.
    Intentionally excludes raw message/reply content for privacy.
    """
    if path is None:
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    _rotate_if_needed(path, max_bytes=max_bytes, backup_count=backup_count)
    event = {
        "ts_utc": datetime.now(timezone.utc).isoformat(),
        "status": status,
        "session_id": session_id[:48],
        "route": route,
        "route_hint": route_hint,
        "model": model,
        "msg_chars": msg_chars,
        "tooling_chars": tooling_chars,
        "cloud_redact": cloud_redact,
        "duration_ms": duration_ms,
        "error": (error or "")[:500],
    }
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=True) + "\n")


def _rotate_if_needed(path: Path, *, max_bytes: int, backup_count: int) -> None:
    if not path.exists():
        return
    try:
        size = path.stat().st_size
    except OSError:
        return
    if size < max_bytes:
        return

    # chat_audit.jsonl -> .1, .1 -> .2, ... up to backup_count
    for idx in range(backup_count, 0, -1):
        src = path.with_suffix(path.suffix + f".{idx}")
        dst = path.with_suffix(path.suffix + f".{idx + 1}")
        if idx == backup_count and src.exists():
            try:
                src.unlink()
            except OSError:
                pass
            continue
        if src.exists():
            try:
                src.rename(dst)
            except OSError:
                pass
    first = path.with_suffix(path.suffix + ".1")
    try:
        path.rename(first)
    except OSError:
        # If rename fails, keep writing to current file.
        pass
