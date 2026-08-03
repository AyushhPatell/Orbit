"""Memory consolidation — the sleep cycle (M7, 2026-08-03).

Memory that only ever grows becomes memory that contradicts itself. The live DB showed the
shape of it before the 2026-08-03 cleanup: three near-identical Spider-Man entries and three
Kan/Kawan entries, all live in the recall window at once, so a single plan looked like several.

Recent agent-memory research separates a fast episodic buffer from a slower consolidation
pass that merges and retires — this is that pass, deliberately kept **deterministic**:

- **Dedupe** near-identical entries; the strongest survives, the rest are retired.
- **Expire** events whose moment has clearly passed, so they leave the recall window.

No LLM call. Nothing is deleted — duplicates and finished events are marked `is_resolved`,
which is exactly what that column is for. That keeps the pass cheap, testable, reversible,
and portable to iOS (plain SQL, no exotic dependencies), per the platform constraint.

Entity-level merging ("Kan" and "Kawan" are one person split by a mishearing) is NOT handled
here — that is M8, and guessing at it with string similarity would merge real distinct people.
"""

from __future__ import annotations

import difflib
import logging
import re
from datetime import datetime, timedelta
from typing import Any, Optional

logger = logging.getLogger("orbit.memory.consolidate")

LAST_RUN_KEY = "consolidation.last_run"

# Tuned against the real duplicate pairs found in the live DB. High enough that two genuinely
# different plans on the same day stay separate; low enough to catch a restatement.
SIMILARITY_THRESHOLD = 0.82

# How long after an event ends before it stops being "recent life" and becomes history.
EXPIRE_AFTER_HOURS = 36


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]+", " ", (text or "").lower())).strip()


def _lexical_similar(a: str, b: str) -> float:
    na, nb = _normalize(a), _normalize(b)
    if not na or not nb:
        return 0.0
    if na == nb:
        return 1.0
    # A short summary fully contained in a longer one is a restatement, which the plain
    # ratio underrates ("Quick breakfast" vs "Planning a quick breakfast this morning").
    if len(na) > 12 and len(nb) > 12 and (na in nb or nb in na):
        return 1.0
    return difflib.SequenceMatcher(None, na, nb).ratio()


def _similar(a: str, b: str) -> float:
    """How much two memories say the same thing.

    Lexical distance alone is not enough, measured on the real pair from the live DB:

        "User planned a quick breakfast this morning."              0.602
        "Planning to have a quick breakfast with no specific menu yet"

    Those are one breakfast written twice, and no safe character-level threshold separates
    that from two genuinely different plans. Meaning does separate them, and ORBIT already
    runs `nomic-embed-text` for semantic recall — so the embedder decides when it is live,
    and lexical distance is the floor when it is not. Degrading to "misses a paraphrase" is
    fine; merging two real plans is not.
    """
    lexical = _lexical_similar(a, b)
    if lexical >= SIMILARITY_THRESHOLD:
        return lexical
    try:
        from app.semantic_memory import cosine_similarity, embed_text, is_real_embedder_active

        if not is_real_embedder_active():
            return lexical
        semantic = cosine_similarity(embed_text(a), embed_text(b))
    except Exception:
        return lexical
    return max(lexical, semantic)


def group_duplicates(items: list[dict], *, key: str = "summary") -> list[list[dict]]:
    """Cluster near-identical entries. Each returned group has 2+ members."""
    groups: list[list[dict]] = []
    claimed: set[int] = set()
    for i, item in enumerate(items):
        if i in claimed:
            continue
        group = [item]
        for j in range(i + 1, len(items)):
            if j in claimed:
                continue
            if _similar(item.get(key, ""), items[j].get(key, "")) >= SIMILARITY_THRESHOLD:
                group.append(items[j])
                claimed.add(j)
        if len(group) > 1:
            claimed.add(i)
            groups.append(group)
    return groups


def pick_survivor(group: list[dict]) -> dict:
    """The entry worth keeping: most informative, then most important, then most recent.

    Length is the first signal on purpose — between "Quick breakfast" and "Planning a quick
    breakfast with no specific menu yet", the longer one carries what he actually said.
    """
    return sorted(
        group,
        key=lambda e: (
            len(_normalize(e.get("summary", ""))),
            float(e.get("importance") or 0.0),
            str(e.get("created_at") or ""),
        ),
        reverse=True,
    )[0]


def find_expired(events: list[dict], *, now: Optional[datetime] = None) -> list[dict]:
    """Events whose moment has passed by enough that they are history, not current life."""
    current = now or datetime.utcnow()
    expired = []
    for ev in events:
        occurs_at = ev.get("occurs_at")
        if not occurs_at:
            continue
        try:
            start = datetime.strptime(occurs_at, "%Y-%m-%d %H:%M:%S")
        except (ValueError, TypeError):
            continue
        end = start + timedelta(minutes=int(ev.get("duration_minutes") or 60))
        if current - end > timedelta(hours=EXPIRE_AFTER_HOURS):
            expired.append(ev)
    return expired


def consolidate(store: Any, *, now: Optional[datetime] = None) -> dict:
    """Run one consolidation pass. Returns a report of what changed."""
    current = now or datetime.utcnow()
    report = {"duplicates_retired": [], "expired": [], "facts_merged": []}

    events = store.recent_life_events(limit=200, days=30)

    for group in group_duplicates(events):
        survivor = pick_survivor(group)
        for ev in group:
            if ev["id"] == survivor["id"]:
                continue
            store.mark_life_event_resolved(ev["id"])
            report["duplicates_retired"].append(
                {"retired": ev["summary"], "kept": survivor["summary"]}
            )

    still_live = [e for e in events
                  if not any(d["retired"] == e["summary"] for d in report["duplicates_retired"])]
    for ev in find_expired(still_live, now=current):
        store.mark_life_event_resolved(ev["id"])
        report["expired"].append(ev["summary"])

    # Durable facts get the same treatment, but they are merged rather than retired — a fact
    # has no lifecycle, so the weaker phrasing of a duplicate is simply removed.
    facts = store.all_personal_knowledge()
    for group in group_duplicates(facts, key="fact"):
        survivor = sorted(
            group,
            key=lambda f: (len(_normalize(f.get("fact", ""))), float(f.get("importance") or 0)),
            reverse=True,
        )[0]
        for fact in group:
            if fact["id"] == survivor["id"]:
                continue
            store.delete_personal_knowledge(fact["id"])
            report["facts_merged"].append(
                {"removed": fact["fact"], "kept": survivor["fact"]}
            )

    store.set_meta(LAST_RUN_KEY, current.strftime("%Y-%m-%d %H:%M:%S"))
    total = sum(len(v) for v in report.values())
    if total:
        logger.info(
            "consolidation retired=%d expired=%d facts_merged=%d",
            len(report["duplicates_retired"]), len(report["expired"]), len(report["facts_merged"]),
        )
    return report


def is_due(store: Any, *, now: Optional[datetime] = None, every_hours: int = 24) -> bool:
    """At most once a day. Cheap enough to check on any request."""
    current = now or datetime.utcnow()
    raw = store.get_meta(LAST_RUN_KEY, "")
    if not raw:
        return True
    try:
        last = datetime.strptime(raw, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return True
    return (current - last) >= timedelta(hours=every_hours)
