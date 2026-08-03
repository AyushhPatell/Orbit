from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.models import Message
from app.providers.local_chat import chat_openai_compatible


class _FakeAsyncClientCM:
    def __init__(self, client: MagicMock) -> None:
        self._client = client

    async def __aenter__(self) -> MagicMock:
        return self._client

    async def __aexit__(self, *args: object) -> None:
        return None


@pytest.mark.asyncio
async def test_chat_openai_compatible_sends_max_tokens() -> None:
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"choices": [{"message": {"content": "  hello  "}}]}
    mock_response.text = ""

    mock_inner = MagicMock()
    mock_inner.post = AsyncMock(return_value=mock_response)

    def factory(*args: object, **kwargs: object) -> _FakeAsyncClientCM:
        return _FakeAsyncClientCM(mock_inner)

    with patch("app.providers.local_chat.httpx.AsyncClient", side_effect=factory):
        out = await chat_openai_compatible(
            "http://127.0.0.1:8080",
            "test-model",
            [Message(role="user", content="hi")],
            max_tokens=512,
        )

    assert out == "hello"
    mock_inner.post.assert_called_once()
    kwargs = mock_inner.post.call_args.kwargs
    assert kwargs["json"]["max_tokens"] == 512
    assert kwargs["json"]["stream"] is False
