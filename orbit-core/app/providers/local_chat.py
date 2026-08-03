from __future__ import annotations

import json
from typing import Any, AsyncGenerator, Optional

import httpx

from app.models import Message


def _base(url: str) -> str:
    return url.rstrip("/")


async def chat_openai_compatible(
    base_url: str,
    model: str,
    messages: list[Message],
    bearer_token: Optional[str] = None,
    max_tokens: Optional[int] = None,
) -> str:
    """
    OpenAI-style POST /v1/chat/completions.
    Works with Ollama (11434), MLX-LM server (8080), LM Studio, etc.
    """
    b = _base(base_url)
    payload: dict[str, Any] = {
        "model": model,
        "messages": [message.model_dump() for message in messages],
        "stream": False,
    }
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens

    url = f"{b}/v1/chat/completions"

    headers: dict[str, str] = {}
    if bearer_token:
        headers["Authorization"] = f"Bearer {bearer_token}"

    async with httpx.AsyncClient(timeout=120) as client:
        response = await client.post(url, json=payload, headers=headers)

    if response.status_code >= 400:
        snippet = (response.text or "")[:2000]
        raise RuntimeError(
            f"Local LLM returned HTTP {response.status_code} from {url}. "
            f"Body (truncated): {snippet}"
        )

    data = response.json()
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError(f"Local LLM returned no choices: {data!r}")

    content = choices[0].get("message", {}).get("content")
    if not content or not str(content).strip():
        raise RuntimeError(f"Local LLM returned empty content: {data!r}")

    return str(content).strip()


async def stream_openai_compatible(
    base_url: str,
    model: str,
    messages: list[Message],
    bearer_token: Optional[str] = None,
    max_tokens: Optional[int] = None,
) -> AsyncGenerator[str, None]:
    """Yields text tokens from a streaming /v1/chat/completions response."""
    b = _base(base_url)
    payload: dict[str, Any] = {
        "model": model,
        "messages": [m.model_dump() for m in messages],
        "stream": True,
    }
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens

    headers: dict[str, str] = {}
    if bearer_token:
        headers["Authorization"] = f"Bearer {bearer_token}"

    url = f"{b}/v1/chat/completions"
    async with httpx.AsyncClient(timeout=120) as client:
        async with client.stream("POST", url, json=payload, headers=headers) as response:
            if response.status_code >= 400:
                body = await response.aread()
                raise RuntimeError(
                    f"Local LLM returned HTTP {response.status_code} from {url}. "
                    f"Body: {body[:2000]!r}"
                )
            async for line in response.aiter_lines():
                if not line.startswith("data: "):
                    continue
                payload_str = line[len("data: "):]
                if payload_str.strip() == "[DONE]":
                    return
                try:
                    chunk = json.loads(payload_str)
                    token = chunk.get("choices", [{}])[0].get("delta", {}).get("content") or ""
                    if token:
                        yield token
                except (json.JSONDecodeError, IndexError, KeyError):
                    continue
