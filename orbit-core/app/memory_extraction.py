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
import re
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
- NEVER record what ORBIT did. Device actions and assistant bookkeeping are not the user's
  life: "Turned off sleep mode and adjusted brightness to 50%", "Deleted a reminder",
  "Set a reminder for 5 PM", "Call with X was deleted" are all WRONG — they are ORBIT's
  command log. Record the user's own plans, feelings and events only. If a turn contains
  nothing but ORBIT operating the machine, return empty arrays.
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


# Model output is untrusted, and the "record nothing from commands" rule is one the model
# has demonstrably broken — "Turned off sleep mode and adjusted screen brightness to 50%"
# was filed as a life event. Prompting is not enforcement; this is.
_DEVICE_ACTION_RE = re.compile(
    r"\b(?:"
    r"turn(?:ed|s)?\s+(?:on|off)|switch(?:ed)?\s+(?:on|off)|"
    r"(?:set|adjust(?:ed)?|chang(?:e|ed)|lower(?:ed)?|rais(?:e|ed)|dimm?(?:ed)?|increas(?:e|ed)|"
    r"decreas(?:e|ed)|mut(?:e|ed))\s+(?:the\s+)?"
    r"(?:volume|brightness|screen|display|wi-?fi|bluetooth|focus|dark\s+mode|night\s+shift)|"
    r"open(?:ed)?\s+(?:safari|chrome|firefox|arc|spotify|finder|terminal)|"
    r"(?:wi-?fi|bluetooth|dark\s+mode|sleep\s+mode|do\s+not\s+disturb)\s+(?:is|was|were)\s+"
    r"(?:on|off|enabled|disabled)|"
    r"locked\s+the\s+screen"
    r")\b",
    re.IGNORECASE,
)

# ORBIT's own artefacts. A reminder or note is not a life event — the Reminders and Notes
# apps already hold it, and ORBIT can read them back with a tool. Duplicating them into
# memory is what lets memory drift out of sync with the truth and speak stale plans.
#
# The line is drawn on VOICE, not topic: a record ABOUT the artefact or the operation
# ("Reminder to buy tickets is set for 5 PM", "Confirmed deletion of the call") is
# bookkeeping and goes. A record of the EVENT ("Call scheduled with Kawan Thursday at
# 2 PM", "Has a meeting with a professor at 2 PM") is a real commitment and stays.
_ARTEFACT_CRUD_RE = re.compile(
    r"(?:"
    # verb ... artefact  ("set a reminder", "deleted the note")
    r"\b(?:set|setting|create[ds]?|creating|delete[ds]?|deleting|remove[ds]?|removing|add(?:ed|s|ing)?|"
    r"updat(?:e|ed|ing)|schedul(?:e|ed|ing)|complet(?:e|ed|ing)|mark(?:ed|s|ing)?|clear(?:ed|s|ing)?)\b"
    r"[^.;]{0,40}?\b(?:reminders?|alarms?|notes?)\b"
    r"|"
    # artefact ... was/is verbed  ("the reminder is set for 5 PM")
    r"\b(?:reminders?|alarms?|notes?)\b[^.;]{0,40}?\b(?:was|were|is|are|have\s+been|has\s+been)\s+"
    r"(?:set|created|deleted|removed|added|updated|scheduled|completed|cleared)\b"
    r"|"
    # the summary IS the artefact  ("Reminder to buy tickets for the movie at 5 PM")
    r"^\s*(?:a\s+|the\s+|new\s+)?(?:reminders?|alarms?|notes?)\b"
    r"|"
    # being reminded is reminder bookkeeping however it is phrased
    r"\b(?:asked\s+to\s+be\s+reminded|reminded\s+to|reminder\s+(?:for|to|about))\b"
    r"|"
    # confirming an operation is bookkeeping regardless of the object
    r"\bconfirm(?:ed|s|ing)?\s+(?:the\s+)?(?:deletion|removal|cancellation)\b"
    r"|"
    # passive deletion of a scheduled thing — the record is about the filing, not the life
    r"\b(?:call|event|meeting|appointment)\b[^.;]{0,40}?\b(?:was|were|has\s+been|have\s+been)\s+"
    r"(?:deleted|removed|cancelled|canceled)\b"
    r")",
    re.IGNORECASE,
)


def is_tool_operation(summary: str) -> bool:
    """True when a 'life event' is really ORBIT's own command log.

    The model breaks the prompt's "record nothing from commands" rule — "Turned off sleep
    mode and adjusted screen brightness to 50%" was filed as Ayush's life. Prompting is not
    enforcement; this is.
    """
    return bool(_DEVICE_ACTION_RE.search(summary) or _ARTEFACT_CRUD_RE.search(summary))


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
        if is_tool_operation(summary):
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
