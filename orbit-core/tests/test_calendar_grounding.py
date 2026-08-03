from __future__ import annotations

from app.calendar_grounding import (
    ground_calendar_reply,
    is_schedule_or_calendar_question,
    reply_mentions_times_not_in_snapshot,
)


def test_is_schedule_or_calendar_question() -> None:
    assert is_schedule_or_calendar_question("What's on my schedule today?")
    assert is_schedule_or_calendar_question("Anything on my calendar tomorrow?")
    assert not is_schedule_or_calendar_question("Refactor the router module")


def test_reply_times_must_match_snapshot() -> None:
    snap = "Apr 19, 2026 at 23:59 — HSCI Quiz\nAll day (Apr 20, 2026) — Holiday"
    assert reply_mentions_times_not_in_snapshot(
        "You have a break at 10:30 AM and a meeting at 2:00 PM with your professor.",
        snap,
    )
    assert not reply_mentions_times_not_in_snapshot(
        "You have HSCI at 11:59 PM tonight per your calendar.",
        snap,
    )


def test_ground_calendar_reply_replaces_hallucination() -> None:
    snap = "Apr 19, 2026 at 23:59 — HSCI Quiz\nAll day (Apr 20, 2026) — Holiday"
    bad = "You've got a 10-minute break at 10:30 AM, and then a 30-minute meeting at 2:00 PM."
    out = ground_calendar_reply(
        bad,
        user_message="What's on my schedule today?",
        route="tooling",
        tooling_context=snap,
        client_local_iso="2026-04-20T12:00:00",
    )
    assert "10:30" not in out
    assert "2:00" not in out.lower()
    assert "Mac Calendar snapshot" in out or "calendar snapshot" in out.lower()


def test_ground_calendar_reply_no_snapshot() -> None:
    out = ground_calendar_reply(
        "You have a meeting at 3:00 PM.",
        user_message="What's on my calendar?",
        route="tooling",
        tooling_context=None,
    )
    assert "refresh" in out.lower()
