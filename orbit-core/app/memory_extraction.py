"""
LLM-based memory extraction.

Replaces regex extraction, which stored raw transcript fragments rather than knowledge — 1188
turns produced 19 "memories" like "I am high what do you think about that you judge me", and
filed "I want to go for a sleep could you please turn on the sleep" under *goals*. Buried in
those same turns was a real fact — his shift ends at 4:30 — that regex could not distil.

Design notes, chosen with the iPhone/iPad future in mind:
- Runs on the **brain** (a network model), not the local Ollama tier, because the brain is the
  component that ports to iOS unchanged. Nothing here depends on a local daemon.
- Runs in the **background**: extraction never blocks a reply.
- Runs on a **window of turns**, not one message, so "my shift" and "until 4:30" can be joined.
- **Degrades, never fails**: if the network is down, the caller keeps the old regex path.
"""

from __future__ import annotations

import json
import logging
from typing import Any, Optional

import httpx

logger = logging.getLogger("orbit.memory.extract")

CURSOR_KEY = "extraction.last_turn_id"

# Enough turns to give context, few enough to stay cheap and within a small context window.
MIN_NEW_TURNS = 6
MAX_TURNS_PER_RUN = 30

VALID_CATEGORIES = {
    "identity", "work", "relationships", "routines",
    "preferences", "interests", "goals", "location", "health",
}

_SYSTEM_PROMPT = """You maintain the long-term memory of ORBIT, a personal AI companion, by reading \
recent conversation and recording what is worth remembering about the user long-term.

Return ONLY a JSON object of this exact shape:
{
  "knowledge": [{"category": "...", "fact": "...", "importance": 0.0-1.0}],
  "events":    [{"summary": "...", "category": "plan|feeling|life-update", "emotion": "positive|negative|stressed|low-energy|null", "when": "today|tomorrow|weekend|next-week|past|null", "importance": 0.0-1.0}]
}

"knowledge" = durable facts that stay true for weeks or months.
category must be one of: identity, work, relationships, routines, preferences, interests, goals, location, health.

"events" = things that happened or are planned, which matter now but fade.

Rules:
- Write each fact as a short third-person statement about the user: "Works as IT Support at
  Dalhousie University", "Shift ends at 4:30 PM", "Has a friend named Shruti". Never copy the
  user's sentence verbatim.
- The transcript comes from speech recognition and may be garbled. Record only what you are
  confident about; silently drop the rest.
- Record nothing from commands ("turn off wifi"), small talk, or ORBIT's own replies.
- Do NOT repeat anything in the "Already known" list.
- One clean fact is better than five noisy ones. Empty arrays are a perfectly good answer.
"""


async def extract_memories(
    turns: list[tuple[int, str, str]],
    known_facts: list[str],
    *,
    api_key: str,
    base_url: str,
    model: str,
    timeout: float = 45.0,
) -> Optional[dict[str, list[dict[str, Any]]]]:
    """Distil a window of turns into durable knowledge and episodic events, or None on failure."""
    user_lines = [f"{role}: {content}" for _, role, content in turns if content.strip()]
    if not user_lines:
        return None

    known = "\n".join(f"- {f}" for f in known_facts[:60]) or "(nothing yet)"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {
                "role": "user",
                "content": (
                    f"Already known (do not repeat):\n{known}\n\n"
                    f"Recent conversation:\n" + "\n".join(user_lines)
                ),
            },
        ],
        "response_format": {"type": "json_object"},
        "max_tokens": 900,
        "temperature": 0,
    }

    url = base_url.rstrip("/") + "/v1/chat/completions"
    async with httpx.AsyncClient(timeout=timeout) as client:
        resp = await client.post(url, json=payload, headers={"Authorization": f"Bearer {api_key}"})
    if resp.status_code >= 400:
        logger.warning("memory extraction HTTP %s: %s", resp.status_code, resp.text[:200])
        return None

    raw = (resp.json()["choices"][0]["message"].get("content") or "").strip()
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        logger.warning("memory extraction returned non-JSON: %s", raw[:200])
        return None

    return {
        "knowledge": _clean_knowledge(parsed.get("knowledge")),
        "events": _clean_events(parsed.get("events")),
    }


def _clamp(value: Any, default: float = 0.6) -> float:
    try:
        return max(0.0, min(1.0, float(value)))
    except (TypeError, ValueError):
        return default


def _clean_knowledge(items: Any) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not isinstance(items, list):
        return out
    for item in items:
        if not isinstance(item, dict):
            continue
        fact = str(item.get("fact") or "").strip()
        category = str(item.get("category") or "").strip().lower()
        if len(fact) < 4 or len(fact) > 220 or category not in VALID_CATEGORIES:
            continue
        out.append({"category": category, "fact": fact, "importance": _clamp(item.get("importance"))})
    return out[:8]


def _clean_events(items: Any) -> list[dict[str, Any]]:
    valid_when = {"today", "tomorrow", "weekend", "next-week", "past"}
    valid_emotion = {"positive", "negative", "stressed", "low-energy"}
    out: list[dict[str, Any]] = []
    if not isinstance(items, list):
        return out
    for item in items:
        if not isinstance(item, dict):
            continue
        summary = str(item.get("summary") or "").strip()
        if len(summary) < 4 or len(summary) > 280:
            continue
        emotion = str(item.get("emotion") or "").strip().lower()
        when = str(item.get("when") or "").strip().lower()
        out.append({
            "summary": summary,
            "category": str(item.get("category") or "life-update").strip().lower(),
            "emotion": emotion if emotion in valid_emotion else None,
            "event_date": when if when in valid_when else None,
            "importance": _clamp(item.get("importance")),
        })
    return out[:6]
