"""Memory provenance (M9, 2026-08-03) — a guest's words are never facts about Ayush.

A microphone cannot tell who spoke. When someone else is in the room, everything it hears
still lands in the same transcript — and that is how *"Meet my friend Shruti she's
listening"* ended up stored as a fact about Ayush's relationships.

The rule is enforced in code, not asked of the model: turns captured with company present are
excluded from personal-knowledge extraction. Life events still come through, because the
situation is real either way. If something really is a fact about him, he will say it again
when it is just the two of them.
"""
from __future__ import annotations

import json


def test_turn_context_is_recorded(isolate_memory_store) -> None:
    store = isolate_memory_store
    store.append_turn("s", "user", "my friend Shruti is here", context="company")
    store.append_turn("s", "user", "turn off the wifi", context="alone")

    tagged = store.turns_after_with_context("s", 0)
    assert [t[3] for t in tagged] == ["company", "alone"]


def test_context_defaults_to_alone(isolate_memory_store) -> None:
    """Existing rows predate the column; they must not be mistaken for company turns."""
    store = isolate_memory_store
    store.append_turn("s", "user", "hello")
    assert store.turns_after_with_context("s", 0)[0][3] == "alone"


def test_company_turns_are_identifiable_for_exclusion(isolate_memory_store) -> None:
    store = isolate_memory_store
    store.append_turn("s", "user", "alone thing", context="alone")
    store.append_turn("s", "user", "guest thing", context="company")
    store.append_turn("s", "user", "another alone thing", context="alone")

    tagged = store.turns_after_with_context("s", 0)
    company_ids = {tid for tid, _, _, ctx in tagged if ctx != "alone"}
    knowledge_turns = [t for t in tagged if t[0] not in company_ids]

    assert len(company_ids) == 1
    assert [t[2] for t in knowledge_turns] == ["alone thing", "another alone thing"]


def test_provenance_round_trips_on_knowledge(isolate_memory_store) -> None:
    store = isolate_memory_store
    prov = json.dumps({"source": "llm-extraction", "turns": "10-20", "context": "alone"})
    store.add_personal_knowledge("work", "Works at Dalhousie", 0.9, "llm-extraction", provenance=prov)

    rows = store.all_personal_knowledge()
    assert len(rows) == 1
    stored = store._connect().execute(
        "SELECT provenance FROM personal_knowledge WHERE id = ?", (rows[0]["id"],)
    ).fetchone()[0]
    assert json.loads(stored)["turns"] == "10-20"


def test_provenance_round_trips_on_life_events(isolate_memory_store) -> None:
    store = isolate_memory_store
    prov = json.dumps({"source": "llm-extraction", "context": "company"})
    store.add_life_event("Had dinner with friends", category="plan", provenance=prov)

    row = store._connect().execute(
        "SELECT provenance FROM life_events ORDER BY id DESC LIMIT 1"
    ).fetchone()[0]
    assert json.loads(row)["context"] == "company"


def test_a_memory_without_provenance_is_still_valid(isolate_memory_store) -> None:
    """Everything written before this existed must keep working."""
    store = isolate_memory_store
    store.add_personal_knowledge("work", "An older fact", 0.5, "curated")
    assert len(store.all_personal_knowledge()) == 1
