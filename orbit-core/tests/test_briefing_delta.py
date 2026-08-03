"""Delta briefings (V3, 2026-08-03).

An explicit "what's on today?" should get the picture — that is the one moment a rundown is
wanted. But asking again an hour later and hearing the identical list is the 3 PM recital all
over again, just invited rather than volunteered. What he has already been told is named for
the brain so it can lead with what changed.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta

from app.main import briefing_delta_note, is_briefing_request

FMT = "%Y-%m-%d %H:%M:%S"
NOW = datetime(2026, 8, 12, 15, 0, 0)

EVENTS = [
    {"summary": "Call scheduled with Kawan on Thursday at 2 PM"},
    {"summary": "Going to the gym after his shift"},
]


def _state(minutes_ago: int, covered: list[str]) -> str:
    return json.dumps({
        "at": (NOW - timedelta(minutes=minutes_ago)).strftime(FMT),
        "covered": covered,
    })


def test_briefing_requests_are_recognised() -> None:
    for text in [
        "what's on today", "what do I have today", "catch me up", "brief me",
        "what did I miss", "anything new", "what's my schedule", "how's my day looking",
        "what's happening today", "run me through my day",
    ]:
        assert is_briefing_request(text), text


def test_ordinary_messages_are_not_briefing_requests() -> None:
    for text in [
        "turn off the wifi", "how are you", "Um", "I'm going for a bath",
        "remind me to call mom", "what's the weather like in Halifax",
    ]:
        assert not is_briefing_request(text), text


def test_recent_briefing_produces_a_delta_note() -> None:
    covered = [e["summary"] for e in EVENTS]
    note = briefing_delta_note(_state(40, covered), EVENTS, now=NOW)
    assert note is not None
    assert "40 minutes ago" in note
    assert "Do NOT repeat those verbatim" in note
    assert "Call scheduled with Kawan on Thursday at 2 PM" in note


def test_an_old_briefing_gets_the_full_picture_again() -> None:
    covered = [e["summary"] for e in EVENTS]
    assert briefing_delta_note(_state(60 * 8, covered), EVENTS, now=NOW) is None


def test_covered_items_that_are_gone_are_not_mentioned() -> None:
    """Only what is still true gets suppressed — a retired plan shouldn't shape the reply."""
    note = briefing_delta_note(_state(30, ["Something that has since been resolved"]), EVENTS, now=NOW)
    assert note is None


def test_first_briefing_has_no_delta() -> None:
    assert briefing_delta_note("", EVENTS, now=NOW) is None
    assert briefing_delta_note(json.dumps({"at": NOW.strftime(FMT), "covered": []}), EVENTS, now=NOW) is None


def test_corrupt_state_is_ignored() -> None:
    assert briefing_delta_note("not json", EVENTS, now=NOW) is None
