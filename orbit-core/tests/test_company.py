"""Company awareness (E5, 2026-08-03) — ORBIT notices when Ayush isn't alone.

Real moments from his transcripts, which the old system filed as *facts about Ayush*:

    [relationships] "Meet my friend Shruti she's listening do you want to say hi"
    [relationships] "No thank you my friend Kawan is here would you like to talk with him"

Those are situations, not biography. What matters is what ORBIT does with them: greet the
person, and stop volunteering Ayush's private life to an audience he did not choose.

Deliberately NOT a lockdown — if he asks for his reminders he still gets them. Only
unprompted sharing stops.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta

from app.main import company_note, detect_company, detect_company_left

FMT = "%Y-%m-%d %H:%M:%S"
NOW = datetime(2026, 8, 12, 15, 0, 0)

KNOWN = [
    {"name": "Kavan", "relationship": "close friend and housemate", "aliases": ["kawan", "kan"]},
    {"name": "Shruti", "relationship": "close friend", "aliases": ["shruthi"]},
    {"name": "Nishika", "relationship": "close friend", "aliases": ["nishka"]},
]


def _state(minutes_ago: int, names: list[str]) -> str:
    return json.dumps({
        "at": (NOW - timedelta(minutes=minutes_ago)).strftime(FMT),
        "names": names,
        "wants_greeting": True,
    })


def test_the_real_transcript_lines_are_recognised() -> None:
    got = detect_company("Meet my friend Shruti she's listening do you want to say hi", KNOWN)
    assert got is not None
    assert "Shruti" in got["names"]
    assert got["wants_greeting"]

    got = detect_company("my friend Kavan is here would you like to talk with him", KNOWN)
    assert got is not None and "Kavan" in got["names"]


def test_various_ways_of_saying_someone_is_here() -> None:
    for text, expected in [
        ("say hi to Nishika", "Nishika"),
        ("Shruti is here", "Shruti"),
        ("I'm with Kavan", "Kavan"),
        ("Kavan wants to talk to you", "Kavan"),
        ("my friend Shruti is sitting next to me", "Shruti"),
    ]:
        got = detect_company(text, KNOWN)
        assert got is not None, text
        assert expected in got["names"], text


def test_generic_company_without_a_name() -> None:
    for text in ["someone is here", "we're here", "my friends are here", "I'm not alone"]:
        got = detect_company(text, KNOWN)
        assert got is not None, text


def test_ordinary_messages_are_not_company() -> None:
    for text in [
        "turn off the wifi",
        "what's on my calendar today",
        "remind me to call Kavan tomorrow",     # talking ABOUT him, not WITH him
        "how are you",
        "I am going for a bath now",
        "schedule a call with Kavan on Thursday at 2 PM",
    ]:
        assert detect_company(text, KNOWN) is None, text


def test_a_stray_capitalised_word_is_not_a_guest() -> None:
    """Without a relationship word or a greeting request, an unknown name is not a person."""
    assert detect_company("Halifax is here", KNOWN) is None
    assert detect_company("the weather is here", KNOWN) is None


def test_an_unknown_name_counts_when_introduced() -> None:
    got = detect_company("meet my friend Rajesh", KNOWN)
    assert got is not None and "Rajesh" in got["names"]


def test_departure_is_recognised() -> None:
    for text in ["he left", "she's gone", "they left", "I'm alone now", "just me now", "they're gone"]:
        assert detect_company_left(text), text


def test_departure_does_not_fire_on_normal_speech() -> None:
    for text in ["turn off the wifi", "how are you", "I left my keys at work"]:
        assert not detect_company_left(text), text


def test_note_asks_for_discretion_and_a_greeting() -> None:
    note = company_note(_state(5, ["Shruti"]), now=NOW)
    assert note is not None
    assert "Shruti" in note
    assert "do NOT volunteer" in note
    # Not a lockdown: a direct question is still answered.
    assert "answer him normally" in note


def test_company_expires() -> None:
    assert company_note(_state(10, ["Kavan"]), now=NOW) is not None
    assert company_note(_state(120, ["Kavan"]), now=NOW) is None


def test_generic_company_still_produces_discretion() -> None:
    note = company_note(json.dumps({"at": NOW.strftime(FMT), "names": []}), now=NOW)
    assert note is not None and "someone else" in note


def test_corrupt_state_is_ignored() -> None:
    assert company_note("not json", now=NOW) is None
    assert company_note("", now=NOW) is None
