"""The proactivity governor + repetition guard (the 3 PM briefing case, 2026-08-03).

ORBIT volunteered a full memory recital in answer to "Um" and again to "okay?" —
because life events were injected INTO the user message on every turn, with no
novelty guard. These tests pin the replacement behaviour:
- volunteering is allowed only on conversational openers,
- a near-duplicate reply is detected structurally,
- a repeated time-of-day greeting is stripped.
"""
from __future__ import annotations

from app.main import (
    _is_conversational_opener,
    _is_near_duplicate_reply,
    _strip_repeated_greeting,
)
from app.models import Message

BRIEFING = (
    "Afternoon, Ayush. Looks like your call with Kan on Thursday at 2 PM is already "
    "deleted, and the call with Kawan at that time is good to go. Your Spiderman movie "
    "ticket reminder is still on for 5 PM today, and you're planning a quick breakfast now."
)


def test_openers_are_recognised() -> None:
    for t in [
        "hey", "Hi ORBIT", "good morning", "How are you?", "what's up",
        "are you there orbit", "catch me up", "what's new today", "ORBIT?",
        "hows it going",
    ]:
        assert _is_conversational_opener(t), t


def test_substantive_messages_are_not_openers() -> None:
    for t in [
        "I am going for a bath now, I will be back in 30 minutes",
        "remind me to buy tickets for Spiderman on Tuesday",
        "turn off the wifi",
        "good morning was rough, I barely slept",
        "hey can you set a reminder for five pm",
        "what's the weather like",
        "okay",
    ]:
        assert not _is_conversational_opener(t), t


def test_briefing_repeated_verbatim_is_detected() -> None:
    recent = [Message(role="user", content="Um"), Message(role="assistant", content=BRIEFING)]
    assert _is_near_duplicate_reply(BRIEFING, recent)


def test_briefing_lightly_reworded_is_detected() -> None:
    recent = [Message(role="assistant", content=BRIEFING)]
    reworded = BRIEFING.replace("Afternoon, Ayush. Looks like", "All clear with your plans:")
    assert _is_near_duplicate_reply(reworded, recent)


def test_fresh_reply_is_not_flagged() -> None:
    recent = [Message(role="assistant", content=BRIEFING)]
    assert not _is_near_duplicate_reply(
        "Sure — enjoy the bath, I'll be here when you're back.", recent
    )


def test_short_replies_are_exempt() -> None:
    recent = [Message(role="assistant", content="All set.")]
    assert not _is_near_duplicate_reply("All set.", recent)


def test_repeated_greeting_is_stripped() -> None:
    recent = [Message(role="assistant", content="Afternoon, Ayush. Your 5 PM reminder is set.")]
    out = _strip_repeated_greeting("Afternoon, Ayush. Nothing new on my end.", recent)
    assert out == "Nothing new on my end."


def test_first_greeting_is_kept() -> None:
    recent = [Message(role="assistant", content="Done — Wi-Fi is off.")]
    reply = "Evening, Ayush. How was the shift?"
    assert _strip_repeated_greeting(reply, recent) == reply


def test_content_starting_with_a_time_word_is_not_mangled() -> None:
    # "Night shift was rough" starts with a greeting word but is content, not a greeting.
    recent = [Message(role="assistant", content="Evening, Ayush. All quiet.")]
    reply = "Night shift talk again? Hope it went okay."
    assert _strip_repeated_greeting(reply, recent) == reply
