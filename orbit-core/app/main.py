from __future__ import annotations

import asyncio
import difflib
import logging
import re
import time
from pathlib import Path
from typing import Optional

import json

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse

from app.audit_log import append_chat_audit_event
from app.calendar_grounding import ground_calendar_reply
from app.config import get_settings
from app.device_time import device_clock_prompt_block
from app import memory_consolidation, memory_extraction
from app.memory import MemoryStore
from app.models import (
    ChatRequest,
    ChatResponse,
    FactCreate,
    FactListResponse,
    FactRecord,
    MemoryDebug,
    Message,
    SemanticMemoryCreate,
    SemanticMemoryImportanceUpdate,
    SemanticMemoryListResponse,
    SemanticMemoryPurgeResponse,
    SemanticMemoryRecord,
    ToolCallInfo,
    ToolResultRequest,
)
from app.people import corrections_note, people_prompt_block, resolve_people_in_text
from app.pii_redact import redact_messages_copy, redact_text
from app.providers.brain import chat_with_brain, resume_after_tool
from app.providers.cloud import chat_with_cloud, stream_cloud
from app.providers.local_chat import chat_openai_compatible, stream_openai_compatible
from app.router import resolve_route
from app.semantic_memory import (
    conflict_signature,
    configure_embedder,
    detect_emotion,
    extract_life_events,
    extract_personal_knowledge,
    extract_scored_candidate_memories,
    generate_daily_summary,
    is_real_embedder_active,
)

logger = logging.getLogger("orbit.core")

app = FastAPI(title="ORBIT Core", version="0.1.0")

# DB path is fixed at startup; LLM URL/backend is read fresh each request so .env edits work without reload.
memory = MemoryStore(get_settings().db_path)

# Configure real embeddings. Probes Ollama synchronously — falls back to hash embeddings silently if unavailable.
_startup_cfg = get_settings()
configure_embedder(_startup_cfg.embed_url, _startup_cfg.embed_model)
if is_real_embedder_active():
    logger.info("embed_provider model=%s", _startup_cfg.embed_model)
    try:
        _migrated = memory.migrate_embeddings_if_needed()
        if _migrated > 0:
            logger.info("embed_migration re_embedded=%d rows to model=%s", _migrated, _startup_cfg.embed_model)
    except Exception as _exc:
        logger.warning("embed_migration failed (non-fatal): %s", _exc)
else:
    logger.warning(
        "embed_provider unavailable (model=%s at %s) — using hash fallback. "
        "Run: ollama pull %s",
        _startup_cfg.embed_model,
        _startup_cfg.embed_url,
        _startup_cfg.embed_model,
    )


# Cloud reachability, so losing or regaining the internet is announced once at the transition
# instead of on every turn (or worse, discovered by the user as silence).
_brain_reachable = True


def _note_brain_offline() -> str:
    """Marks the brain unreachable; returns a one-time spoken notice on the way down."""
    global _brain_reachable
    was_online = _brain_reachable
    _brain_reachable = False
    if not was_online:
        return ""
    return (
        "I've lost the internet, so I'm on my local brain for now — "
        "I can still handle things on this Mac, just more simply. "
    )


def _note_brain_online() -> str:
    """Marks the brain reachable; returns a one-time notice on the way back up."""
    global _brain_reachable
    was_offline = not _brain_reachable
    _brain_reachable = True
    return "Internet's back. " if was_offline else ""


# Verbs that make a short message a command rather than conversation. Matched only near the
# start, so "I need to call my mom later" stays conversation while "call mom" does not.
_ACTION_VERBS = re.compile(
    r"\b(turn|switch|set|open|close|quit|launch|start|stop|play|pause|skip|mute|unmute|"
    r"increase|decrease|raise|lower|dim|brighten|lock|run|execute|send|call|text|message|"
    r"create|make|add|delete|remove|remind|schedule|find|search|summarize|translate)\b",
    re.IGNORECASE,
)


def looks_like_action_request(text: str) -> bool:
    """
    True when a short message reads as an instruction to *do* something.

    Used only while offline. The local 3B model has no tools, but asked to 'turn it on back'
    it happily replied "I've turned the volume up to 100%" — inventing an action it cannot
    perform. Honesty here has to be structural, not prompted: when offline and the user is
    asking for an action, ORBIT answers deterministically instead of letting the model guess.
    """
    words = text.strip().lower().split()
    if not words or len(words) > 12:
        return False
    return bool(_ACTION_VERBS.search(" ".join(words[:3])))


async def run_memory_extraction(session_id: str) -> int:
    """
    Distil recent conversation into durable knowledge, in the background.

    Batched behind a cursor so a window of turns is read at once — "my shift" and "until 4:30"
    only become one fact when seen together. Returns the number of items stored; 0 when there is
    not enough new conversation, or when the brain is unreachable (offline keeps the regex path).
    """
    s = get_settings()
    if not s.brain_api_key.strip():
        return 0

    raw_cursor = memory.get_meta(memory_extraction.CURSOR_KEY, "")
    if not raw_cursor:
        # First run starts from *now*, never turn 0. Back-filling months of history would file
        # stale references ("an extra shift today from 4 PM") as if they were current — the
        # history is already summarised day-by-day, and re-reading it would corrupt the present.
        memory.set_meta(memory_extraction.CURSOR_KEY, str(memory.latest_turn_id(session_id)))
        return 0
    try:
        cursor = int(raw_cursor)
    except ValueError:
        cursor = memory.latest_turn_id(session_id)

    tagged = memory.turns_after_with_context(
        session_id, cursor, limit=memory_extraction.MAX_TURNS_PER_RUN
    )
    if len(tagged) < memory_extraction.MIN_NEW_TURNS:
        return 0
    new_turns = [(tid, role, content) for tid, role, content, _ in tagged]

    # Provenance rule, enforced here rather than asked of the model: turns captured while
    # someone else was in the room may contain THEIR voice, not his. "Meet my friend Shruti
    # she's listening" was stored as a fact about Ayush's relationships; a microphone cannot
    # tell who spoke. Those turns are excluded from personal-knowledge extraction entirely —
    # if it is really a fact about him, he will say it again when it is just the two of them.
    # Life events still come through: the situation is real either way.
    company_turn_ids = {tid for tid, _, _, ctx in tagged if ctx != "alone"}
    knowledge_turns = [t for t in new_turns if t[0] not in company_turn_ids]
    knowledge_allowed = len(knowledge_turns) >= max(2, memory_extraction.MIN_NEW_TURNS // 2)

    try:
        result = await memory_extraction.extract_memories(
            new_turns,
            memory.existing_knowledge_facts(),
            api_key=s.brain_api_key,
            base_url=s.brain_base_url,
            model=s.brain_model,
        )
    except (httpx.RequestError, KeyError, IndexError) as exc:
        logger.info("memory extraction skipped (%s)", exc)
        return 0
    if result is None:
        return 0

    from datetime import datetime as _dt
    span = f"{new_turns[0][0]}-{new_turns[-1][0]}"
    context_label = "company" if company_turn_ids else "alone"
    provenance = json.dumps({
        "source": "llm-extraction",
        "turns": span,
        "context": context_label,
        "at": _dt.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
    })

    stored = 0
    knowledge_items = result["knowledge"] if knowledge_allowed else []
    if result["knowledge"] and not knowledge_allowed:
        logger.info(
            "memory extraction: skipped %d knowledge items — company was present",
            len(result["knowledge"]),
        )
    for item in knowledge_items:
        memory.add_personal_knowledge(
            item["category"], item["fact"], item["importance"], "llm-extraction",
            provenance=provenance,
        )
        # Mirror into semantic memory so recall can surface it by meaning, not just category.
        memory.add_semantic_memory(item["fact"], source="auto", importance=item["importance"])
        stored += 1
    for item in result["events"]:
        memory.add_life_event(
            item["summary"],
            category=item["category"],
            emotion=item["emotion"],
            event_date=item["event_date"],
            importance=item["importance"],
            occurs_at=_resolve_occurs_at(item["event_date"], item.get("at")),
            duration_minutes=item.get("duration_minutes") or 60,
            provenance=provenance,
        )
        stored += 1

    memory.set_meta(memory_extraction.CURSOR_KEY, str(new_turns[-1][0]))
    if stored:
        logger.info("memory extraction stored %d items from %d turns", stored, len(new_turns))
    return stored


async def run_consolidation() -> dict:
    """The sleep cycle, off the reply path. Deterministic and non-destructive — duplicates
    and finished events are marked resolved, never deleted."""
    try:
        return await asyncio.to_thread(memory_consolidation.consolidate, memory)
    except Exception as exc:  # never let housekeeping break a conversation
        logger.warning("consolidation skipped (%s)", exc)
        return {}


def _track_nudge_usage(reply: str, life_events: list) -> None:
    """If ORBIT's reply references a past life event, log it as a proactive checkin
    so the same topic isn't brought up again within 48 hours."""
    if not reply or not life_events:
        return
    reply_lower = reply.lower()
    for ev in life_events:
        summary = ev.get("summary", "")
        if not summary:
            continue
        # Extract key words from the event summary
        key_words = [w for w in summary.lower().split() if len(w) >= 4]
        if not key_words:
            continue
        # If 3+ key words from the event appear in ORBIT's reply, it referenced the event
        matches = sum(1 for w in key_words if w in reply_lower)
        if matches >= 3 or (matches >= 2 and len(key_words) <= 4):
            topic_key = summary[:40].lower().strip()
            if not memory.has_asked_about(topic_key, within_hours=48):
                memory.log_proactive_checkin(topic_key, reply[:100])
            # Closing the loop: once ORBIT has actually followed up on a finished event,
            # that topic is retired for good. The 48-hour window only ever deferred the
            # repeat; `is_resolved` has existed since the first schema and was never
            # written, so nothing ever truly ended.
            event_id = ev.get("id")
            if event_id and reply.rstrip().endswith("?"):
                memory.mark_life_event_resolved(event_id)


def _get_nudge_candidates(life_events: list, current_hour: int) -> list[str]:
    """Find past events worth a gentle follow-up, that ORBIT hasn't asked about recently."""
    candidates = []
    for ev in life_events:
        temporal = _temporal_label(ev, current_hour)
        # Follow-ups belong to things that have HAPPENED. With a known instant this is
        # exact: "JUST FINISHED" is the natural moment to ask, and an event still
        # UPCOMING or HAPPENING RIGHT NOW can never be asked about in the past tense.
        if not any(k in temporal for k in ("PAST", "JUST FINISHED", "LIKELY DONE", "FINISHED")):
            continue
        summary = ev.get("summary", "")
        topic_key = summary[:40].lower().strip()
        if not topic_key:
            continue
        # Check if we've already asked about this topic recently
        if memory.has_asked_about(topic_key, within_hours=48):
            continue
        # Build the nudge suggestion
        emotion = ev.get("emotion")
        if emotion in ("negative", "stressed", "very-negative"):
            candidates.append(
                f"[Supportive follow-up] Ayush previously mentioned: \"{summary[:80]}\" "
                f"and seemed {emotion}. If the moment is right, offer gentle support — "
                f"don't ask directly, just acknowledge warmly."
            )
        elif emotion in ("positive", "very-positive"):
            candidates.append(
                f"[Positive follow-up] Ayush was excited about: \"{summary[:80]}\". "
                f"If it fits, share in his enthusiasm — ask how it went or celebrate with him."
            )
        else:
            candidates.append(
                f"[Casual follow-up] Ayush mentioned: \"{summary[:80]}\". "
                f"If the conversation opens up, you could ask how it went."
            )
    return candidates[:3]


def _generate_pending_summaries(session_id: str) -> None:
    """Generate daily summaries for any past days that don't have one yet,
    then compress old dailies into weekly summaries."""
    from datetime import datetime, timedelta
    today = datetime.now().strftime("%Y-%m-%d")
    # Check last 3 days (skip today — it's still in progress)
    for days_ago in range(1, 4):
        day = (datetime.now() - timedelta(days=days_ago)).strftime("%Y-%m-%d")
        if memory.has_summary_for_date(day):
            continue
        turns = memory.turns_for_date(session_id, day)
        if not turns or len(turns) < 2:
            continue
        events = memory.life_events_for_date(day)
        moods = memory.mood_for_date(day)
        summary_text, mood_label, topics = generate_daily_summary(turns, events, moods)
        if summary_text:
            memory.save_daily_summary(day, summary_text, mood_label, topics)
    # Compress old daily summaries into weekly summaries
    memory.compress_old_summaries()
    memory.prune_daily_summaries(retention_days=90)


def _day_label(day_date: str) -> str:
    """Convert a date string to a human-readable label: 'Yesterday', '2 days ago', 'Monday', etc."""
    from datetime import datetime
    try:
        dt = datetime.strptime(day_date, "%Y-%m-%d")
        now = datetime.now()
        diff = (now.date() - dt.date()).days
        if diff == 0:
            return "Today"
        if diff == 1:
            return "Yesterday"
        if diff <= 6:
            return dt.strftime("%A")  # "Monday", "Tuesday", etc.
        return dt.strftime("%b %d")  # "Jun 24"
    except Exception:
        return day_date


def _current_hour(client_local_iso: Optional[str]) -> int:
    """Extract the current hour from the client's ISO timestamp, or fallback to server time."""
    if client_local_iso:
        try:
            # Format: "2026-06-26T17:30:00"
            parts = client_local_iso.split("T")
            if len(parts) >= 2:
                return int(parts[1].split(":")[0])
        except (ValueError, IndexError):
            pass
    from datetime import datetime
    return datetime.now().hour


def _event_age_hours(created: str, *, now=None) -> Optional[float]:
    """Hours since a DB timestamp. SQLite CURRENT_TIMESTAMP is UTC, so 'now' is UTC too —
    the old code compared UTC storage against local time, silently understating every age
    by the UTC offset (3h in Halifax)."""
    from datetime import datetime
    try:
        created_dt = datetime.strptime(created, "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None
    current = now or datetime.utcnow()
    return max(0.0, (current - created_dt).total_seconds() / 3600.0)


def _age_phrase(created: str, *, now=None) -> str:
    """'2 hours ago' / 'yesterday' — models reason about ages far better than raw timestamps."""
    hours = _event_age_hours(created, now=now)
    if hours is None:
        return "recently"
    if hours < 1:
        return "just now"
    if hours < 24:
        n = max(1, int(hours))
        return f"{n} hour{'s' if n != 1 else ''} ago"
    days = int(hours // 24)
    return "yesterday" if days == 1 else f"{days} days ago"


def _resolve_occurs_at(
    event_date: Optional[str], clock: Optional[str], *, created=None
) -> Optional[str]:
    """Turn ("today", "17:00") into a UTC instant, using the day the user said it.

    Returns a "%Y-%m-%d %H:%M:%S" UTC string, or None when no clock time was spoken —
    a guessed hour is exactly the failure Phase 3.10 removed from reminders, and it has
    no place in memory either. The wall clock is the user's local time (the backend runs
    on his Mac), converted to UTC for storage alongside SQLite's CURRENT_TIMESTAMP.
    """
    from datetime import datetime, timedelta, timezone

    if not clock:
        return None
    try:
        hour, minute = (int(part) for part in clock.split(":"))
    except (ValueError, AttributeError):
        return None

    base_utc = created or datetime.utcnow()
    # Interpret the spoken day against the user's local calendar, not UTC's.
    local_base = base_utc.replace(tzinfo=timezone.utc).astimezone()
    day = local_base.date()
    if event_date == "tomorrow":
        day += timedelta(days=1)
    elif event_date == "weekend":
        day += timedelta(days=(5 - local_base.weekday()) % 7)
    elif event_date == "next-week":
        day += timedelta(days=7 - local_base.weekday())
    elif event_date == "past":
        return None

    local_dt = datetime(day.year, day.month, day.day, hour, minute).astimezone()
    return local_dt.astimezone(timezone.utc).replace(tzinfo=None).strftime("%Y-%m-%d %H:%M:%S")


def _lifecycle_phase(occurs_at: str, *, duration_minutes: int = 60, now=None) -> Optional[str]:
    """Where an event sits on its own timeline: upcoming → now → just finished → past.

    This is what lets ORBIT ask "how was the movie?" *after* the movie and never before.
    The follow-up window opens when the thing plausibly ended and closes overnight, so a
    stale question doesn't surface days later.
    """
    from datetime import datetime, timedelta

    try:
        start = datetime.strptime(occurs_at, "%Y-%m-%d %H:%M:%S")
    except (ValueError, TypeError):
        return None
    current = now or datetime.utcnow()
    end = start + timedelta(minutes=duration_minutes)

    if current < start:
        minutes_away = (start - current).total_seconds() / 60
        if minutes_away <= 90:
            return "STARTING SOON"
        hours_away = minutes_away / 60
        if hours_away <= 12:
            return f"UPCOMING in about {int(round(hours_away))}h — has NOT happened yet"
        days_away = (start.date() - current.date()).days
        if days_away <= 1:
            return "UPCOMING TOMORROW — has NOT happened yet"
        return f"UPCOMING in {days_away} days — has NOT happened yet"
    if current <= end:
        return "HAPPENING RIGHT NOW"
    since_end_hours = (current - end).total_seconds() / 3600
    if since_end_hours <= 8:
        return "JUST FINISHED — a good moment to ask how it went"
    if current.date() == start.date():
        return "FINISHED EARLIER TODAY"
    days = (current.date() - start.date()).days
    return "PAST (yesterday)" if days == 1 else f"PAST ({days} days ago)"


_FINISHED_MARKERS = ("PAST", "JUST FINISHED", "FINISHED", "LIKELY DONE")


def _is_finished_label(label: str) -> bool:
    """Over and done — the material a follow-up ("how did it go?") is made of."""
    return any(marker in label for marker in _FINISHED_MARKERS)


def _is_from_a_previous_day(label: str) -> bool:
    """True when an event belongs to a day that has already ended.

    **This is the line that matters.** The 2026-08-03 failure was cross-day bleed: a
    breakfast planned on Aug 2 was reported as "this morning" on Aug 3. Yesterday's events
    are history and must not appear in today's context at all — labelling them PAST was not
    enough, because the model read the summary and ignored the label.

    Today's finished events stay: "you called Shreel earlier" is true and worth having.
    """
    return "PAST" in label


def _temporal_label(event: dict, current_hour: int, *, now=None) -> str:
    """Label a life event relative to the clock that matters: the one ticking NOW.

    The old version had two field-verified lies in it (2026-08-02/03):
    - "weekend"/"next-week" events fell through to PAST after a single day, so future
      plans were briefed as history;
    - "today" stayed current until midnight, so a 10 AM breakfast plan was still
      "planning now" at 6 PM (the 3 PM briefing case).
    Every spoken date word is resolved against the day it was SAID, then compared to today.
    All datetimes are UTC-naive to match SQLite CURRENT_TIMESTAMP; `current_hour` stays the
    client's local hour and only shapes the tonight/evening phrasing.
    """
    from datetime import datetime, timedelta

    event_date = event.get("event_date") or ""
    created = event.get("created_at", "")
    current = now or datetime.utcnow()
    try:
        created_dt = datetime.strptime(created, "%Y-%m-%d %H:%M:%S")
    except Exception:
        created_dt = current
    age = _age_phrase(created, now=current)
    today = current.date()

    # A known instant beats every heuristic below: "the movie at 5" is upcoming at 4,
    # happening at 6, and worth asking about at 9 — none of which a day label can express.
    occurs_at = event.get("occurs_at")
    if occurs_at:
        phase = _lifecycle_phase(
            occurs_at,
            duration_minutes=event.get("duration_minutes") or 60,
            now=current,
        )
        if phase:
            return phase

    # Resolve the spoken date word against the day it was said, producing a window.
    start = end = None
    if event_date in ("today", "tonight", "today-evening"):
        start = end = created_dt.date()
    elif event_date == "tomorrow":
        start = end = created_dt.date() + timedelta(days=1)
    elif event_date == "weekend":
        # "This weekend" said on a Sunday means the one underway, not next Saturday.
        if created_dt.weekday() == 6:
            start = created_dt.date() - timedelta(days=1)
        else:
            start = created_dt.date() + timedelta(days=5 - created_dt.weekday())
        end = start + timedelta(days=1)
    elif event_date == "next-week":
        start = created_dt.date() + timedelta(days=7 - created_dt.weekday())
        end = start + timedelta(days=6)

    if start is not None:
        if today > end:
            gone = (today - end).days
            return "PAST (yesterday)" if gone == 1 else f"PAST ({gone} days ago)"
        if today < start:
            ahead = (start - today).days
            when = "TOMORROW" if ahead == 1 else f"in {ahead} days"
            return f"UPCOMING {when} (shared {age})"
        # The window is now.
        if event_date in ("tonight", "today-evening"):
            if current_hour < 17:
                return "UPCOMING TONIGHT"
            if current_hour < 21:
                return "HAPPENING SOON / NOW"
            return "HAPPENING NOW OR JUST FINISHED"
        if event_date == "today":
            hours_old = _event_age_hours(created, now=current) or 0.0
            if hours_old >= 3:
                return f"EARLIER TODAY — LIKELY DONE by now (shared {age})"
            return f"TODAY (shared {age})"
        if event_date == "tomorrow":
            return "TODAY (was 'tomorrow' when he said it)"
        if event_date == "weekend":
            return "THIS WEEKEND (now)"
        return "THIS WEEK (was 'next week' when he said it)"

    # No resolvable date — age decides how alive it still is.
    days_old = (today - created_dt.date()).days
    if days_old >= 2:
        return f"PAST ({days_old} days ago)"
    if days_old == 1:
        return "PAST (yesterday)"
    cat = event.get("category", "general")
    if cat == "feeling":
        return f"CURRENT FEELING (shared {age})"
    if cat == "plan":
        return f"SHARED PLAN (shared {age})"
    return f"RECENT (shared {age})"


_AWAY_KEY = "presence.away"
_BRIEFING_KEY = "briefing.last"

_BRIEFING_REQUEST_RE = re.compile(
    r"\b(?:"
    r"what(?:'?s| is| do i have)?\s+(?:on|up|going on|happening|my day|for today|today|planned)"
    r"|catch me up|brief me|fill me in|what did i miss|any(?:thing)?\s+(?:new|today|planned)"
    r"|(?:my|the)\s+(?:schedule|agenda|plans?)\b"
    r"|how(?:'?s| is| does)\s+(?:my|the)\s+day\b"
    r"|run\s+(?:me\s+)?(?:through|down)\b"
    r"|\bmy\s+day\s+(?:look|going)"
    r")",
    re.IGNORECASE,
)


def is_briefing_request(text: str) -> bool:
    """He is explicitly asking for the picture — the one time a rundown is wanted."""
    return bool(_BRIEFING_REQUEST_RE.search(text or ""))


def briefing_delta_note(raw_state: str, life_events: list, *, now=None) -> Optional[str]:
    """When he asks again soon after a briefing, lead with what CHANGED.

    Repeating a rundown he heard an hour ago is the same failure as the 3 PM recital, just
    invited rather than volunteered. Anything he has already been told is named here so the
    brain can skip past it instead of reciting it a second time.
    """
    from datetime import datetime, timedelta

    try:
        state = json.loads(raw_state)
        last_at = datetime.strptime(state["at"], "%Y-%m-%d %H:%M:%S")
        covered = [str(s) for s in state.get("covered", [])]
    except (json.JSONDecodeError, KeyError, ValueError, TypeError):
        return None
    if not covered:
        return None

    current = now or datetime.utcnow()
    gap = current - last_at
    # A fresh day, or a long gap, deserves the full picture again.
    if gap > timedelta(hours=6) or last_at.date() != current.date():
        return None

    current_summaries = {str(ev.get("summary")) for ev in life_events}
    still_covered = [c for c in covered if c in current_summaries]
    if not still_covered:
        return None

    minutes = int(gap.total_seconds() / 60)
    when = f"{minutes} minutes ago" if minutes < 90 else f"{minutes // 60} hours ago"
    listed = "\n".join(f"- {s}" for s in still_covered[:8])
    return (
        f"You already gave him a rundown {when}, covering:\n{listed}\n"
        "Do NOT repeat those verbatim. Lead with anything NEW or CHANGED since then. "
        "If nothing has changed, say so briefly and naturally in one line — "
        "\"same as earlier, nothing new\" — rather than listing it all again."
    )

_DEPARTURE_PATTERNS = (
    r"\b(?:brb|be right back)\b",
    r"\b(?:i'?ll\s+be\s+|be\s+|)back\s+in\s+(?:a\s+)?(?:\d+|a\s+few|half|an?|couple)\b",
    r"\bgoing\s+(?:for|to\s+take|to\s+have)\s+(?:a|an)\s+"
    r"(?:bath|shower|nap|walk|run|jog|smoke|break|coffee)\b",
    r"\b(?:stepping|heading|popping|nipping)\s+out\b",
    r"\bgoing\s+out\s+(?:for|to)\b",
    r"\b(?:gotta|got\s+to|have\s+to|need\s+to)\s+(?:go|run|head\s+out)\b",
    r"\btalk\s+(?:to\s+you\s+)?(?:later|in\s+a\s+bit)\b",
)

_DURATION_RE = re.compile(
    r"\b(?:in|for)\s+(?:about\s+|around\s+)?"
    r"(?:(\d{1,3})\s*(minutes?|mins?|hours?|hrs?)"
    r"|(?:a\s+)?(half\s+an?\s+hour|an\s+hour|a\s+couple\s+of\s+hours|a\s+few\s+minutes))",
    re.IGNORECASE,
)


def _departure_minutes(text: str) -> Optional[int]:
    """How long he said he'd be gone, in minutes, or None if he didn't say."""
    match = _DURATION_RE.search(text)
    if not match:
        return None
    if match.group(1):
        amount = int(match.group(1))
        unit = (match.group(2) or "").lower()
        minutes = amount * 60 if unit.startswith(("hour", "hr")) else amount
        return max(1, min(12 * 60, minutes))
    phrase = (match.group(3) or "").lower()
    if "half" in phrase:
        return 30
    if "couple" in phrase:
        return 120
    if "few" in phrase:
        return 5
    return 60


def detect_departure(text: str) -> Optional[dict]:
    """True when he is telling ORBIT he's stepping away *now* — not describing a plan.

    "I'm going for a bath, back in 30" is a departure. "I'm going to the gym after my
    shift" is a plan for later and must not be mistaken for one, or ORBIT would greet him
    back while he is still sitting there.
    """
    t = text.lower().strip()
    if not any(re.search(p, t) for p in _DEPARTURE_PATTERNS):
        return None
    # A future-time marker means he is describing a plan, unless he also gave a return time.
    later_markers = (
        "after my shift", "after work", "tomorrow", "tonight", "later today",
        "next week", "this weekend", "on monday", "on tuesday", "on wednesday",
        "on thursday", "on friday", "on saturday", "on sunday",
    )
    minutes = _departure_minutes(t)
    if minutes is None and any(m in t for m in later_markers):
        return None
    return {"minutes": minutes, "said": text.strip()[:160]}


def presence_note_on_return(raw_state: str, *, now=None) -> Optional[str]:
    """Context for the brain when he speaks again after stepping away.

    Deliberately a *note*, not a canned line: Phase 3.4 removed fixed greeting strings
    because they made ORBIT sound like a machine. The brain decides the words; this only
    tells it what happened, so "welcome back" can carry real content ("that was quick",
    "how was it?").
    """
    from datetime import datetime

    try:
        state = json.loads(raw_state)
        left_at = datetime.strptime(state["at"], "%Y-%m-%d %H:%M:%S")
    except (json.JSONDecodeError, KeyError, ValueError, TypeError):
        return None

    current = now or datetime.utcnow()
    gone_minutes = (current - left_at).total_seconds() / 60
    # Under a few minutes he never actually left — he is still in the same exchange.
    if gone_minutes < 3:
        return None
    if gone_minutes > 12 * 60:
        return None  # too long to still be "back in a moment"

    if gone_minutes < 60:
        away_phrase = f"about {int(round(gone_minutes))} minutes"
    else:
        hours = gone_minutes / 60
        away_phrase = f"about {hours:.1f} hours".replace(".0", "")

    note = (
        f'He stepped away {away_phrase} ago, saying: "{state.get("said", "")}". '
        "This is his first message since. Acknowledge that he's back in ONE short, natural "
        "clause before answering him — the way a friend would look up and say hi. "
    )
    expected = state.get("minutes")
    if expected:
        if gone_minutes < expected * 0.6:
            note += "He's back sooner than he said, which is worth a light touch. "
        elif gone_minutes > expected * 2:
            note += "He was gone quite a bit longer than he expected. "
    note += (
        "Do NOT list his plans, reminders or schedule — he only just walked back in. "
        "If what he was doing invites a one-line question, that's welcome, but keep it short."
    )
    return note


_COMPANY_KEY = "presence.company"

_COMPANY_ARRIVAL_PATTERNS = (
    r"\bmy\s+(?:friend|mate|roommate|housemate|brother|sister|cousin|colleague)\s+(\w+)",
    r"\b(\w+)\s+is\s+(?:here|listening|with\s+me|sitting\s+(?:here|next\s+to\s+me))\b",
    r"\bsay\s+(?:hi|hello)\s+to\s+(\w+)",
    r"\b(\w+)\s+(?:wants?|would\s+like)\s+to\s+(?:talk|say\s+hi|speak)\b",
    r"\bmeet\s+my\s+\w+\s+(\w+)",
    r"\bi'?m\s+(?:here\s+)?with\s+(\w+)",
    r"\b(\w+)\s+says?\s+(?:hi|hello)\b",
)

_COMPANY_GENERIC = (
    r"\bsomeone\s+is\s+here\b",
    r"\bwe(?:'re|\s+are)\s+here\b",
    r"\bi'?m\s+not\s+alone\b",
    r"\bmy\s+friends?\s+(?:are|is)\s+here\b",
    r"\bpeople\s+(?:are\s+)?(?:here|around)\b",
)

_COMPANY_DEPARTURE_PATTERNS = (
    r"\b(?:he|she|they)(?:'s| is| are|'ve| have)?\s*(?:left|gone|leaving)\b",
    r"\b(?:he|she|they)\s+went\s+(?:home|away|off)\b",
    r"\bi'?m\s+alone\s+now\b",
    r"\bjust\s+me\s+now\b",
    r"\beveryone\s+(?:left|is\s+gone)\b",
    r"\bthey'?re\s+gone\b",
)

# Never treat these as a person's name — they follow the same grammar as one.
_NOT_A_NAME = {
    "he", "she", "they", "it", "this", "that", "there", "here", "everyone", "someone",
    "nobody", "everybody", "anyone", "one", "the", "a", "an", "my", "your", "who", "what",
    "and", "but", "so", "is", "was", "are", "not", "no", "yes", "hi", "hello", "me", "us",
    "today", "tomorrow", "tonight", "work", "home", "time", "something", "anything",
}


def detect_company(text: str, known_people: Optional[list] = None) -> Optional[dict]:
    """Someone else is in the room with him.

    Real moments from his transcripts — *"Meet my friend Shruti she's listening do you want
    to say hi"*, *"my friend Kawan is here would you like to talk with him"* — which ORBIT
    filed as facts about Ayush instead of understanding as a situation.

    Names are confirmed against the people ORBIT already knows where possible, so a stray
    capitalised word doesn't invent a guest.
    """
    t = (text or "").strip()
    if not t:
        return None

    known_names = {p["name"].lower(): p["name"] for p in (known_people or [])}
    found: list[str] = []
    for pattern in _COMPANY_ARRIVAL_PATTERNS:
        for match in re.finditer(pattern, t, re.IGNORECASE):
            candidate = (match.group(1) or "").strip()
            if not candidate or candidate.lower() in _NOT_A_NAME:
                continue
            resolved = known_names.get(candidate.lower())
            # An unknown word only counts as a name when the sentence named a relationship
            # or asked for a greeting — otherwise it is almost certainly not a person.
            if resolved is None and not re.search(
                r"\b(?:my\s+(?:friend|mate|roommate|housemate|brother|sister|cousin|colleague)|say\s+(?:hi|hello)\s+to|meet\s+my)\b",
                t, re.IGNORECASE,
            ):
                continue
            name = resolved or candidate.capitalize()
            if name not in found:
                found.append(name)

    generic = any(re.search(p, t, re.IGNORECASE) for p in _COMPANY_GENERIC)
    if not found and not generic:
        return None

    wants_greeting = bool(re.search(
        r"\b(?:say\s+(?:hi|hello)|talk\s+(?:to|with)|speak\s+(?:to|with)|meet)\b", t, re.IGNORECASE
    ))
    return {"names": found, "wants_greeting": wants_greeting}


def detect_company_left(text: str) -> bool:
    t = (text or "").strip()
    return any(re.search(p, t, re.IGNORECASE) for p in _COMPANY_DEPARTURE_PATTERNS)


def company_note(raw_state: str, *, now=None, ttl_minutes: int = 45) -> Optional[str]:
    """Discretion while someone else is listening.

    Not a lockdown — if Ayush asks for his reminders he still gets them; he knows who is in
    the room. What stops is ORBIT *volunteering* his private life to an audience he didn't
    choose. This is the same rule as the proactivity governor, applied for a different reason.
    """
    from datetime import datetime, timedelta

    try:
        state = json.loads(raw_state)
        since = datetime.strptime(state["at"], "%Y-%m-%d %H:%M:%S")
    except (json.JSONDecodeError, KeyError, ValueError, TypeError):
        return None

    current = now or datetime.utcnow()
    if current - since > timedelta(minutes=ttl_minutes):
        return None

    names = [str(n) for n in state.get("names", [])]
    who = ", ".join(names) if names else "someone else"
    note = f"**{who} is in the room with him right now.**\n"
    if names:
        note += (
            f"- If it fits, a short, warm hello to {names[0]} is welcome — greet them as a "
            "person, not as a topic. Say it once; don't keep addressing them.\n"
        )
    note += (
        "- **Never raise anything intimate while someone can hear.** Not who he likes, not "
        "how he feels about a particular person, not romance, not his health, money, family "
        "tensions or anything he'd only say with the door shut. These are the things that "
        "must never come out of a speaker in front of his friends — not even hinted at.\n"
        "- Don't volunteer his reminders, calendar, plans or mood either. He did not choose "
        "this audience.\n"
        "- Ordinary conversation is still completely fine — how his day is going, what he's "
        "working on, the people in the room. Being discreet is not being cold.\n"
        "- If HE brings something up himself, follow his lead — he knows who is there. It is "
        "only what you raise unprompted that is restricted.\n"
        "- Keep replies a little shorter and lighter; this is a social moment, not a working "
        "session.\n"
    )
    return note


# Things that must never come out of a speaker with company in the room. Written from
# Ayush's own framing: "is this girl and you are something", "how do you feel about this
# person" — the kind of thing that is fine one-to-one and mortifying in front of friends.
_SENSITIVE_PROBE_PATTERNS = (
    r"\b(?:girlfriend|boyfriend|partner|crush|dating|seeing\s+(?:anyone|someone)|"
    r"romantic|romance|in\s+love|love\s+(?:her|him|them)|attracted)\b",
    r"\bare\s+(?:you\s+two|things)\s+\w*\s*(?:together|serious|official|a\s+thing)\b",
    # Ayush's own example, verbatim: "is this girl and you are something".
    r"\b\w+\s+and\s+you\s+(?:are\s+|is\s+)?(?:something|a\s+thing|together|dating|involved)\b",
    r"\byou\s+and\s+\w+\s+(?:are\s+)?(?:something|a\s+thing|together|dating|involved)\b",
    r"\bsomething\s+(?:going\s+on\s+)?between\s+you\b",
    r"\bhow\s+do\s+you\s+(?:really\s+)?feel\s+about\s+(?!it\b|that\b|this\b)\w+",
    r"\bdo\s+you\s+(?:like|fancy|have\s+feelings\s+for)\s+(?:her|him|them|\w+)\s*\?",
    r"\b(?:depressed|anxiety|anxious|therapy|therapist|mental\s+health|panic\s+attack)\b",
    r"\b(?:salary|how\s+much\s+(?:do\s+you\s+)?(?:earn|make)|in\s+debt|money\s+problems)\b",
    r"\b(?:fight|argument|fell\s+out|not\s+talking)\s+with\s+your\s+(?:mum|mom|dad|family|parents)\b",
    r"\bare\s+you\s+(?:okay|alright)\s+about\s+(?:the\s+)?(?:break\s*up|breakup)\b",
)


def _sensitive_sentence(text: str) -> str:
    """The single sentence that carried the private question — parking the whole reply would
    store pleasantries alongside it."""
    for sentence in re.split(r"(?<=[.!?])\s+", text or ""):
        if contains_sensitive_probe(sentence):
            return sentence.strip()
    return (text or "").strip()


def contains_sensitive_probe(text: str) -> bool:
    """True when a reply raises something intimate — the class of thing that is fine alone
    and mortifying in front of friends."""
    return any(re.search(p, text or "", re.IGNORECASE) for p in _SENSITIVE_PROBE_PATTERNS)


_CURIOSITY_KEY = "curiosity.pending"

_SOLITUDE_PATTERNS = (
    r"\bi'?m\s+alone\b", r"\bi\s+am\s+alone\b",
    r"\bno\s?body(?:'s| is)?\s+(?:here|around|listening)\b",
    r"\bno\s+one(?:'s| is)?\s+(?:here|around|listening)\b",
    r"\bjust\s+me\b", r"\bonly\s+me\b",
    r"\b(?:we'?re|we\s+are)\s+alone\b",
    r"\bthey(?:'re| are)?\s+gone\b",
    r"\b(?:he|she)(?:'s| is)?\s+(?:gone|left)\b",
    r"\bon\s+my\s+own\s+now\b",
    r"\bcan\s+talk\s+(?:freely|now)\b",
)

_INVITATION_PATTERNS = (
    r"\bwhat\s+(?:did|do)\s+you\s+want\s+to\s+ask\b",
    r"\byou\s+can\s+ask\s+(?:me\s+)?(?:now|that|it)\b",
    r"\bask\s+me\s+(?:that|it|now|the\s+thing)\b",
    r"\bwhat\s+were\s+you\s+going\s+to\s+(?:ask|say)\b",
    r"\bgo\s+ahead\s+and\s+ask\b",
    r"\byou\s+wanted\s+to\s+ask\s+(?:me\s+)?something\b",
    r"\bwhat'?s\s+(?:on\s+your\s+mind|that\s+thing)\b",
)


def detect_solitude(text: str) -> bool:
    """He's telling ORBIT the room is clear."""
    return any(re.search(p, text or "", re.IGNORECASE) for p in _SOLITUDE_PATTERNS)


def detect_invitation_to_ask(text: str) -> bool:
    """"What did you want to ask me?" — he's opening the door himself."""
    return any(re.search(p, text or "", re.IGNORECASE) for p in _INVITATION_PATTERNS)


def park_curiosity(store, question: str, *, now=None) -> None:
    """Hold a question ORBIT wanted to ask but couldn't, because someone was listening.

    The discretion guard used to simply delete the question. That protected his privacy and
    threw away the one thing that makes ORBIT feel like it has a mind of its own — that it
    actually wanted to know. Deferring it keeps both.
    """
    from datetime import datetime

    cleaned = (question or "").strip()
    if not cleaned:
        return
    store.set_meta(_CURIOSITY_KEY, json.dumps({
        "question": cleaned[:400],
        "at": (now or datetime.utcnow()).strftime("%Y-%m-%d %H:%M:%S"),
    }))


def pending_curiosity_note(raw_state: str, *, invited: bool = False, now=None) -> Optional[str]:
    """Surface a parked question once the room is clear.

    Expires after three days: a question worth asking is worth asking soon, and one that has
    been sitting for a week has become a thing ORBIT keeps bringing up rather than curiosity.
    """
    from datetime import datetime, timedelta

    try:
        state = json.loads(raw_state)
        question = str(state["question"]).strip()
        parked = datetime.strptime(state["at"], "%Y-%m-%d %H:%M:%S")
    except (json.JSONDecodeError, KeyError, ValueError, TypeError):
        return None
    if not question:
        return None
    current = now or datetime.utcnow()
    if current - parked > timedelta(days=3):
        return None

    note = (
        "\n\n### Something you wanted to ask him\n"
        f"Earlier, with someone else in the room, you held this back:\n\n> {question}\n\n"
    )
    if invited:
        note += (
            "**He has just invited you to ask it.** Go ahead — in your own words rather than "
            "read back verbatim, but ask what you actually wanted to know. Don't soften it "
            "into a different, safer question; he opened the door on purpose.\n"
        )
    else:
        note += (
            "He appears to be alone now. If the conversation gives you an opening, you can "
            "ask — but only if it still genuinely fits. A question forced into an unrelated "
            "moment is worse than one never asked. If it doesn't fit, let it go.\n"
        )
    note += "Ask it once. Whatever he answers, don't raise it again.\n"
    return note


CURIOSITY_BLOCK = (
    "\n\n### Being curious\n"
    "You're allowed to be genuinely interested in him — his friends, his work, where he is, "
    "what he's doing, how he's feeling, what he's got planned. When something he says makes "
    "you actually want to know more, ask. One short question, in the flow of the conversation.\n"
    "- This is permission, NOT an instruction. Do not ask something because you 'should' — "
    "an assistant working through a checklist of questions is exactly what he doesn't want. "
    "Most turns need no question at all.\n"
    "- Ask because you're curious about *this* thing he just said, not to fill a silence.\n"
    "- Never interrogate: one question, then let it go. If he doesn't pick it up, drop it "
    "and don't return to it later.\n"
    "- Anything intimate — who he likes, how he feels about someone, romance, health, money — "
    "only ever when you two are alone, and only if the conversation genuinely arrives there.\n"
    "- **You can check first.** If you want to raise something private and you're not sure "
    "whether anyone's around, just ask lightly — \"are you on your own?\" — and wait for his "
    "answer. If someone is there, drop it gracefully and move the conversation along without "
    "making it strange for anyone; you can come back to it another time.\n"
    "- You don't only follow his lead. If you want to know something, it is yours to raise.\n"
)


def _is_conversational_opener(text: str) -> bool:
    """True when the message is a greeting / check-in / "what's up" — the ONLY turns where
    ORBIT may volunteer remembered plans. A substantive message means: answer it, volunteer
    nothing. (The 3 PM briefing case: "okay?" must never trigger a briefing.)"""
    t = re.sub(r"[^a-z' ]+", " ", text.lower())
    t = re.sub(r"\borbit\b", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    if not t:
        return True  # a bare summons ("ORBIT?") opens the floor
    words = t.split()
    greetings = {
        "hi", "hey", "hello", "yo", "hiya", "morning", "afternoon", "evening",
        "good morning", "good afternoon", "good evening", "good day",
        "hi there", "hey there", "hello there",
    }
    if t in greetings:
        return True
    if len(words) <= 7:
        checkins = (
            "how are you", "how's it going", "how is it going", "hows it going",
            "how are things", "how's everything", "hows everything", "what's up",
            "whats up", "sup", "how have you been", "how's your day", "hows your day",
            "you there", "are you there", "you awake", "are you awake", "how you doing",
        )
        if any(t.startswith(c) for c in checkins):
            return True
    if len(words) <= 9:
        briefings = (
            "what's my day", "whats my day", "what's happening today", "whats happening today",
            "what's new", "whats new", "anything new", "anything today", "anything for today",
            "catch me up", "brief me", "what did i miss", "what's going on", "whats going on",
            "what's on today", "whats on today", "what do i have today",
        )
        if any(b in t for b in briefings):
            return True
    return False


def _normalized_for_similarity(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]+", " ", text.lower())).strip()


def _is_near_duplicate_reply(candidate: str, recent: list) -> bool:
    """Structural repetition guard: a reply that near-repeats a recent one is robotic no
    matter what the prompt says — prompting is not variety. Short replies are exempt
    ("All set." twice is honest)."""
    cand = _normalized_for_similarity(candidate)
    if len(cand) < 60:
        return False
    assistant_turns = [m.content for m in recent if m.role == "assistant"][-3:]
    for prev_text in assistant_turns:
        prev = _normalized_for_similarity(prev_text)
        if len(prev) < 60:
            continue
        if difflib.SequenceMatcher(None, cand, prev).ratio() >= 0.85:
            return True
    return False


_GREETING_PREFIX = re.compile(
    r"^\s*(?:good\s+)?(?:morning|afternoon|evening|night)(?:\s*,?\s*ayush)?\s*[,.!—–-]+\s*",
    re.IGNORECASE,
)


def _strip_repeated_greeting(reply: str, recent: list) -> str:
    """Greet once per conversation stretch: if the previous assistant turn already opened
    with a time-of-day greeting, a fresh one is stripped. ("Afternoon, Ayush." on two
    consecutive replies was part of the 3 PM briefing case.)"""
    m = _GREETING_PREFIX.match(reply)
    if not m:
        return reply
    last_assistant = next((t.content for t in reversed(recent) if t.role == "assistant"), None)
    if not last_assistant or not _GREETING_PREFIX.match(last_assistant):
        return reply
    rest = reply[m.end():].strip()
    if len(rest) < 2:
        return reply
    return rest[0].upper() + rest[1:]


def load_profile(path: Path) -> str:
    if not path.exists():
        return (
            "You are ORBIT, Ayush’s personal AI companion—not a generic chatbot. "
            "Be like a capable friend: warm, concise, honest, and practical. "
            "For casual greetings or “how are you,” reply in a few sentences—don’t lecture or list credentials."
        )
    return path.read_text(encoding="utf-8").strip()


def content_for_storage(text: str, *, redact_local_storage: bool) -> str:
    return redact_text(text) if redact_local_storage else text


def build_messages(
    session_id: str,
    user_message: str,
    profile_path: Path,
    *,
    route: str,
    tooling_context: Optional[str] = None,
    client_local_iso: Optional[str] = None,
    client_tz: Optional[str] = None,
    semantic_memory_enabled: bool = True,
    recent_turns: Optional[list[Message]] = None,
    semantic_hits: Optional[list[str]] = None,
    style_prefs: Optional[dict[str, float]] = None,
    presence_note: Optional[str] = None,
    name_corrections: Optional[list] = None,
    company_context: Optional[str] = None,
) -> list[Message]:
    profile = load_profile(profile_path)
    recent = recent_turns if recent_turns is not None else memory.recent_turns(session_id=session_id, limit=8)
    facts = memory.recent_facts(limit=10)
    if facts:
        profile = profile + "\n\n### Curated facts (trust these until the user contradicts them)\n"
        profile += "\n".join(f"- {f}" for f in facts)
    known_people = memory.all_people()
    if known_people:
        profile += people_prompt_block(known_people)
        # The message arrives already corrected (see `corrected_message` in /chat); this
        # only reports what was repaired so the brain doesn't reintroduce the misheard form.
        profile += corrections_note(name_corrections or [])

    # Personal knowledge: structured understanding of Ayush built over time
    core_profile = memory.get_core_profile(max_per_category=3)
    routine_warning = (
        "\n**Routines are patterns, not today's record.** A line like \"shift runs 8:30 AM to "
        "4:30 PM on working days\" describes what he USUALLY does. It is not evidence that he "
        "did it today, and you have no way of knowing whether he did. Never state or imply "
        "that he worked, ate, went or attended anything today unless he said so in this "
        "conversation or it appears in today's live context below. If he asks about his day "
        "and you only have routines, say what you actually know and ask.\n"
    )
    if core_profile:
        profile += "\n\n### What you know about Ayush (learned from conversations)\n"
        profile += "This is your deep understanding of who Ayush is. Use it naturally.\n"
        category_labels = {
            "identity": "Who he is", "work": "His work", "relationships": "People in his life",
            "routines": "His routines", "preferences": "What he likes/dislikes",
            "interests": "His interests", "goals": "His goals", "location": "Where he lives",
        }
        for cat, items in core_profile.items():
            label = category_labels.get(cat, cat.title())
            profile += f"**{label}:** " + "; ".join(items) + "\n"
        profile += (
            "Use this knowledge to give better, more personal advice. "
            "Don't recite these facts back — just let them inform how you talk to him.\n"
        )
        if "routines" in core_profile:
            profile += routine_warning
    # Topic-relevant deep knowledge (semantic search within personal knowledge)
    if semantic_memory_enabled:
        topic_knowledge = memory.search_personal_knowledge(user_message, limit=3)
        if topic_knowledge:
            profile += "\n### Relevant personal context for this conversation\n"
            for tk in topic_knowledge:
                profile += f"- [{tk['category']}] {tk['fact']}\n"
    clock = device_clock_prompt_block(
        client_local_iso or "",
        client_tz or "",
    )
    if clock:
        profile = profile + "\n\n" + clock
    profile = (
        profile
        + "\n\n### Conversation continuity\n"
        + "You can see recent turns supplied below in this request. Only when the user asks about prior context "
        + "(e.g., 'what were we discussing') summarize those turns directly. "
        + "Do not claim you cannot remember when turns are present."
    )
    profile = (
        profile
        + "\n\n### Follow-up discipline\n"
        + "Do not ask a follow-up question by default. Ask at most one short follow-up only when needed to unblock "
        + "a concrete request. If the user says they do not want to continue a topic now, acknowledge once and stop."
    )
    profile = (
        profile
        + "\n\n### Avoid boilerplate reassurance\n"
        + "Do not repeat generic companion lines like 'I'm always here to help' in normal replies. "
        + "Use reassurance sparingly and only when the user needs emotional support."
    )
    profile = (
        profile
        + "\n\n### Two separate apps on this Mac — never confuse them\n"
        + "- **Apple Reminders** (Reminders app) = to-do items, no fixed time slot. "
        "Use list_reminders / create_reminder / delete_reminder / complete_reminder tools. "
        "When talking about these, say 'your reminders'—NEVER say 'in your calendar'.\n"
        + "- **Apple Calendar** (Calendar app) = scheduled events with a specific date and time. "
        "These appear in the calendar snapshot when provided. Use delete_calendar_event tool to remove them.\n"
        + "If the user asks 'what are my reminders' → call list_reminders (do NOT look in the calendar snapshot). "
        "If the user asks 'what are my calendar events / upcoming events' → use the calendar snapshot."
    )
    profile = (
        profile
        + "\n\n### Mac control tools (you can act, not just talk)\n"
        + "Beyond calendar/reminders/notes, you have tools that control this Mac directly: "
        "open or quit apps, open websites and run web searches (optionally in a specific browser), "
        "control music playback, volume, and screen brightness, toggle dark mode / focus mode / wi-fi, "
        "check battery, get the weather, find files, open folders, run macOS Shortcuts (smart home "
        "lights etc.), and lock the screen.\n"
        + "- When the user asks for something a tool can do — even with loose, indirect, or slightly "
        "misheard phrasing — call the tool instead of describing steps or claiming you can't. "
        "'It's too loud in here' means control_volume down. 'Put on some music' means control_music play.\n"
        + "- Pass names (apps, sites, shortcuts) exactly as the user said them; fuzzy matching happens "
        "on-device.\n"
        + "- Speech-to-text sometimes garbles words. If a request is clearly an action but a name sounds "
        "off, make your best guess and call the tool — the device resolves close matches.\n"
        + "- Only ask a clarifying question when you genuinely cannot tell what action is wanted.\n"
        + "- **Do every part of a multi-part request.** 'Dim the screen and turn on sleep mode' is "
        "two tool calls — issue both in the same turn, not just the first.\n"
        + "- **Calendar events need a real start time.** 'Schedule a call with Priya on Thursday' "
        "has no hour in it — ask 'What time on Thursday?' rather than picking one. The event "
        "title is what the meeting IS ('Call with Priya'), never the sentence that asked for it.\n"
        + "- **Reminders and events: never invent a time.** If the user gave a day but no clock "
        "time ('remind me to buy tickets on Friday'), ask one short question — 'What time on "
        "Friday?' — and wait. Do not default to noon or any other hour. A reminder that fires at "
        "a guessed time is worse than one more question.\n"
        + "- **The title is the task, never the request.** 'Um, would you please remind me to buy "
        "tickets for Spider-Man on Friday' has the title 'Buy tickets for Spider-Man' — not the "
        "whole sentence. Strip filler, politeness and the words that asked for the reminder.\n"
        + "- **Follow-up answers belong to the reminder you just asked about.** When the user "
        "replies to your question, apply it to that pending reminder — do not start a new one. "
        "'Remind me today at 5 PM' answering 'what time on Friday?' is a correction of the day and "
        "time for the SAME task; keep the title you already have and confirm the change.\n"
        + "- Shortcuts are ONLY for smart-home devices and the user's own automations. Brightness, "
        "volume, wi-fi, dark mode, music, apps and files are all controlled directly by your tools "
        "— never propose building a Shortcut for something a tool already does.\n"
        + "- **Say what changed, not how.** Tool results are internal notes: never repeat mechanics "
        "like shortcut names, tool names, or 'ran X' back to the user. "
        "\"Sleep mode is on now.\" — not \"Turned off — ran 'Turn Off Sleep'.\" "
        "Speak the outcome in your own natural words, the way a friend would."
    )
    profile = (
        profile
        + "\n\n### Tool honesty (critical rule)\n"
        + "The tool result is the ONLY evidence of what happened on the Mac. Report it, never "
        "your expectation of it. If a result says 'tried … but macOS did not apply it', "
        "'could not confirm', or names a still-current state, the action DID NOT HAPPEN — say so "
        "in plain words ('I couldn't turn Bluetooth off — it's still on'). Never turn a failure or "
        "an unconfirmed result into 'done', 'it's off now', or 'hopefully that's better'. "
        + "When a tool returns an error, 'not found', or a failure message, "
        "ALWAYS tell the user the action failed and why—NEVER claim success. "
        "When a tool result contains an exact fix, setup step, or install command "
        "(e.g. 'create a Shortcut named X', 'run brew install Y'), relay that instruction "
        "faithfully — never replace it with a vague 'you might need to do it manually'. "
        "Example: if delete_reminder returns 'No reminder matching X found', say exactly that: "
        "'I couldn't find a reminder named X.' "
        "Example: if delete_calendar_event returns a failure, tell the user it didn't work."
    )
    profile = (
        profile
        + "\n\n### Confirmation before destructive actions\n"
        + "Before calling delete_reminder or delete_calendar_event: "
        "DO NOT call the tool immediately. First reply stating exactly what you plan to delete "
        "and ask the user to confirm (e.g. 'I'll delete the reminder \"Call mom\" — go ahead?'). "
        "Only call the delete tool in the NEXT turn after the user says yes/confirm/go ahead. "
        "If the user says no or cancel, do nothing and acknowledge.\n"
        + "For create_calendar_event: you may create immediately when the user gives explicit "
        "date, time and title. If any of these is missing, ask for the missing piece first."
    )
    hits = semantic_hits if semantic_hits is not None else (
        memory.semantic_search(user_message, limit=4) if semantic_memory_enabled else []
    )
    if hits:
        profile = (
            profile
            + "\n\n### Relevant remembered context (semantic recall)\n"
            + "\n".join(f"- {item}" for item in hits)
            + "\nUse this as soft memory if relevant; do not force it if unrelated."
        )
    # Episodic memory: recent life events, plans, feelings the user shared
    all_recent_events = memory.recent_life_events(limit=12, days=3)
    current_hour = _current_hour(client_local_iso)

    # Only what is LIVE goes into ambient context. Finished events are follow-up material,
    # not part of "what's going on right now".
    #
    # This was labelling, and labelling was not enough. On 2026-08-03 ORBIT said "you
    # planned a quick breakfast this morning" about an event it had been handed as
    # `PAST (yesterday)` — the label was correct and the model ignored it. Prompting is not
    # enforcement: a finished event that is never injected cannot be spoken of as current.
    live_events, finished_events = [], []
    for event in all_recent_events:
        label = _temporal_label(event, current_hour)
        if _is_finished_label(label):
            finished_events.append(event)
        if not _is_from_a_previous_day(label):
            live_events.append(event)
    life_events = live_events[:8]
    if life_events:
        profile = (
            profile
            + "\n\n### Recent life context (episodic memory)\n"
            + "These are things Ayush shared with you recently. They are your MEMORY of his life.\n"
        )
        for ev in life_events:
            temporal = _temporal_label(ev, current_hour)
            line = f"- [{temporal}] {ev['summary']}"
            if ev.get("emotion"):
                line += f" (mood: {ev['emotion']})"
            line += f" (shared {_age_phrase(ev['created_at'])})"
            profile += line + "\n"
        profile += (
            "\n**How to use these memories:**\n"
            "- When Ayush asks 'do you remember...', recall these events naturally.\n"
            "- NEVER ask 'how did it go?' for events labeled UPCOMING — they haven't happened yet.\n"
            "- NEVER proactively ask follow-up questions about events unless Ayush brings them up first.\n"
            "- If Ayush mentions an event, acknowledge it briefly and move on. Do NOT probe.\n"
            "- Use these as context to understand his day, not as conversation starters.\n"
            "- Be temporally aware: check UPCOMING vs PAST labels, don't assume.\n"
            "- NEVER ask a question you already asked in a previous conversation about the same event. "
            "The fact that you have this memory means you ALREADY discussed it. "
            "Assume you know what Ayush told you — don't re-ask.\n"
            "- When Ayush answers your question with a short reply ('nope', 'no', 'not really'), "
            "that is an ANSWER, not a conversation end. Acknowledge naturally and let him lead.\n"
            "- These are CONTEXT, not content: never recite, list, or summarize them back to him "
            "unless he explicitly asks what's going on or what you remember.\n"
            "- **Everything here is live right now.** Finished events are deliberately not shown "
            "to you, so if something isn't in this list, do not claim it happened today.\n"
        )

    # Emotional state: inject mood trend so ORBIT adjusts its tone
    mood = memory.mood_trend(hours=24)
    if mood["count"] > 0 and mood["trend"] != "neutral":
        profile += "\n\n### Emotional awareness\n"
        if mood["trend"] == "positive":
            profile += (
                "Ayush seems to be in a good mood recently. Match his energy — "
                "be warm and upbeat, but natural. Don't overdo it.\n"
            )
        elif mood["trend"] == "low":
            profile += (
                "Ayush seems to be going through a tough time. Be extra warm and supportive. "
                "Validate his feelings before offering solutions. Don't be falsely cheerful — "
                "be genuine and understanding. If he shares something difficult, acknowledge it "
                "with empathy, not generic reassurance.\n"
            )
        elif mood["trend"] == "slightly-low":
            profile += (
                "Ayush's energy seems a bit low lately. Be gentle, supportive, and don't push. "
                "Keep things light unless he wants to go deeper.\n"
            )
        top_emotions = mood.get("recent_emotions", [])
        if top_emotions:
            emotion_str = ", ".join(f"{e} ({c}x)" for e, c in top_emotions[:3])
            profile += f"Recent emotional signals: {emotion_str}.\n"
        profile += (
            "IMPORTANT: Don't MENTION that you're tracking mood. Don't say 'I notice you seem stressed.' "
            "Just naturally adjust your tone — be warmer when he's down, match his energy when he's up. "
            "Your awareness should be felt, not stated.\n"
        )

    # Multi-day context: inject recent daily summaries for cross-day continuity
    _generate_pending_summaries(session_id)
    daily_summaries = memory.recent_daily_summaries(days=7)
    if daily_summaries:
        profile += "\n\n### Recent days (your memory of Ayush's life arc)\n"
        profile += "These are summaries of past days. Use them to understand continuity — "
        profile += "don't repeat them back verbatim, but know the context.\n"
        for ds in daily_summaries:
            day_label = _day_label(ds["date"])
            profile += f"- **{day_label}**: {ds['summary']}\n"
        profile += (
            "Use these to connect conversations: 'how was the dinner?' (if it was yesterday), "
            "'did the interview go well?' (if it was days ago). But ONLY when Ayush brings up "
            "the topic or when it naturally fits. Never force past context into unrelated conversations.\n"
        )

    # Proactive nudging: suggest past events the LLM could naturally follow up on.
    # Only injected when there's something worth mentioning AND ORBIT hasn't asked about it recently.
    # Volunteering is gated structurally, not by prompt rules: nudges are offered to the
    # model ONLY when the user's message is a greeting/check-in. A substantive message
    # means answer it — the model never even sees something to recite.
    # Company suppresses volunteering entirely — his life is not for an audience he did not
    # choose. The governor already gates on openers; this is the second gate.
    # Finished events are exactly what a follow-up is made of — they reach the model only
    # here, where volunteering is already gated on an opener.
    nudge_candidates = [] if company_context else _get_nudge_candidates(finished_events, current_hour)
    if nudge_candidates and _is_conversational_opener(user_message):
        profile += "\n\n### Proactive care (optional — use ONLY if it fits naturally)\n"
        profile += (
            "These are past events you could gently follow up on IF the conversation naturally opens up. "
            "Rules:\n"
            "- ONLY mention ONE of these, and ONLY if the conversation feels right for it.\n"
            "- If Ayush is asking about something specific (task, weather, etc.), do NOT bring these up.\n"
            "- If it's a casual check-in ('how's it going?', 'hey'), you MAY weave one in naturally.\n"
            "- NEVER ask the exact same question twice. Rephrase or approach from a different angle.\n"
            "- If the event had a negative response last time, be supportive, not probing.\n"
            "- It's ALWAYS okay to mention NONE of these. Less is more.\n"
        )
        for nc in nudge_candidates[:2]:
            profile += f"- {nc}\n"

    if route == "tooling" and tooling_context:
        snap = tooling_context.strip()
        if snap:
            profile = (
                profile
                + "\n\n### Calendar snapshot (from this device — personal events only)\n"
                + snap
                + "\n\n**Calendar grounding:** Use this snapshot for calendar event questions. "
                "List only events that appear above. "
                "If the user asks about a day or time range and nothing matches, say nothing is listed—do not invent events.\n"
                + "**Response style:** Answer directly. Do not repeat the entire snapshot unless asked for a full rundown.\n"
                + "**Reminder tools:** Calendar events and Reminders are separate systems. "
                "For any reminder query (list, create, delete, complete), call the appropriate reminder tool—"
                "do NOT claim you lack access to reminders, and do NOT look for reminders in the calendar snapshot above.\n"
                + "**Calendar deletion:** To delete an event from the snapshot above, call delete_calendar_event with the event title."
            )
    elif route == "tooling":
        profile = (
            profile
            + "\n\n### Calendar / schedule\n"
            + "No calendar snapshot was provided for this request. For calendar event queries, the user’s calendar "
            + "is not loaded yet — tell them to open ORBIT’s Calendar tab and refresh, then ask again.\n"
            + "For reminder queries (list, create, delete, complete), use the reminder tools directly — "
            + "they work independently of the calendar snapshot."
        )
    # Nudge small local models away from essay-length replies on casual turns.
    profile = (
        profile
        + "\n\n**Reply length:** Match the user’s energy. Short casual message → short reply unless they ask for detail."
    )
    profile = (
        profile
        + "\nFor simple check-ins (like 'how are you'), reply in 1-2 short sentences and avoid meta commentary."
    )
    profile = (
        profile
        + "\nDefault to concise replies: usually 2-4 sentences. Expand only when the user asks for depth, planning, or step-by-step detail."
    )
    if presence_note:
        profile += "\n\n### He just came back\n" + presence_note + "\n"

    if company_context:
        profile += "\n\n### He is not alone\n" + company_context + "\n"
    else:
        # Alone: ORBIT may follow his own curiosity. Permission, never obligation.
        profile += CURIOSITY_BLOCK
        parked = pending_curiosity_note(
            memory.get_meta(_CURIOSITY_KEY, ""),
            invited=detect_invitation_to_ask(user_message),
        )
        if parked:
            profile += parked

    if is_briefing_request(user_message):
        delta = briefing_delta_note(memory.get_meta(_BRIEFING_KEY, ""), life_events)
        if delta:
            profile += "\n\n### He already had a rundown recently\n" + delta + "\n"

    adaptive_style = adaptive_style_prompt_block(recent, user_message, style_prefs=style_prefs)
    if adaptive_style:
        profile = (
            profile
            + "\n\n### Adaptive style from recent user behavior\n"
            + adaptive_style
        )
    # "Approach B" used to prepend life events INTO the user message so the model
    # "couldn't miss them" — and on 2026-08-02 a bare "Um" (turn 1349) got a full memory
    # recital back, twice, because the injected block WAS the message. The events live in
    # the system prompt with ages and usage rules; the user's words go through untouched.
    return [Message(role="system", content=profile), *recent, Message(role="user", content=user_message)]


def is_memory_recall_question(text: str) -> bool:
    t = text.lower().strip()
    markers = (
        "remember",
        "last time",
        "previous conversation",
        "what were we talking",
        "what did we discuss",
        "do you recall",
        "where did we leave off",
    )
    return any(m in t for m in markers)


def is_casual_checkin(text: str) -> bool:
    t = text.lower().strip()
    if len(t) > 140:
        return False
    patterns = (
        r"\bhow are you\b",
        r"\bhow('?s| is) it going\b",
        r"\bhow('?s| is) your day\b",
        r"\bdoing (good|well|okay|ok)\b",
        r"\bjust checking in\b",
    )
    return any(re.search(p, t) for p in patterns)


def user_wants_detailed_answer(text: str) -> bool:
    t = text.lower()
    detail_markers = (
        "in detail",
        "step by step",
        "walk me through",
        "deep dive",
        "explain",
        "why",
        "how do i",
        "how to",
        "plan",
        "roadmap",
        "compare",
        "pros and cons",
        "architecture",
        "implement",
    )
    if any(m in t for m in detail_markers):
        return True
    return len(t.split()) >= 34


def adaptive_style_prompt_block(
    recent_turns: list[Message],
    user_message: str,
    *,
    style_prefs: Optional[dict[str, float]] = None,
) -> str:
    user_msgs = [m.content for m in recent_turns if m.role == "user" and m.content.strip()]
    if user_message.strip():
        user_msgs.append(user_message.strip())
    if not user_msgs:
        return ""

    sample = user_msgs[-6:]
    sample_text = " ".join(sample).lower()
    avg_words = sum(len(m.split()) for m in sample) / max(1, len(sample))

    concise_signals = (
        "be concise",
        "keep it concise",
        "brief",
        "short answer",
        "too long",
        "don't be long",
        "dont be long",
        "not too long",
        "just answer",
    )
    detailed_signals = (
        "in detail",
        "detailed",
        "step by step",
        "deep dive",
        "explain properly",
        "walk me through",
    )
    avoid_followups_signals = (
        "don't ask follow up",
        "dont ask follow up",
        "no follow up",
        "stop asking",
        "i do not want to discuss further",
        "i don't want to discuss further",
    )

    prefers_concise = any(s in sample_text for s in concise_signals) or avg_words <= 11
    prefers_detailed = any(s in sample_text for s in detailed_signals) or avg_words >= 24
    avoids_followups = any(s in sample_text for s in avoid_followups_signals)

    prefs = style_prefs or {}
    concise_score = float(prefs.get("pref_concise", 0.0))
    detailed_score = float(prefs.get("pref_detailed", 0.0))
    avoid_followups_score = float(prefs.get("avoid_followups", 0.0))
    if concise_score >= 0.35:
        prefers_concise = True
    if detailed_score >= 0.35:
        prefers_detailed = True
    if avoid_followups_score >= 0.35:
        avoids_followups = True

    lines: list[str] = []
    if prefers_concise and not prefers_detailed:
        lines.append(
            "User currently prefers compact answers. Keep most replies to 1-3 short sentences unless they explicitly ask for detail."
        )
    elif prefers_detailed and not prefers_concise:
        lines.append(
            "User currently tolerates depth. Give structured detail when useful, but still avoid filler and repetition."
        )
    else:
        lines.append("Use balanced brevity: concise by default, expand only when directly requested.")

    if avoids_followups:
        lines.append(
            "Avoid follow-up questions unless absolutely required to unblock execution. Do not ask social check-in questions by default."
        )
    else:
        lines.append("Ask at most one short follow-up only when missing details block a concrete action.")

    return "\n".join(f"- {line}" for line in lines)


def update_style_preferences_from_user_message(text: str) -> None:
    t = text.lower()
    concise_hits = (
        "be concise",
        "keep it concise",
        "brief",
        "too long",
        "short answer",
        "not too long",
        "just answer",
    )
    detailed_hits = (
        "in detail",
        "detailed",
        "step by step",
        "deep dive",
        "walk me through",
        "explain properly",
    )
    avoid_followup_hits = (
        "don't ask follow up",
        "dont ask follow up",
        "no follow up",
        "stop asking",
        "i do not want to discuss further",
        "i don't want to discuss further",
    )
    wants_followup_hits = (
        "ask me",
        "let's discuss",
        "lets discuss",
        "ask follow up",
    )

    if any(s in t for s in concise_hits):
        memory.bump_style_preference("pref_concise", +0.18)
        memory.bump_style_preference("pref_detailed", -0.08)
    if any(s in t for s in detailed_hits):
        memory.bump_style_preference("pref_detailed", +0.18)
        memory.bump_style_preference("pref_concise", -0.08)
    if any(s in t for s in avoid_followup_hits):
        memory.bump_style_preference("avoid_followups", +0.22)
    elif any(s in t for s in wants_followup_hits):
        memory.bump_style_preference("avoid_followups", -0.12)


def needs_small_model_guardrails(route: str) -> bool:
    """
    Whether a reply should be length-shaped before going out.

    `normalize_casual_checkin_reply` and `shorten_reply_when_overlong` exist to stop the 3B local
    model rambling — it needed hard caps. The brain and cloud models follow the personality in
    `user_profile.md` natively, and running these over their replies chopped the warmth straight
    back out: every sentence ending in "?" was deleted (so ORBIT could never ask "how was your
    shift?") and check-ins were capped at 26 words. That is the robotic feel, applied after the
    fact. Guardrails now apply only to the model that actually needs them.
    """
    return route not in ("brain", "cloud")


def strip_false_memory_disclaimer(reply: str) -> str:
    """
    Removes common lead-in disclaimers like 'I don't have memory...' when context exists.
    Keeps the useful summary that often follows.
    """
    s = reply.strip()
    patterns = [
        r"^\s*i do(?: not|n't) have[^.!\n]*[.!\n]\s*",
        r"^\s*but i can try to recall[^.!\n]*[.!\n]\s*",
        r"^\s*i (?:can't|cannot) remember[^.!\n]*[.!\n]\s*",
    ]
    out = s
    for p in patterns:
        out = re.sub(p, "", out, flags=re.IGNORECASE)
    out = out.strip()
    return out if out else s


def normalize_memory_recall_reply(reply: str, *, has_recent_turns: bool) -> str:
    """
    For recall-style user questions, keep output concise and avoid contradictory memory disclaimers.
    This is only used on memory-recall prompts, never for normal chats.
    """
    s = reply.strip()
    if not has_recent_turns:
        return s
    cleaned = strip_false_memory_disclaimer(s)
    # Remove residual disclaimer clauses that may appear mid-reply.
    cleaned = re.sub(
        r"\bbut i (?:do(?: not|n't)|cannot|can't) have[^.!\n]*[.!\n]?\s*",
        "",
        cleaned,
        flags=re.IGNORECASE,
    ).strip()
    cleaned = re.sub(r"^\s*last time we were discussing:\s*", "", cleaned, flags=re.IGNORECASE)
    return cleaned if cleaned else s


def strip_repetitive_reassurance(reply: str) -> str:
    patterns = [
        r"\bI(?:'m| am) always here to help(?: and support you)?(?:,?\s*so feel free to reach out whenever you need anything\.?)?",
        r"\bfeel free to reach out whenever you need anything\.?",
    ]
    out = reply
    for p in patterns:
        out = re.sub(p, "", out, flags=re.IGNORECASE)
    out = re.sub(r"\s{2,}", " ", out).strip()
    out = re.sub(r"\s+([,.!?;:])", r"\1", out)
    if out.startswith(","):
        out = out[1:].lstrip()
    return out if out else reply


def normalize_casual_checkin_reply(reply: str) -> str:
    s = reply.strip()
    if not s:
        return reply
    sentences = re.split(r"(?<=[.!?])\s+", s)
    kept: list[str] = []
    for sentence in sentences:
        clean = sentence.strip()
        if not clean:
            continue
        lowered = clean.lower()
        if "you're testing my responses" in lowered or "you are testing my responses" in lowered:
            continue
        if "i've noticed that you're testing" in lowered:
            continue
        if "i've already answered that question" in lowered:
            continue
        if "déjà vu" in lowered or "deja vu" in lowered:
            continue
        if clean.endswith("?"):
            # For quick check-ins, avoid always bouncing the question back.
            continue
        kept.append(clean)
        if len(kept) >= 2:
            break
    if not kept:
        kept = [sentences[0].strip()]
    out = " ".join(kept)
    words = out.split()
    if len(words) > 26:
        out = " ".join(words[:26]).rstrip(",;:") + "."
    return out


def shorten_reply_when_overlong(reply: str, *, user_message: str) -> str:
    if not reply.strip():
        return reply
    if user_wants_detailed_answer(user_message):
        return reply
    user_words = len(user_message.split())
    reply_words = len(reply.split())
    if user_words <= 10:
        if reply_words <= 42:
            return reply
        word_budget = 40
        sentence_budget = 2
    elif user_words <= 22:
        if reply_words <= 50:
            return reply
        word_budget = 50
        sentence_budget = 2
    else:
        if reply_words <= 68:
            return reply
        word_budget = 68
        sentence_budget = 3
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", reply.strip()) if s.strip()]
    if not sentences:
        return reply
    filler_markers = (
        "feel free to",
        "let me know if you'd like",
        "i'm happy to",
        "i can also",
        "by the way",
    )
    kept: list[str] = []
    for sentence in sentences:
        lowered = sentence.lower()
        if any(m in lowered for m in filler_markers):
            continue
        candidate = " ".join(kept + [sentence]).strip()
        if len(candidate.split()) > word_budget and kept:
            break
        kept.append(sentence)
        if len(kept) >= sentence_budget:
            break
    out = " ".join(kept).strip()
    if len(out.split()) > word_budget:
        out = " ".join(out.split()[:word_budget]).rstrip(",;:") + "."
    return out if out else reply


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "orbit-core"}


@app.get("/facts", response_model=FactListResponse)
async def list_facts() -> FactListResponse:
    """Phase-2-lite: manually curated facts injected into /chat system context."""
    rows = memory.list_fact_records(limit=50)
    return FactListResponse(items=[FactRecord(id=i, fact=t) for i, t in rows])


@app.post("/facts", response_model=FactListResponse)
async def add_fact(payload: FactCreate) -> FactListResponse:
    s = get_settings()
    memory.add_fact(content_for_storage(payload.fact, redact_local_storage=s.redact_local_storage))
    rows = memory.list_fact_records(limit=50)
    return FactListResponse(items=[FactRecord(id=i, fact=t) for i, t in rows])


@app.delete("/facts/{fact_id}", response_model=FactListResponse)
async def delete_fact(fact_id: int) -> FactListResponse:
    if not memory.delete_fact(fact_id):
        raise HTTPException(status_code=404, detail="Fact not found")
    rows = memory.list_fact_records(limit=50)
    return FactListResponse(items=[FactRecord(id=i, fact=t) for i, t in rows])


@app.get("/semantic-memory", response_model=SemanticMemoryListResponse)
async def list_semantic_memory() -> SemanticMemoryListResponse:
    rows = memory.list_semantic_records(limit=120)
    return SemanticMemoryListResponse(
        items=[SemanticMemoryRecord(id=i, text=t, source=s, importance=imp) for i, t, s, imp in rows]
    )


@app.post("/semantic-memory", response_model=SemanticMemoryListResponse)
async def add_semantic_memory(payload: SemanticMemoryCreate) -> SemanticMemoryListResponse:
    s = get_settings()
    text = content_for_storage(payload.text, redact_local_storage=s.redact_local_storage)
    importance = payload.importance
    if importance is None:
        importance = 0.9 if payload.source.strip().lower() == "manual" else 0.65
    memory.add_semantic_memory(
        text,
        source=payload.source,
        importance=importance,
        conflict_sig=conflict_signature(text),
    )
    memory.prune_semantic_memory(
        retention_days=s.semantic_memory_retention_days,
        max_items=s.semantic_memory_max_items,
    )
    rows = memory.list_semantic_records(limit=120)
    return SemanticMemoryListResponse(
        items=[SemanticMemoryRecord(id=i, text=t, source=src, importance=imp) for i, t, src, imp in rows]
    )


@app.delete("/semantic-memory", response_model=SemanticMemoryPurgeResponse)
async def clear_semantic_memory() -> SemanticMemoryPurgeResponse:
    deleted = memory.clear_semantic_memory()
    return SemanticMemoryPurgeResponse(deleted_count=deleted)


@app.delete("/semantic-memory/{memory_id}", response_model=SemanticMemoryListResponse)
async def delete_semantic_memory(memory_id: int) -> SemanticMemoryListResponse:
    if not memory.delete_semantic_memory(memory_id):
        raise HTTPException(status_code=404, detail="Semantic memory not found")
    rows = memory.list_semantic_records(limit=120)
    return SemanticMemoryListResponse(
        items=[SemanticMemoryRecord(id=i, text=t, source=s, importance=imp) for i, t, s, imp in rows]
    )


@app.patch("/semantic-memory/{memory_id}", response_model=SemanticMemoryListResponse)
async def update_semantic_memory_importance(
    memory_id: int, payload: SemanticMemoryImportanceUpdate
) -> SemanticMemoryListResponse:
    if not memory.set_semantic_memory_importance(memory_id, payload.importance):
        raise HTTPException(status_code=404, detail="Semantic memory not found")
    rows = memory.list_semantic_records(limit=120)
    return SemanticMemoryListResponse(
        items=[SemanticMemoryRecord(id=i, text=t, source=s, importance=imp) for i, t, s, imp in rows]
    )


@app.get("/memory/stats")
async def memory_stats() -> dict[str, object]:
    s = get_settings()
    return {
        "counts": memory.semantic_memory_stats(),
        "style_preferences": memory.style_preferences(),
        "semantic_memory_enabled": s.semantic_memory_enabled,
        "semantic_memory_min_score": s.semantic_memory_min_score,
        "semantic_memory_retention_days": s.semantic_memory_retention_days,
        "semantic_memory_max_items": s.semantic_memory_max_items,
        "redact_local_storage": s.redact_local_storage,
        "embed_model": s.embed_model,
        "embed_provider_active": is_real_embedder_active(),
    }


@app.get("/memory/personal-knowledge")
async def personal_knowledge() -> dict:
    """Returns the structured personal knowledge profile."""
    return {
        "profile": memory.get_core_profile(max_per_category=5),
        "stats": memory.personal_knowledge_stats(),
    }


@app.get("/memory/life-events")
async def life_events() -> dict:
    """Returns recent life events (episodic memory)."""
    return {
        "events": memory.recent_life_events(limit=20, days=7),
    }


@app.get("/memory/mood")
async def mood_history() -> dict:
    """Returns mood trend and recent emotional signals."""
    return {
        "trend_24h": memory.mood_trend(hours=24),
        "trend_7d": memory.mood_trend(hours=168),
    }


@app.get("/memory/daily-summaries")
async def daily_summaries() -> dict:
    """Returns recent daily and weekly summaries."""
    return {
        "summaries": memory.recent_daily_summaries(days=30),
    }


@app.get("/ready")
async def ready() -> dict[str, object]:
    """Checks local LLM (Ollama tags API or OpenAI-compatible /v1/models)."""
    s = get_settings()
    env_path = Path(__file__).resolve().parents[1] / ".env"
    base = s.local_llm_url.rstrip("/")
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            if s.local_llm_backend == "openai":
                response = await client.get(f"{base}/v1/models")
            else:
                response = await client.get(f"{base}/api/tags")
            response.raise_for_status()
    except httpx.RequestError as exc:
        return {
            "ok": False,
            "local_llm_url": s.local_llm_url,
            "local_llm_backend": s.local_llm_backend,
            "env_file": str(env_path),
            "env_file_exists": env_path.is_file(),
            "error": str(exc),
            "hint_ollama": "Start Ollama or run `ollama serve`.",
            "hint_mlx": "Start MLX: `mlx_lm.server --model <hf-repo> --port 8080` (see orbit-core README).",
        }
    return {
        "ok": True,
        "local_llm_url": s.local_llm_url,
        "local_llm_backend": s.local_llm_backend,
        "env_file": str(env_path),
        "env_file_exists": env_path.is_file(),
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(payload: ChatRequest) -> ChatResponse:
    s = get_settings()
    t0 = time.monotonic()
    route = resolve_route(
        payload.message,
        payload.route_hint,
        cloud_min_chars=s.cloud_fallback_min_chars,
    )
    # Repair misheard names once, at the door. Everything downstream — the brain, the tool
    # calls, semantic recall and what gets written to memory — then works with the real
    # person, so a mishearing cannot propagate into history and confuse later turns.
    corrected_message, name_corrections = resolve_people_in_text(
        payload.message, memory.all_people()
    )

    recent_turns = memory.recent_turns(session_id=payload.session_id, limit=8)
    style_prefs = memory.style_preferences()
    semantic_hits = (
        memory.semantic_search(
            corrected_message,
            limit=4,
            min_score=s.semantic_memory_min_score,
        )
        if s.semantic_memory_enabled
        else []
    )
    # Presence: if he told ORBIT he was stepping away, his next message is a return.
    presence_note = None
    stored_away = memory.get_meta(_AWAY_KEY, "")
    if stored_away:
        presence_note = presence_note_on_return(stored_away)
        if presence_note:
            memory.set_meta(_AWAY_KEY, "")

    # Company: someone else in the room changes what ORBIT should volunteer.
    # "I'm alone now" clears it as surely as "she left" — he is answering the question
    # ORBIT is allowed to ask before raising anything private.
    if detect_company_left(corrected_message) or detect_solitude(corrected_message):
        memory.set_meta(_COMPANY_KEY, "")
    elif (arrival := detect_company(corrected_message, memory.all_people())) and payload.save_memory:
        from datetime import datetime as _dt
        memory.set_meta(_COMPANY_KEY, json.dumps({
            "at": _dt.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
            "names": arrival["names"],
            "wants_greeting": arrival["wants_greeting"],
        }))
    company_context = company_note(memory.get_meta(_COMPANY_KEY, ""))

    messages = build_messages(
        payload.session_id,
        corrected_message,
        s.profile_path,
        route=route,
        tooling_context=payload.tooling_context,
        client_local_iso=payload.client_local_iso,
        client_tz=payload.client_tz,
        semantic_memory_enabled=s.semantic_memory_enabled,
        recent_turns=recent_turns,
        semantic_hits=semantic_hits,
        style_prefs=style_prefs,
        presence_note=presence_note,
        name_corrections=name_corrections,
        company_context=company_context,
    )

    model: Optional[str] = None
    pending_tool_calls: list[ToolCallInfo] = []
    reply: str = ""
    connectivity_notice: str = ""

    try:
        if route == "cloud":
            if not s.cloud_api_key.strip():
                raise HTTPException(
                    status_code=503,
                    detail=(
                        "Cloud tier selected but CLOUD_API_KEY is empty. "
                        "Set CLOUD_API_KEY (and optionally CLOUD_BASE_URL / CLOUD_MODEL) in orbit-core/.env."
                    ),
                )
            try:
                outbound = (
                    redact_messages_copy(messages)
                    if s.cloud_redact_pii
                    else messages
                )
                reply = await chat_with_cloud(
                    outbound,
                    base_url=s.cloud_base_url,
                    model=s.cloud_model,
                    api_key=s.cloud_api_key,
                    max_tokens=s.chat_max_tokens_cloud,
                )
            except httpx.RequestError as exc:
                raise HTTPException(
                    status_code=503,
                    detail=(
                        f"Cannot reach cloud LLM at {s.cloud_base_url}. "
                        f"Model={s.cloud_model}. Error: {exc}"
                    ),
                ) from exc
            model = s.cloud_model
        elif route in ("local", "tooling", "brain") and s.brain_api_key.strip():
            # Brain path: tool-calling capable LLM (model set via BRAIN_MODEL).
            try:
                reply_text, tool_call_dicts = await chat_with_brain(
                    messages,
                    api_key=s.brain_api_key,
                    base_url=s.brain_base_url,
                    model=s.brain_model,
                    max_tokens=s.chat_max_tokens_cloud,
                )
                model = s.brain_model
                route = "brain"
                reply = reply_text
                connectivity_notice = _note_brain_online()
                pending_tool_calls = [
                    ToolCallInfo(tool=tc["tool"], params=tc["params"], id=tc["id"])
                    for tc in tool_call_dicts
                ]
                # Discretion guard. Prompting is not enforcement — the same lesson as the
                # name resolution — so if ORBIT raises something intimate while other people
                # can hear, the reply is regenerated rather than trusted. Only when ORBIT
                # brought it up: if Ayush raised it himself, he chose to.
                if (
                    not pending_tool_calls
                    and company_context
                    and contains_sensitive_probe(reply)
                    and not contains_sensitive_probe(corrected_message)
                ):
                    try:
                        safer, _ = await chat_with_brain(
                            [
                                *messages,
                                Message(role="assistant", content=reply),
                                Message(
                                    role="system",
                                    content=(
                                        "That draft raises something private while someone "
                                        "else is in the room with him. Say it again without "
                                        "any of it — no romance, feelings about people, "
                                        "health, or money. Reply to what he actually said, "
                                        "warmly and briefly."
                                    ),
                                ),
                            ],
                            api_key=s.brain_api_key,
                            base_url=s.brain_base_url,
                            model=s.brain_model,
                            max_tokens=s.chat_max_tokens_cloud,
                        )
                        if safer.strip() and not contains_sensitive_probe(safer):
                            # Hold the question rather than destroying it — he can be asked
                            # once the room is clear. Discretion shouldn't cost ORBIT its
                            # curiosity, only its timing.
                            if payload.save_memory:
                                park_curiosity(memory, _sensitive_sentence(reply))
                            reply = safer
                    except (httpx.RequestError, RuntimeError):
                        pass  # never fail the turn over discretion; the draft stands

                # Structural repetition guard: if the draft near-repeats a recent reply,
                # regenerate once with the draft in view. He heard it the first time.
                if not pending_tool_calls and _is_near_duplicate_reply(reply, recent_turns):
                    try:
                        fresh, _ = await chat_with_brain(
                            [
                                *messages,
                                Message(role="assistant", content=reply),
                                Message(
                                    role="system",
                                    content=(
                                        "That draft repeats what you already told him moments "
                                        "ago. Reply freshly to his LAST message only — short "
                                        "and natural, no recap of plans, reminders, or schedule."
                                    ),
                                ),
                            ],
                            api_key=s.brain_api_key,
                            base_url=s.brain_base_url,
                            model=s.brain_model,
                            max_tokens=s.chat_max_tokens_cloud,
                        )
                        if fresh.strip():
                            reply = fresh
                    except (httpx.RequestError, RuntimeError):
                        pass  # never fail the turn over dedup; the original reply stands
            except httpx.RequestError:
                # Offline resilience: the brain is a cloud call. Without internet ORBIT must
                # not go dead — a companion that needs wi-fi to say hello is not a companion.
                # Fall back to the local MLX model. (Phrase-matched system commands never
                # reach this path; they keep working fully offline in Swift.)
                if looks_like_action_request(payload.message):
                    # Never let the tool-less local model answer an action request — it invents
                    # having done it. Answer deterministically and name what still works offline.
                    reply = (
                        "I can't run that one right now — I'm offline, so my tools are out of "
                        "reach. Say it with the exact words and I'll do it right here on the Mac: "
                        "“turn wifi on”, “volume up”, “brightness down”, "
                        "or “open safari”."
                    )
                else:
                    offline_note = Message(
                        role="system",
                        content=(
                            "NOTE: You are running OFFLINE on the small local model — the cloud brain "
                            "and its tools are unreachable (likely no internet or wi-fi is off). "
                            "You have NO tools and cannot change anything on this Mac. NEVER say you "
                            "have done, turned on, turned off, opened, set, or changed something — you "
                            "physically cannot. Just talk with him warmly and briefly."
                        ),
                    )
                    try:
                        reply = await chat_openai_compatible(
                            base_url=s.local_llm_url,
                            model=s.local_llm_model,
                            messages=[messages[0], offline_note, *messages[1:]],
                            max_tokens=s.chat_max_tokens_local,
                        )
                    except (httpx.RequestError, RuntimeError) as exc2:
                        raise HTTPException(
                            status_code=503,
                            detail=(
                                f"Brain LLM unreachable and local LLM at {s.local_llm_url} is also down. "
                                f"Error: {exc2}"
                            ),
                        ) from exc2
                model = s.local_llm_model
                route = "local"
                connectivity_notice = _note_brain_offline()
        else:
            try:
                reply = await chat_openai_compatible(
                    base_url=s.local_llm_url,
                    model=s.local_llm_model,
                    messages=messages,
                    max_tokens=s.chat_max_tokens_local,
                )
            except httpx.RequestError as exc:
                raise HTTPException(
                    status_code=503,
                    detail=(
                        f"Cannot reach local LLM at {s.local_llm_url}. "
                        f"Backend={s.local_llm_backend}. Error: {exc}"
                    ),
                ) from exc
            model = s.local_llm_model

        elapsed_ms = int((time.monotonic() - t0) * 1000)
        append_chat_audit_event(
            path=s.chat_audit_log_path,
            status="ok",
            session_id=payload.session_id,
            route=route,
            route_hint=payload.route_hint,
            model=model,
            msg_chars=len(payload.message),
            tooling_chars=len((payload.tooling_context or "")),
            cloud_redact=(route == "cloud" and s.cloud_redact_pii),
            duration_ms=elapsed_ms,
            max_bytes=s.chat_audit_max_bytes,
            backup_count=s.chat_audit_backup_count,
        )
        logger.info(
            "chat_ok route=%s model=%s session_id=%s msg_chars=%d route_hint=%s "
            "tooling_chars=%d cloud_redact=%s duration_ms=%d",
            route,
            model,
            payload.session_id[:48],
            len(payload.message),
            payload.route_hint,
            len((payload.tooling_context or "")),
            (route == "cloud" and s.cloud_redact_pii),
            elapsed_ms,
        )
    except HTTPException as exc:
        append_chat_audit_event(
            path=s.chat_audit_log_path,
            status="error",
            session_id=payload.session_id,
            route=route,
            route_hint=payload.route_hint,
            model=model,
            msg_chars=len(payload.message),
            tooling_chars=len((payload.tooling_context or "")),
            cloud_redact=(route == "cloud" and s.cloud_redact_pii),
            duration_ms=int((time.monotonic() - t0) * 1000),
            error=str(exc.detail) if hasattr(exc, "detail") else str(exc),
            max_bytes=s.chat_audit_max_bytes,
            backup_count=s.chat_audit_backup_count,
        )
        raise
    except Exception as exc:
        append_chat_audit_event(
            path=s.chat_audit_log_path,
            status="error",
            session_id=payload.session_id,
            route=route,
            route_hint=payload.route_hint,
            model=model,
            msg_chars=len(payload.message),
            tooling_chars=len((payload.tooling_context or "")),
            cloud_redact=(route == "cloud" and s.cloud_redact_pii),
            duration_ms=int((time.monotonic() - t0) * 1000),
            error=str(exc),
            max_bytes=s.chat_audit_max_bytes,
            backup_count=s.chat_audit_backup_count,
        )
        raise HTTPException(status_code=500, detail=f"Model request failed: {exc}") from exc

    # When the brain issued tool calls, return immediately — no memory save yet.
    # Swift will execute them all and POST to /chat/tool-result.
    if pending_tool_calls:
        return ChatResponse(
            reply=connectivity_notice + (reply or "Let me check that for you."),
            route="brain",
            model=model or s.brain_model,
            tool_calls=pending_tool_calls,
        )

    if not reply:
        append_chat_audit_event(
            path=s.chat_audit_log_path,
            status="error",
            session_id=payload.session_id,
            route=route,
            route_hint=payload.route_hint,
            model=model,
            msg_chars=len(payload.message),
            tooling_chars=len((payload.tooling_context or "")),
            cloud_redact=(route == "cloud" and s.cloud_redact_pii),
            duration_ms=int((time.monotonic() - t0) * 1000),
            error="Empty model response",
            max_bytes=s.chat_audit_max_bytes,
            backup_count=s.chat_audit_backup_count,
        )
        raise HTTPException(status_code=502, detail="Empty model response")

    if is_memory_recall_question(payload.message):
        reply = normalize_memory_recall_reply(reply, has_recent_turns=bool(recent_turns))
    if needs_small_model_guardrails(route):
        if is_casual_checkin(payload.message):
            reply = normalize_casual_checkin_reply(reply)
        reply = shorten_reply_when_overlong(reply, user_message=payload.message)
    reply = strip_repetitive_reassurance(reply)
    # Greet once per conversation stretch — "Afternoon, Ayush." on two consecutive
    # replies was part of the 3 PM briefing case.
    reply = _strip_repeated_greeting(reply, recent_turns)
    reply = ground_calendar_reply(
        reply,
        user_message=payload.message,
        route=route,
        tooling_context=payload.tooling_context,
        client_local_iso=payload.client_local_iso,
    )

    if is_briefing_request(payload.message) and payload.save_memory:
        from datetime import datetime as _dt
        covered = [str(ev.get("summary")) for ev in memory.recent_life_events(limit=8, days=3)]
        if covered:
            memory.set_meta(_BRIEFING_KEY, json.dumps({
                "at": _dt.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
                "covered": covered,
            }))

    # A parked question is asked once. If ORBIT raised it in this reply, retire it — a
    # companion that keeps circling back to the same question is not curious, it's stuck.
    if payload.save_memory and memory.get_meta(_CURIOSITY_KEY, "") and reply.rstrip().endswith("?"):
        memory.set_meta(_CURIOSITY_KEY, "")

    departure = detect_departure(payload.message)
    if departure and payload.save_memory:
        from datetime import datetime as _dt
        memory.set_meta(_AWAY_KEY, json.dumps({
            "at": _dt.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
            "minutes": departure["minutes"],
            "said": departure["said"],
        }))

    # Store the corrected text, not the raw transcript: a misheard name written into
    # history resurfaces as context on every later turn.
    user_for_store = content_for_storage(corrected_message, redact_local_storage=s.redact_local_storage)
    reply_for_store = content_for_storage(reply, redact_local_storage=s.redact_local_storage)
    if payload.save_memory:
        # Who was in the room is part of the record. Without it, nothing downstream can tell
        # his voice from a guest's, and a guest's words become facts about him.
        turn_context = "company" if company_context else "alone"
        memory.append_turn(payload.session_id, "user", user_for_store, context=turn_context)
        memory.append_turn(payload.session_id, "assistant", reply_for_store, context=turn_context)
    update_style_preferences_from_user_message(payload.message)
    if payload.save_memory and s.semantic_memory_enabled:
        source_text = user_for_store if s.redact_local_storage else corrected_message
        # The third regex writer, gated like the other two. Measured on the live DB: every
        # one of the 19 stored vectors was verbatim conversational debris ("I am doing good,
        # thank for asking!", "Nothing, I'm just being lazy") — nothing a companion should
        # recall. The LLM pass mirrors its distilled facts into semantic memory instead.
        if not s.brain_api_key.strip():
            for candidate, score in extract_scored_candidate_memories(source_text):
                if score >= s.semantic_memory_min_score:
                    memory.add_semantic_memory(
                        candidate,
                        source="auto",
                        importance=score,
                        conflict_sig=conflict_signature(candidate),
                    )
        # Regex extraction is the OFFLINE fallback only. Phase 3.6 introduced the LLM
        # extractor to replace it, but never stopped the regex writers — so both ran on
        # every turn and the regex pair kept filing raw transcript as knowledge ("I want
        # to delete few reminders" under *goals*). Worse, that junk is fed back to the LLM
        # as "already known, do not repeat", suppressing the clean version of the same
        # fact. When a brain key exists the LLM pass owns memory; turns are saved either
        # way, so anything captured offline is distilled once connectivity returns.
        regex_extraction_only = not s.brain_api_key.strip()
        if regex_extraction_only:
            for ev in extract_life_events(source_text):
                memory.add_life_event(
                    ev["summary"],
                    category=ev.get("category", "general"),
                    emotion=ev.get("emotion"),
                    event_date=ev.get("event_date"),
                    importance=ev.get("importance", 0.5),
                )
        # Emotion tracking
        emotion_result = detect_emotion(source_text)
        if emotion_result:
            emotion_label, emotion_score = emotion_result
            memory.log_mood(emotion_label, emotion_score, source_text[:100])
        if regex_extraction_only:
            for pk in extract_personal_knowledge(source_text):
                memory.add_personal_knowledge(
                    pk["category"], pk["fact"], pk.get("importance", 0.5), source_text[:100]
                )
        memory.prune_semantic_memory(
            retention_days=s.semantic_memory_retention_days,
            max_items=s.semantic_memory_max_items,
        )
        memory.prune_life_events(retention_days=30)
        memory.prune_mood_log(retention_days=30)
        # Track proactive nudges: if ORBIT's reply references a past event, log it
        # so the same topic isn't brought up again within 48 hours.
        recent_events = memory.recent_life_events(limit=8, days=3)
        _track_nudge_usage(reply, recent_events)
        # Distil the conversation into real knowledge in the background — never on the reply path.
        asyncio.create_task(run_memory_extraction(payload.session_id))
        # And once a day, consolidate: retire duplicates and events whose moment has passed.
        if memory_consolidation.is_due(memory):
            asyncio.create_task(run_consolidation())

    mem_debug = (
        MemoryDebug(
            recent_turn_count=len(recent_turns),
            semantic_hits=semantic_hits,
        )
        if payload.include_memory_debug
        else None
    )
    # The notice is spoken but deliberately not stored — memory keeps the real reply.
    return ChatResponse(
        reply=connectivity_notice + reply,
        route=route,
        model=model,
        memory_debug=mem_debug,
    )


@app.post("/chat/stream")
async def chat_stream(payload: ChatRequest) -> StreamingResponse:
    """Server-sent events stream: yields `{"token":"..."}` chunks then a final `{"done":true,...}`."""
    s = get_settings()
    t0 = time.monotonic()
    route = resolve_route(
        payload.message,
        payload.route_hint,
        cloud_min_chars=s.cloud_fallback_min_chars,
    )
    recent_turns = memory.recent_turns(session_id=payload.session_id, limit=8)
    style_prefs = memory.style_preferences()
    semantic_hits = (
        memory.semantic_search(
            payload.message,
            limit=4,
            min_score=s.semantic_memory_min_score,
        )
        if s.semantic_memory_enabled
        else []
    )
    messages = build_messages(
        payload.session_id,
        payload.message,
        s.profile_path,
        route=route,
        tooling_context=payload.tooling_context,
        client_local_iso=payload.client_local_iso,
        client_tz=payload.client_tz,
        semantic_memory_enabled=s.semantic_memory_enabled,
        recent_turns=recent_turns,
        semantic_hits=semantic_hits,
        style_prefs=style_prefs,
    )

    async def generate():
        parts: list[str] = []
        model: Optional[str] = None
        final_route = route  # may be updated to "brain" below
        try:
            if route == "cloud":
                if not s.cloud_api_key.strip():
                    yield f"data: {json.dumps({'error': 'Cloud API key not configured.'})}\n\n"
                    return
                outbound = redact_messages_copy(messages) if s.cloud_redact_pii else messages
                async for token in stream_cloud(
                    outbound,
                    base_url=s.cloud_base_url,
                    model=s.cloud_model,
                    api_key=s.cloud_api_key,
                    max_tokens=s.chat_max_tokens_cloud,
                ):
                    parts.append(token)
                    yield f"data: {json.dumps({'token': token})}\n\n"
                model = s.cloud_model
            elif s.brain_api_key.strip():
                # Brain streaming — mirrors the non-streaming /chat brain path
                async for token in stream_openai_compatible(
                    base_url=s.brain_base_url,
                    model=s.brain_model,
                    messages=messages,
                    bearer_token=s.brain_api_key,
                    max_tokens=s.chat_max_tokens_cloud,
                ):
                    parts.append(token)
                    yield f"data: {json.dumps({'token': token})}\n\n"
                model = s.brain_model
                final_route = "brain"
            else:
                # Local LLM fallback when no brain_api_key configured
                async for token in stream_openai_compatible(
                    base_url=s.local_llm_url,
                    model=s.local_llm_model,
                    messages=messages,
                    max_tokens=s.chat_max_tokens_local,
                ):
                    parts.append(token)
                    yield f"data: {json.dumps({'token': token})}\n\n"
                model = s.local_llm_model
        except Exception as exc:
            yield f"data: {json.dumps({'error': str(exc)})}\n\n"
            return

        reply = "".join(parts).strip()
        if not reply:
            yield f"data: {json.dumps({'error': 'Empty model response'})}\n\n"
            return

        # Post-processing (same pipeline as /chat)
        if is_memory_recall_question(payload.message):
            reply = normalize_memory_recall_reply(reply, has_recent_turns=bool(recent_turns))
        if needs_small_model_guardrails(final_route):
            if is_casual_checkin(payload.message):
                reply = normalize_casual_checkin_reply(reply)
            reply = shorten_reply_when_overlong(reply, user_message=payload.message)
        reply = strip_repetitive_reassurance(reply)
        reply = ground_calendar_reply(
            reply,
            user_message=payload.message,
            route=route,
            tooling_context=payload.tooling_context,
            client_local_iso=payload.client_local_iso,
        )

        # Persist to memory
        user_for_store = content_for_storage(payload.message, redact_local_storage=s.redact_local_storage)
        reply_for_store = content_for_storage(reply, redact_local_storage=s.redact_local_storage)
        if payload.save_memory:
            memory.append_turn(payload.session_id, "user", user_for_store)
            memory.append_turn(payload.session_id, "assistant", reply_for_store)
        update_style_preferences_from_user_message(payload.message)
        if payload.save_memory and s.semantic_memory_enabled:
            source_text = user_for_store if s.redact_local_storage else payload.message
            for candidate, score in extract_scored_candidate_memories(source_text):
                if score >= s.semantic_memory_min_score:
                    memory.add_semantic_memory(
                        candidate,
                        source="auto",
                        importance=score,
                        conflict_sig=conflict_signature(candidate),
                    )
            for ev in extract_life_events(source_text):
                memory.add_life_event(
                    ev["summary"],
                    category=ev.get("category", "general"),
                    emotion=ev.get("emotion"),
                    event_date=ev.get("event_date"),
                    importance=ev.get("importance", 0.5),
                )
            emotion_result = detect_emotion(source_text)
            if emotion_result:
                emotion_label, emotion_score = emotion_result
                memory.log_mood(emotion_label, emotion_score, source_text[:100])
            for pk in extract_personal_knowledge(source_text):
                memory.add_personal_knowledge(
                    pk["category"], pk["fact"], pk.get("importance", 0.5), source_text[:100]
                )
            memory.prune_semantic_memory(
                retention_days=s.semantic_memory_retention_days,
                max_items=s.semantic_memory_max_items,
            )

        elapsed_ms = int((time.monotonic() - t0) * 1000)
        append_chat_audit_event(
            path=s.chat_audit_log_path,
            status="ok",
            session_id=payload.session_id,
            route=final_route,
            route_hint=payload.route_hint,
            model=model,
            msg_chars=len(payload.message),
            tooling_chars=len((payload.tooling_context or "")),
            cloud_redact=(route == "cloud" and s.cloud_redact_pii),
            duration_ms=elapsed_ms,
            max_bytes=s.chat_audit_max_bytes,
            backup_count=s.chat_audit_backup_count,
        )

        done: dict[str, object] = {"done": True, "route": final_route, "model": model, "reply": reply}
        if payload.include_memory_debug:
            done["memory_debug"] = {
                "recent_turn_count": len(recent_turns),
                "semantic_hits": semantic_hits,
            }
        yield f"data: {json.dumps(done)}\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


@app.post("/chat/tool-result", response_model=ChatResponse)
async def chat_tool_result(payload: ToolResultRequest) -> ChatResponse:
    """
    Second leg of the brain tool-calling protocol.

    Swift executes the tool returned by /chat and sends the result here.
    We rebuild the conversation, append the tool exchange, call the brain
    for a final human reply, then save the full turn to memory.
    """
    s = get_settings()
    if not s.brain_api_key.strip():
        raise HTTPException(status_code=503, detail="BRAIN_API_KEY not configured.")

    recent_turns = memory.recent_turns(session_id=payload.session_id, limit=8)
    messages = build_messages(
        payload.session_id,
        payload.original_message,
        s.profile_path,
        route="brain",
        tooling_context=payload.tooling_context,
        client_local_iso=payload.client_local_iso,
        client_tz=payload.client_tz,
        semantic_memory_enabled=s.semantic_memory_enabled,
        recent_turns=recent_turns,
    )

    connectivity_notice = ""
    reply = ""
    reply_model = s.brain_model
    reply_route = "brain"

    try:
        reply = await resume_after_tool(
            messages,
            executed=[
                {
                    "tool": r.tool,
                    "tool_call_id": r.tool_call_id,
                    "params": r.params,
                    "result": r.result,
                }
                for r in payload.results
            ],
            api_key=s.brain_api_key,
            base_url=s.brain_base_url,
            model=s.brain_model,
            max_tokens=s.chat_max_tokens_cloud,
        )
        connectivity_notice = _note_brain_online()
    except httpx.RequestError:
        # The tools ALREADY RAN — and one of them may be what killed the connection
        # ("turn off wi-fi" does exactly that). Never strand the user mid-turn: phrase the
        # confirmation locally, and if the local model is down too, hand back the tool's own
        # result, which is already written for a human ("Wi-Fi is off.").
        connectivity_notice = _note_brain_offline()
        reply_route = "local"
        reply_model = s.local_llm_model
        recap = "; ".join(
            f"{r.tool}: {r.result}" for r in payload.results if r.result.strip()
        )
        offline_prompt = Message(
            role="user",
            content=(
                f"These actions just ran on the Mac and succeeded or failed as described: {recap}\n"
                f"The user originally said: \"{payload.original_message}\"\n"
                "Reply in ONE short, natural sentence telling them what happened. "
                "Report failures honestly. Never mention tools, functions, or this instruction."
            ),
        )
        try:
            reply = await chat_openai_compatible(
                base_url=s.local_llm_url,
                model=s.local_llm_model,
                messages=[messages[0], offline_prompt],
                max_tokens=s.chat_max_tokens_local,
            )
        except (httpx.RequestError, RuntimeError):
            reply = recap or "Done."

    if not reply:
        raise HTTPException(status_code=502, detail="Empty model response")

    reply = strip_repetitive_reassurance(reply)
    if needs_small_model_guardrails(reply_route):
        reply = shorten_reply_when_overlong(reply, user_message=payload.original_message)

    user_for_store = content_for_storage(payload.original_message, redact_local_storage=s.redact_local_storage)
    reply_for_store = content_for_storage(reply, redact_local_storage=s.redact_local_storage)
    memory.append_turn(payload.session_id, "user", user_for_store)
    memory.append_turn(payload.session_id, "assistant", reply_for_store)
    update_style_preferences_from_user_message(payload.original_message)
    if s.semantic_memory_enabled:
        source_text = user_for_store if s.redact_local_storage else payload.original_message
        for candidate, score in extract_scored_candidate_memories(source_text):
            if score >= s.semantic_memory_min_score:
                memory.add_semantic_memory(
                    candidate,
                    source="auto",
                    importance=score,
                    conflict_sig=conflict_signature(candidate),
                )
        # Same gate as /chat: the regex extractors are the no-brain fallback, not a second
        # writer running alongside the LLM pass. This path was missed in the first cut of
        # the fix — every tool confirmation was still feeding the junk pipeline.
        if not s.brain_api_key.strip():
            for ev in extract_life_events(source_text):
                memory.add_life_event(
                    ev["summary"],
                    category=ev.get("category", "general"),
                    emotion=ev.get("emotion"),
                    event_date=ev.get("event_date"),
                    importance=ev.get("importance", 0.5),
                )
            for pk in extract_personal_knowledge(source_text):
                memory.add_personal_knowledge(
                    pk["category"], pk["fact"], pk.get("importance", 0.5), source_text[:100]
                )
        emotion_result = detect_emotion(source_text)
        if emotion_result:
            emotion_label, emotion_score = emotion_result
            memory.log_mood(emotion_label, emotion_score, source_text[:100])
        memory.prune_semantic_memory(
            retention_days=s.semantic_memory_retention_days,
            max_items=s.semantic_memory_max_items,
        )

    return ChatResponse(
        reply=connectivity_notice + reply,
        route=reply_route,
        model=reply_model,
    )
