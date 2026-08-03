"""Memory consolidation — the sleep cycle (M7, 2026-08-03).

Anchored on the real duplicate clusters found in the live DB before the cleanup: three
near-identical Spider-Man entries and three Kan/Kawan entries, all live in the recall
window at once, so one plan looked like several.

Nothing is deleted — duplicates and finished events are marked `is_resolved`, which is
what that column is for.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from app.memory_consolidation import (
    consolidate,
    find_expired,
    group_duplicates,
    is_due,
    pick_survivor,
)

FMT = "%Y-%m-%d %H:%M:%S"
NOW = datetime(2026, 8, 12, 15, 0, 0)


def _ev(id_, summary, importance=0.5, days_ago=0, occurs_at=None, duration=60):
    return {
        "id": id_,
        "summary": summary,
        "importance": importance,
        "created_at": (NOW - timedelta(days=days_ago)).strftime(FMT),
        "occurs_at": occurs_at,
        "duration_minutes": duration,
    }


def test_near_identical_restatements_group_lexically() -> None:
    """No embedder needed: one is contained in the other, or nearly so."""
    events = [
        _ev(1, "Planning to have a quick breakfast"),
        _ev(2, "Planning to have a quick breakfast with no specific menu yet"),
        _ev(3, "Going to the gym after his shift"),
    ]
    groups = group_duplicates(events)
    assert len(groups) == 1
    assert {e["id"] for e in groups[0]} == {1, 2}


def test_paraphrases_need_the_embedder(monkeypatch) -> None:
    """The real pair from the live DB scores only 0.602 on characters — the two sentences
    say the same thing in different words. Lexically it must NOT group (merging on a guess
    that weak would fuse real distinct plans); with meaning available, it must."""
    import app.semantic_memory as sm

    a = "User planned a quick breakfast this morning."
    b = "Planning to have a quick breakfast with no specific menu yet"

    assert group_duplicates([_ev(1, a), _ev(2, b)]) == []

    vectors = {a: [1.0, 0.0, 0.0], b: [0.97, 0.24, 0.0], "Going to the gym": [0.0, 0.0, 1.0]}
    monkeypatch.setattr(sm, "is_real_embedder_active", lambda: True)
    monkeypatch.setattr(sm, "embed_text", lambda t, **kw: vectors.get(t, [0.0, 1.0, 0.0]))

    groups = group_duplicates([_ev(1, a), _ev(2, b), _ev(3, "Going to the gym")])
    assert len(groups) == 1
    assert {e["id"] for e in groups[0]} == {1, 2}


def test_cosine_is_a_real_cosine() -> None:
    """It was a bare dot product, so unnormalised `nomic-embed-text` vectors scored ~150-350
    and every memory cleared the 0.6 relevance gate in semantic_search."""
    from app.semantic_memory import cosine_similarity

    assert cosine_similarity([3.0, 0.0], [5.0, 0.0]) == 1.0
    assert cosine_similarity([1.0, 0.0], [0.0, 1.0]) == 0.0
    assert abs(cosine_similarity([20.0, 20.0], [1.0, 1.0]) - 1.0) < 1e-9
    assert cosine_similarity([0.0, 0.0], [1.0, 1.0]) == 0.0


def test_distinct_plans_are_not_merged() -> None:
    events = [
        _ev(1, "Call scheduled with Kawan on Thursday at 2 PM"),
        _ev(2, "Has a meeting with a professor at 2 PM to discuss a project"),
        _ev(3, "Going to the gym after his shift"),
        _ev(4, "Feeling tired after a busy day at the co-op"),
    ]
    assert group_duplicates(events) == []


def test_survivor_keeps_the_most_informative_wording() -> None:
    group = [
        _ev(1, "Quick breakfast", importance=0.9),
        _ev(2, "Planning to have a quick breakfast with no specific menu yet", importance=0.4),
    ]
    assert pick_survivor(group)["id"] == 2


def test_finished_events_expire() -> None:
    long_done = (NOW - timedelta(hours=48)).strftime(FMT)
    just_done = (NOW - timedelta(hours=2)).strftime(FMT)
    upcoming = (NOW + timedelta(hours=3)).strftime(FMT)
    events = [
        _ev(1, "Saw the movie", occurs_at=long_done, duration=150),
        _ev(2, "Coffee with a friend", occurs_at=just_done),
        _ev(3, "Dentist appointment", occurs_at=upcoming),
        _ev(4, "Something with no time at all"),
    ]
    expired_ids = {e["id"] for e in find_expired(events, now=NOW)}
    assert expired_ids == {1}


def test_consolidate_retires_duplicates_and_expiries(isolate_memory_store) -> None:
    store = isolate_memory_store
    store.add_life_event("Consolidation test: quick breakfast this morning", event_date="today")
    store.add_life_event("Consolidation test: quick breakfast this morning", event_date="today")
    store.add_life_event(
        "Consolidation test: the film screening",
        occurs_at=(NOW - timedelta(hours=72)).strftime(FMT),
        duration_minutes=150,
    )

    def mine():
        return [e for e in store.recent_life_events(limit=100, days=30)
                if e["summary"].startswith("Consolidation test:")]

    assert len(mine()) == 3
    report = consolidate(store, now=NOW)
    remaining = mine()

    assert len(report["duplicates_retired"]) == 1
    assert len(remaining) == 1
    assert "breakfast" in remaining[0]["summary"]


def test_write_time_dedupe_already_handles_same_category(isolate_memory_store) -> None:
    """`add_personal_knowledge` compares against existing facts, so consolidation is a
    safety net here, not the first line of defence."""
    store = isolate_memory_store
    store.add_personal_knowledge("work", "Works as IT Support at Dalhousie", 0.9, "test")
    store.add_personal_knowledge("work", "Works as IT Support at Dalhousie University", 0.6, "test")
    assert len(store.all_personal_knowledge()) == 1


def test_consolidate_merges_facts_filed_under_different_categories(isolate_memory_store) -> None:
    """The gap write-time dedupe leaves: it only looks *within* a category, so the same
    fact filed as `work` and again as `identity` survives twice."""
    store = isolate_memory_store
    store.add_personal_knowledge("work", "Works as IT Support at Dalhousie", 0.9, "test")
    store.add_personal_knowledge("identity", "Works as IT Support at Dalhousie University", 0.6, "test")
    assert len(store.all_personal_knowledge()) == 2

    report = consolidate(store, now=NOW)

    assert len(report["facts_merged"]) == 1
    kept = [f["fact"] for f in store.all_personal_knowledge()]
    assert kept == ["Works as IT Support at Dalhousie University"]


def test_is_due_respects_the_daily_cadence(isolate_memory_store) -> None:
    store = isolate_memory_store
    assert is_due(store, now=NOW)                      # never run
    consolidate(store, now=NOW)
    assert not is_due(store, now=NOW + timedelta(hours=3))
    assert is_due(store, now=NOW + timedelta(hours=25))


def test_corrupt_timestamp_does_not_block_the_pass(isolate_memory_store) -> None:
    store = isolate_memory_store
    store.set_meta("consolidation.last_run", "not-a-date")
    assert is_due(store, now=NOW)
