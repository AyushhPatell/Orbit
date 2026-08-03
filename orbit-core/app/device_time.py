from __future__ import annotations

from datetime import datetime
from typing import Optional


def daypart_for_local_hour(hour: int) -> str:
    """Local hour 0–23 → greeting daypart label."""
    if 5 <= hour < 12:
        return "morning"
    if 12 <= hour < 17:
        return "afternoon"
    if 17 <= hour < 22:
        return "evening"
    return "night"


def device_clock_prompt_block(client_local_iso: str, client_tz: str) -> Optional[str]:
    """
    Human-readable local time + explicit daypart so small LLMs follow wall clock,
    not chat history or guesses.
    """
    iso = (client_local_iso or "").strip()
    tz = (client_tz or "").strip()
    if not iso or not tz:
        return None
    try:
        normalized = iso.replace("Z", "+00:00")
        dt = datetime.fromisoformat(normalized)
    except ValueError:
        return None

    hour = dt.hour
    part = daypart_for_local_hour(hour)
    weekday = dt.strftime("%A")
    # e.g. 2026-04-18  7:45 PM (24h 19:45) for clarity
    ymd_hm = dt.strftime("%Y-%m-%d %H:%M")
    ampm = dt.strftime("%I:%M %p").lstrip("0")  # 7:45 PM

    return (
        "### Device time (authoritative — use only this for time of day)\n"
        f"- **IANA timezone:** `{tz}`\n"
        f"- **ISO (local offset):** `{iso}`\n"
        f"- **Parsed local:** {weekday} **{ymd_hm}** (12h **{ampm}**, local hour **{hour}**)\n"
        f"- **Greeting daypart:** **{part}** — open with good {part} / time-appropriate wording. "
        "**Do not** say it is morning unless daypart is morning. Ignore earlier turns that mentioned a different time of day.\n"
    )
