from __future__ import annotations

from typing import Literal, Optional, cast


Route = Literal["local", "cloud", "tooling"]


def classify_route(message: str, *, cloud_min_chars: int = 1200) -> Route:
    text = message.lower().strip()

    tool_keywords = (
        "calendar",
        "reminder",
        "schedule",
        "event",
        "todo",
        "task",
        "this week",
        "next week",
        "coming up",
        "upcoming",
        "agenda",
        "appointment",
        "appointments",
        "what's on",
        "whats on",
        "what is on",
        "my day",
        "free today",
        "busy today",
    )
    if any(keyword in text for keyword in tool_keywords):
        return "tooling"

    cloud_keywords = (
        "deep research",
        "compare papers",
        "long analysis",
        "multi-step plan with citations",
        "internet research",
        "latest news",
    )
    if any(keyword in text for keyword in cloud_keywords):
        return "cloud"

    if len(text) > cloud_min_chars:
        return "cloud"

    return "local"


def resolve_route(message: str, hint: Optional[str], *, cloud_min_chars: int = 1200) -> Route:
    """
    Tier-1 (Mac) can send route_hint from on-device classification.
    If hint is valid, it wins; otherwise fall back to server heuristics (same rules as classify_route).
    """
    if hint in ("local", "cloud", "tooling"):
        return cast(Route, hint)
    return classify_route(message, cloud_min_chars=cloud_min_chars)
