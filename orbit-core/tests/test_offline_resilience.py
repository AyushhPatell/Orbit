"""
Offline resilience for the brain path.

ORBIT is a companion first: losing the internet must degrade it, never stop it. These guard the
exact failure Ayush hit — he asked ORBIT to turn Wi-Fi off, the tool ran, and the second leg of
the tool call then tried to reach the cloud over the connection it had just severed. That raised
503 and ended the turn mid-conversation.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import httpx
import pytest

import app.main as main
from app.models import ToolResultItem, ToolResultRequest


def _tool_request(result: str = "Wi-Fi is off.") -> ToolResultRequest:
    return ToolResultRequest(
        session_id="test-offline",
        original_message="turn off the wifi",
        results=[
            ToolResultItem(
                tool="set_system_feature",
                tool_call_id="call_1",
                params={"feature": "wifi", "state": "off"},
                result=result,
            )
        ],
    )


@pytest.fixture(autouse=True)
def _reset_reachability():
    main._brain_reachable = True
    yield
    main._brain_reachable = True


@pytest.mark.asyncio
async def test_tool_result_falls_back_to_local_model_when_brain_unreachable() -> None:
    """The turn must complete via the local model instead of raising 503."""
    with patch.object(main, "resume_after_tool", side_effect=httpx.ConnectError("offline")), \
         patch.object(main, "chat_openai_compatible", AsyncMock(return_value="Wi-Fi is off now.")):
        response = await main.chat_tool_result(_tool_request())

    assert "Wi-Fi is off now." in response.reply
    assert response.route == "local"


@pytest.mark.asyncio
async def test_tool_result_uses_raw_tool_output_when_local_model_also_down() -> None:
    """Last resort: the tool's own result is already human-readable — never strand the user."""
    with patch.object(main, "resume_after_tool", side_effect=httpx.ConnectError("offline")), \
         patch.object(main, "chat_openai_compatible", AsyncMock(side_effect=httpx.ConnectError("down"))):
        response = await main.chat_tool_result(_tool_request())

    assert "Wi-Fi is off." in response.reply


@pytest.mark.asyncio
async def test_offline_transition_is_announced_once_then_stays_quiet() -> None:
    """Losing the connection is announced on the way down, not repeated every turn."""
    with patch.object(main, "resume_after_tool", side_effect=httpx.ConnectError("offline")), \
         patch.object(main, "chat_openai_compatible", AsyncMock(return_value="Done.")):
        first = await main.chat_tool_result(_tool_request())
        second = await main.chat_tool_result(_tool_request())

    assert "lost the internet" in first.reply.lower()
    assert "lost the internet" not in second.reply.lower()


@pytest.mark.parametrize(
    "message",
    [
        "turn it on back",          # the real case: became "I've turned the volume up to 100%"
        "turn off the lights",
        "open chrome",
        "play some music",
        "set brightness to 30",
        "can you mute it",
    ],
)
def test_action_requests_are_recognised(message: str) -> None:
    assert main.looks_like_action_request(message)


@pytest.mark.parametrize(
    "message",
    [
        "how are you",
        "I need to call my mom later",          # 'call' present, but conversation
        "do you remember what I said yesterday",
        "I'm going to open up about something",  # 'open' present, but not a command
        "it was a rough day and I want to talk",
    ],
)
def test_conversation_is_not_mistaken_for_an_action(message: str) -> None:
    assert not main.looks_like_action_request(message)


@pytest.mark.asyncio
async def test_recovery_is_announced_once() -> None:
    """Coming back online says so exactly once, then goes quiet again."""
    main._brain_reachable = False
    with patch.object(main, "resume_after_tool", AsyncMock(return_value="All set.")):
        first = await main.chat_tool_result(_tool_request())
        second = await main.chat_tool_result(_tool_request())

    assert first.reply.startswith("Internet's back.")
    assert not second.reply.startswith("Internet's back.")
