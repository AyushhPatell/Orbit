from __future__ import annotations

from typing import AsyncGenerator

from app.models import Message
from app.providers.local_chat import chat_openai_compatible, stream_openai_compatible


async def chat_with_cloud(
    messages: list[Message],
    *,
    base_url: str,
    model: str,
    api_key: str,
    max_tokens: int,
) -> str:
    """
    Cloud tier: same OpenAI-compatible /v1/chat/completions contract as local MLX/Ollama.
    Point CLOUD_BASE_URL at api.openai.com, Gemini’s OpenAI-compat endpoint, or a LiteLLM proxy.
    """
    if not api_key.strip():
        raise RuntimeError(
            "Cloud tier selected but CLOUD_API_KEY is empty. "
            "Set CLOUD_API_KEY in orbit-core/.env (see README)."
        )
    return await chat_openai_compatible(
        base_url=base_url,
        model=model,
        messages=messages,
        bearer_token=api_key,
        max_tokens=max_tokens,
    )


async def stream_cloud(
    messages: list[Message],
    *,
    base_url: str,
    model: str,
    api_key: str,
    max_tokens: int,
) -> AsyncGenerator[str, None]:
    if not api_key.strip():
        raise RuntimeError("Cloud tier selected but CLOUD_API_KEY is empty.")
    async for token in stream_openai_compatible(
        base_url=base_url,
        model=model,
        messages=messages,
        bearer_token=api_key,
        max_tokens=max_tokens,
    ):
        yield token
