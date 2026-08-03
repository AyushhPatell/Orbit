"""
Reply shaping must not strip ORBIT's personality.

`normalize_casual_checkin_reply` and `shorten_reply_when_overlong` were added to stop the 3B
local model rambling. Applied to the brain's replies they did real damage: every sentence ending
in "?" was deleted, so ORBIT could never ask "how was your shift?", and check-ins were capped at
26 words. That is the robotic feel Ayush has been describing, applied *after* the model got it
right. These lock the guardrails to the model that needs them.
"""

from __future__ import annotations

import pytest

from app.main import (
    needs_small_model_guardrails,
    normalize_casual_checkin_reply,
    shorten_reply_when_overlong,
    strip_repetitive_reassurance,
)

WARM_REPLY = (
    "Doing good, thanks for asking. How did the rest of your shift go? "
    "You mentioned it was running long."
)


@pytest.mark.parametrize("route", ["brain", "cloud"])
def test_capable_models_are_not_length_shaped(route: str) -> None:
    assert not needs_small_model_guardrails(route)


@pytest.mark.parametrize("route", ["local", "tooling"])
def test_small_model_keeps_its_guardrails(route: str) -> None:
    assert needs_small_model_guardrails(route)


def test_checkin_normaliser_is_what_strips_the_question() -> None:
    """Documents the damage: this is why a warm reply came back flattened."""
    flattened = normalize_casual_checkin_reply(WARM_REPLY)
    assert "?" not in flattened
    assert "How did the rest of your shift go" not in flattened


def test_brain_reply_survives_intact_end_to_end() -> None:
    """With guardrails off, the follow-up question and warmth reach the user."""
    reply = WARM_REPLY
    if needs_small_model_guardrails("brain"):
        reply = normalize_casual_checkin_reply(reply)
        reply = shorten_reply_when_overlong(reply, user_message="how are you")
    assert "How did the rest of your shift go?" in reply
    assert "You mentioned it was running long." in reply


def test_boilerplate_reassurance_is_still_stripped_for_every_route() -> None:
    """This one is kept everywhere — it removes filler, not personality."""
    noisy = "Sounds good. I'm always here to help, so feel free to reach out whenever you need anything."
    assert "always here to help" not in strip_repetitive_reassurance(noisy)
