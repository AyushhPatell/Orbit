"""Presence model (V4, 2026-08-03) — stepping away and coming back.

From the field test: *"I am going for a bath now, I will be back in 30 minutes"* — ORBIT
had no notion of him leaving, so there was no notion of him returning either. A companion
notices both.

The distinction that matters: a departure is happening NOW. "I'm going to the gym after my
shift" is a plan for later, and treating it as a departure would have ORBIT greeting him
back while he's still sitting there.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta

from app.main import _departure_minutes, detect_departure, presence_note_on_return

FMT = "%Y-%m-%d %H:%M:%S"
NOW = datetime(2026, 8, 12, 15, 0, 0)


def _away(minutes_ago: int, said: str, expected: int | None = 30) -> str:
    return json.dumps({
        "at": (NOW - timedelta(minutes=minutes_ago)).strftime(FMT),
        "minutes": expected,
        "said": said,
    })


def test_the_field_test_sentence_is_a_departure() -> None:
    got = detect_departure("I am going for a bath now, I will be back in 30 minutes")
    assert got is not None
    assert got["minutes"] == 30


def test_departure_phrasings() -> None:
    for text, minutes in [
        ("brb", None),
        ("be right back", None),
        ("back in 10 minutes", 10),
        ("I'll be back in an hour", 60),
        ("back in half an hour", 30),
        ("going for a shower", None),
        ("heading out for a bit", None),
        ("gotta go, talk later", None),
        ("going out to grab a coffee, back in 20 mins", 20),
    ]:
        got = detect_departure(text)
        assert got is not None, text
        assert got["minutes"] == minutes, text


def test_future_plans_are_not_departures() -> None:
    """The trap: these describe later, not now."""
    for text in [
        "I'm going to the gym after my shift",
        "going out for dinner tomorrow",
        "I'll be back at work on Monday",
        "we're heading out this weekend",
        "remind me to go out for a walk tonight",
    ]:
        assert detect_departure(text) is None, text


def test_ordinary_messages_are_not_departures() -> None:
    for text in ["turn off the wifi", "how are you", "what's on my calendar", "Um", "okay"]:
        assert detect_departure(text) is None, text


def test_duration_parsing() -> None:
    assert _departure_minutes("back in 45 minutes") == 45
    assert _departure_minutes("back in 2 hours") == 120
    assert _departure_minutes("back in a couple of hours") == 120
    assert _departure_minutes("back in a few minutes") == 5
    assert _departure_minutes("just heading out") is None


def test_return_after_a_real_absence_produces_a_note() -> None:
    note = presence_note_on_return(_away(28, "going for a bath, back in 30 minutes"), now=NOW)
    assert note is not None
    assert "28 minutes" in note
    assert "first message since" in note
    # It must not turn the welcome into another briefing — that was the 3 PM bug.
    assert "Do NOT list his plans" in note


def test_still_talking_is_not_a_return() -> None:
    """A message moments later means he never left — no welcome-back."""
    assert presence_note_on_return(_away(1, "brb"), now=NOW) is None


def test_back_much_sooner_than_promised_is_noticed() -> None:
    note = presence_note_on_return(_away(5, "back in an hour", expected=60), now=NOW)
    assert note is not None and "sooner than he said" in note


def test_back_much_later_than_promised_is_noticed() -> None:
    note = presence_note_on_return(_away(120, "back in 30 minutes", expected=30), now=NOW)
    assert note is not None and "longer than he expected" in note


def test_a_stale_absence_expires() -> None:
    """Back the next day is not 'welcome back' — it's a new day."""
    assert presence_note_on_return(_away(60 * 20, "brb"), now=NOW) is None


def test_corrupt_state_is_ignored() -> None:
    assert presence_note_on_return("not json", now=NOW) is None
    assert presence_note_on_return(json.dumps({"nope": 1}), now=NOW) is None
