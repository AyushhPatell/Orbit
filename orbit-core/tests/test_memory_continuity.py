from __future__ import annotations

from app.main import (
    adaptive_style_prompt_block,
    is_casual_checkin,
    is_memory_recall_question,
    normalize_casual_checkin_reply,
    normalize_memory_recall_reply,
    shorten_reply_when_overlong,
    strip_false_memory_disclaimer,
    strip_repetitive_reassurance,
    user_wants_detailed_answer,
)
from app.models import Message


def test_is_memory_recall_question() -> None:
    assert is_memory_recall_question("Do you remember what we discussed last time?")
    assert is_memory_recall_question("where did we leave off on ORBIT?")
    assert not is_memory_recall_question("plan my evening study block")


def test_strip_false_memory_disclaimer() -> None:
    raw = (
        "I don't have a specific memory of our previous conversations, but I can try to recall some context. "
        "We discussed your plans for ORBIT and refined the menu bar UX."
    )
    out = strip_false_memory_disclaimer(raw)
    assert out.startswith("We discussed your plans for ORBIT")


def test_normalize_memory_recall_reply_with_recent_turns() -> None:
    raw = (
        "I don't have a specific memory of our previous conversations, but I can try to recall some context. "
        "We discussed ORBIT memory and Actions UX, but I don't have any specific details from before."
    )
    out = normalize_memory_recall_reply(raw, has_recent_turns=True)
    assert out.startswith("We discussed ORBIT memory")
    assert "don't have a specific memory" not in out.lower()
    assert "don't have any specific details" not in out.lower()


def test_normalize_memory_recall_reply_no_recent_turns() -> None:
    raw = "I don't have a specific memory of our previous conversations."
    out = normalize_memory_recall_reply(raw, has_recent_turns=False)
    assert out == raw


def test_strip_repetitive_reassurance_removes_boilerplate_line() -> None:
    raw = (
        "I'm doing well, thanks for asking. "
        "I'm always here to help and support you, so feel free to reach out whenever you need anything."
    )
    out = strip_repetitive_reassurance(raw)
    assert out == "I'm doing well, thanks for asking."


def test_strip_repetitive_reassurance_keeps_normal_reply() -> None:
    raw = "I am doing well today and focused on your ORBIT updates."
    out = strip_repetitive_reassurance(raw)
    assert out == raw


def test_is_casual_checkin() -> None:
    assert is_casual_checkin("How are you?")
    assert is_casual_checkin("Hey, how is it going today")
    assert not is_casual_checkin("Plan my schedule for next week with priorities")


def test_normalize_casual_checkin_reply_is_short_and_clean() -> None:
    raw = (
        "Déjà vu! You're testing my responses again, and I'm happy to oblige. "
        "I'm doing well, thanks for asking. "
        "I've noticed that you're testing my responses. "
        "How about I ask you something instead?"
    )
    out = normalize_casual_checkin_reply(raw)
    assert "Déjà vu" not in out
    assert "testing my responses" not in out.lower()
    assert "How about I ask you" not in out
    assert out == "I'm doing well, thanks for asking."


def test_user_wants_detailed_answer() -> None:
    assert user_wants_detailed_answer("Explain this in detail with steps")
    assert user_wants_detailed_answer("How do I implement this cleanly?")
    assert not user_wants_detailed_answer("Cool, run it")


def test_shorten_reply_when_overlong_for_short_prompt() -> None:
    reply = (
        "Great question. Here's a full breakdown of every moving part in the system and why each one matters. "
        "First we should evaluate architecture options and list trade-offs in depth. "
        "Then we can define implementation phases and test plans and monitoring. "
        "Finally we can discuss rollout safeguards and post-launch review loops."
    )
    out = shorten_reply_when_overlong(reply, user_message="Nice, so what now?")
    assert len(out.split()) < len(reply.split())
    assert len(out.split()) <= 58


def test_shorten_reply_when_overlong_respects_detailed_prompt() -> None:
    reply = (
        "This is a long answer with multiple sections covering architecture, implementation, and testing. "
        "It is intentionally long for a detailed request."
    )
    out = shorten_reply_when_overlong(reply, user_message="Can you explain this in detail step by step?")
    assert out == reply


def test_adaptive_style_prompt_block_prefers_concise() -> None:
    recent = [
        Message(role="user", content="keep it short please"),
        Message(role="assistant", content="Sure."),
        Message(role="user", content="just tell me what to run"),
    ]
    block = adaptive_style_prompt_block(recent, "ok now what")
    assert "1-3 short sentences" in block
    assert "Avoid follow-up questions" not in block


def test_adaptive_style_prompt_block_avoids_followups_when_user_signals() -> None:
    recent = [
        Message(role="user", content="don't ask follow up questions"),
        Message(role="assistant", content="Understood."),
    ]
    block = adaptive_style_prompt_block(recent, "give me the answer directly")
    assert "Avoid follow-up questions" in block


def test_adaptive_style_prompt_block_uses_persistent_style_prefs() -> None:
    recent = [Message(role="user", content="ok"), Message(role="assistant", content="sure")]
    block = adaptive_style_prompt_block(
        recent,
        "what now",
        style_prefs={"pref_concise": 0.7, "avoid_followups": 0.8},
    )
    assert "1-3 short sentences" in block
    assert "Avoid follow-up questions" in block
