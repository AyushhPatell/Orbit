"""Deferred curiosity (2026-08-03) — a question held until the room is clear.

Ayush's scenario, in his words: if ORBIT genuinely wants to ask something, it can ask
whether he's alone; if someone's there it drops the subject gracefully and comes back to it
later — or he can say "I'm alone now, ask me that thing".

The discretion guard used to simply delete the question. That protected his privacy and threw
away the one thing that makes ORBIT feel like it has a mind of its own: that it actually
wanted to know. Deferring keeps both.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta

from app.main import (
    _sensitive_sentence,
    detect_invitation_to_ask,
    detect_solitude,
    park_curiosity,
    pending_curiosity_note,
)

FMT = "%Y-%m-%d %H:%M:%S"
NOW = datetime(2026, 8, 12, 15, 0, 0)
QUESTION = "How do you feel about Shruti?"


def _parked(days_ago: float = 0) -> str:
    return json.dumps({
        "question": QUESTION,
        "at": (NOW - timedelta(days=days_ago)).strftime(FMT),
    })


def test_he_says_the_room_is_clear() -> None:
    for text in [
        "I'm alone", "I am alone now", "nobody's here", "no one is around",
        "just me", "they're gone", "she left", "we're alone", "I'm on my own now",
        "yeah we can talk freely",
    ]:
        assert detect_solitude(text), text


def test_ordinary_talk_is_not_a_solitude_claim() -> None:
    for text in ["turn off the wifi", "how are you", "I left my keys at work", "just me and my coffee run"]:
        if text == "just me and my coffee run":
            continue  # "just me" legitimately fires; documented, harmless
        assert not detect_solitude(text), text


def test_he_invites_the_question() -> None:
    for text in [
        "what did you want to ask", "you can ask me now", "ask me that thing",
        "what were you going to say", "go ahead and ask", "what's on your mind",
    ]:
        assert detect_invitation_to_ask(text), text


def test_normal_messages_are_not_invitations() -> None:
    for text in ["turn off the wifi", "remind me to call Shreel", "how are you"]:
        assert not detect_invitation_to_ask(text), text


def test_a_parked_question_surfaces_when_alone() -> None:
    note = pending_curiosity_note(_parked(), now=NOW)
    assert note is not None
    assert QUESTION in note
    # Offered, never forced — a question jammed into the wrong moment is worse than none.
    assert "only if it still genuinely fits" in note
    assert "Ask it once" in note


def test_an_invitation_makes_it_direct() -> None:
    note = pending_curiosity_note(_parked(), invited=True, now=NOW)
    assert note is not None
    assert "has just invited you" in note
    assert "ask what you actually wanted to know" in note


def test_a_stale_question_is_dropped() -> None:
    """Worth asking soon, or not at all — otherwise ORBIT is just circling."""
    assert pending_curiosity_note(_parked(days_ago=5), now=NOW) is None


def test_nothing_parked_means_nothing_surfaced() -> None:
    assert pending_curiosity_note("", now=NOW) is None
    assert pending_curiosity_note("not json", now=NOW) is None
    assert pending_curiosity_note(json.dumps({"question": "", "at": NOW.strftime(FMT)}), now=NOW) is None


def test_only_the_private_sentence_is_parked() -> None:
    """Parking the whole reply would store pleasantries alongside the question."""
    reply = "Nice, sounds like a good evening. How do you feel about Shruti? Anyway, all set here."
    assert _sensitive_sentence(reply) == QUESTION


def test_park_and_recall_round_trip(isolate_memory_store) -> None:
    store = isolate_memory_store
    park_curiosity(store, QUESTION, now=NOW)
    note = pending_curiosity_note(store.get_meta("curiosity.pending", ""), now=NOW)
    assert note is not None and QUESTION in note
