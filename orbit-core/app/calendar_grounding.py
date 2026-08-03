"""
Ground calendar/schedule answers to the EventKit snapshot from the Mac client.

Prevents invented times, meetings, or titles that do not appear in the provided text.
"""

from __future__ import annotations

import re
from datetime import datetime
from typing import Optional


_SCHEDULE_MARKERS = re.compile(
    r"\b("
    r"calendar|schedule|scheduling|event|events|appointment|appointments|"
    r"meeting|meetings|agenda|what'?s on|what is on|my day|today|tomorrow|"
    r"this week|next week|coming up|free (?:today|tomorrow)|busy"
    r")\b",
    re.IGNORECASE,
)

# Times the model might mention (English); require AM/PM or 24h with colon to avoid "10-minute".
_TIME_PATTERNS = [
    re.compile(
        r"\b(?:[01]?\d|2[0-3]):[0-5]\d\s*(?:[ap]\.?m\.?)\b",
        re.IGNORECASE,
    ),
    re.compile(r"\b(?:[01]?\d|2[0-3]):[0-5]\d\b"),
    re.compile(r"\b(?:1[0-2]|0?[1-9])\s*(?:[ap]\.?m\.?)\b", re.IGNORECASE),
]

_12H = re.compile(
    r"\b(1[0-2]|0?[1-9]):([0-5]\d)\s*([ap]\.?m\.?)\b",
    re.IGNORECASE,
)
_24H = re.compile(r"\b([01]?\d|2[0-3]):([0-5]\d)\b")


def is_schedule_or_calendar_question(text: str) -> bool:
    t = (text or "").strip()
    if len(t) > 800:
        return False
    return bool(_SCHEDULE_MARKERS.search(t))


def _normalize_for_match(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").lower()).strip()


def _clock_minutes_in_text(text: str) -> set[int]:
    """Minutes since midnight for explicit 12h times and unambiguous 24h (13:00–23:59, 00:xx)."""
    out: set[int] = set()
    for m in _12H.finditer(text):
        h, mi = int(m.group(1)), int(m.group(2))
        ap = m.group(3).lower()
        if "p" in ap and h != 12:
            h += 12
        if "a" in ap and h == 12:
            h = 0
        out.add(h * 60 + mi)
    for m in _24H.finditer(text):
        h, mi = int(m.group(1)), int(m.group(2))
        span = m.span()
        preceding = text[max(0, span[0] - 4) : span[0]].lower()
        if "am" in preceding or "pm" in preceding:
            continue
        if h > 12 or h == 0:
            out.add(h * 60 + mi)
    return out


def reply_mentions_times_not_in_snapshot(reply: str, snapshot: str) -> bool:
    """True if reply contains explicit clock times that are not supported by the snapshot."""
    reply_times = _clock_minutes_in_text(reply)
    if not reply_times:
        return False
    snap_times = _clock_minutes_in_text(snapshot)
    if not snap_times:
        # Snapshot has text but no parseable times (e.g. all-day only); fall back to substring check.
        snap = _normalize_for_match(snapshot)
        for pat in _TIME_PATTERNS:
            for m in pat.finditer(reply):
                if _normalize_for_match(m.group(0)) not in snap:
                    return True
        return False
    return not reply_times.issubset(snap_times)


def snapshot_reports_no_events(snapshot: str) -> bool:
    s = (snapshot or "").lower()
    return "no calendar events" in s


def _snapshot_lines_for_today(snapshot: str, client_local_iso: Optional[str]) -> list[str]:
    lines = [ln.strip() for ln in (snapshot or "").splitlines() if ln.strip()]
    if not client_local_iso:
        return lines
    try:
        raw = client_local_iso.replace("Z", "+00:00")
        dt = datetime.fromisoformat(raw)
        day = dt.date()
        # Match DateFormatter medium-style "Apr 20, 2026" from the Mac client (locale may vary slightly).
        day_token = f"{day.strftime('%b')} {day.day}, {day.year}"
        day_token_long = f"{day.strftime('%B')} {day.day}, {day.year}"
    except ValueError:
        return lines
    out: list[str] = []
    for ln in lines:
        low = ln.lower()
        if day_token.lower() in low or day_token_long.lower() in low:
            out.append(ln)
    return out if out else lines


def _honest_reply_from_snapshot(
    snapshot: str,
    *,
    user_message: str,
    client_local_iso: Optional[str],
) -> str:
    snap = snapshot.strip()
    if snapshot_reports_no_events(snap):
        return (
            "Your Calendar snapshot from this Mac shows no events in that range, "
            "so I shouldn't invent anything. If something is missing, check other accounts "
            "in Calendar or tap Refresh in ORBIT."
        )
    um = (user_message or "").lower()
    if "today" in um and "tomorrow" not in um and client_local_iso:
        lines = _snapshot_lines_for_today(snap, client_local_iso)
        if not lines:
            lines = [ln for ln in snap.splitlines() if ln.strip()][:12]
        body = "\n".join(f"• {ln}" for ln in lines[:12])
        return (
            "I'm only going by your Mac Calendar snapshot right now. For today, I see:\n"
            f"{body}\n"
            "If that doesn't match what you expect, refresh the Calendar section in ORBIT."
        )
    lines = [ln.strip() for ln in snap.splitlines() if ln.strip()][:14]
    body = "\n".join(f"• {ln}" for ln in lines)
    return (
        "I'm only going by your Mac Calendar snapshot (next ~14 days from today). Here's what's listed:\n"
        f"{body}\n"
        "I won't add events that aren't shown there."
    )


def ground_calendar_reply(
    reply: str,
    *,
    user_message: str,
    route: str,
    tooling_context: Optional[str],
    client_local_iso: Optional[str] = None,
) -> str:
    """
    If this is a schedule question routed with tooling, ensure we don't emit fabricated times.

    When the model invents times not present in the snapshot, replace with an honest, snapshot-only answer.
    """
    if route != "tooling":
        return reply
    if not is_schedule_or_calendar_question(user_message):
        return reply

    snap = (tooling_context or "").strip()
    if not snap:
        return (
            "I don't have a calendar snapshot from your Mac in this request, so I can't list real events "
            "or times. Open ORBIT's Calendar section and tap Refresh, then ask again."
        )

    if snapshot_reports_no_events(snap):
        if reply_mentions_times_not_in_snapshot(reply, snap) or _looks_like_invented_busy_day(reply):
            return _honest_reply_from_snapshot(snap, user_message=user_message, client_local_iso=client_local_iso)
        return reply

    if reply_mentions_times_not_in_snapshot(reply, snap):
        return _honest_reply_from_snapshot(snap, user_message=user_message, client_local_iso=client_local_iso)

    return reply


def _looks_like_invented_busy_day(reply: str) -> bool:
    """Heuristic: claims a timed break/meeting without any snapshot line echoed."""
    low = reply.lower()
    if not any(w in low for w in ("break", "meeting", "professor", "call", "appointment")):
        return False
    return bool(_TIME_PATTERNS[0].search(reply) or _TIME_PATTERNS[1].search(reply))
