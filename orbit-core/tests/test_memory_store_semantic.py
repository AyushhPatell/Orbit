from __future__ import annotations

from app.memory import MemoryStore


def test_semantic_memory_list_and_delete(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    mem.add_semantic_memory("I prefer short bullet plans.", source="auto")
    mem.add_semantic_memory("We are building ORBIT.", source="auto")

    rows = mem.list_semantic_records(limit=10)
    assert len(rows) >= 2
    first_id = rows[0][0]
    assert mem.delete_semantic_memory(first_id) is True


def test_semantic_memory_clear_all(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    mem.add_semantic_memory("Memory A", source="auto")
    mem.add_semantic_memory("Memory B", source="auto")
    deleted = mem.clear_semantic_memory()
    assert deleted >= 2
    assert mem.list_semantic_records(limit=10) == []


def test_semantic_memory_prune_overflow(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    for i in range(8):
        mem.add_semantic_memory(f"Memory {i}", source="auto")
    deleted = mem.prune_semantic_memory(retention_days=365, max_items=5)
    assert deleted >= 3
    assert len(mem.list_semantic_records(limit=20)) == 5


def test_semantic_search_prefers_higher_importance(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    text = "I prefer concise bullet summaries for planning."
    mem.add_semantic_memory(text, source="auto", importance=0.25)
    # Upsert same text with higher importance should preserve stronger score.
    mem.add_semantic_memory(text, source="manual", importance=0.95)
    hits = mem.semantic_search("prefer concise summaries", limit=1, min_score=0.3)
    assert hits
    rows = mem.list_semantic_records(limit=5)
    assert any(r[1] == text and r[3] >= 0.95 for r in rows)


def test_set_semantic_memory_importance(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    mem.add_semantic_memory("Tune this", source="manual", importance=0.6)
    row = mem.list_semantic_records(limit=1)[0]
    assert mem.set_semantic_memory_importance(row[0], 0.85) is True
    updated = mem.list_semantic_records(limit=1)[0]
    assert updated[3] == 0.85


def test_semantic_memory_conflict_replaces_old(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    sig = "pref:study-style"
    mem.add_semantic_memory("I prefer long essays.", source="auto", importance=0.6, conflict_sig=sig)
    mem.add_semantic_memory("I prefer concise bullets.", source="auto", importance=0.8, conflict_sig=sig)
    rows = mem.list_semantic_records(limit=10)
    texts = [r[1] for r in rows]
    assert "I prefer concise bullets." in texts
    assert "I prefer long essays." not in texts


def test_semantic_memory_stats(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    mem.append_turn("s", "user", "hello")
    mem.add_fact("fact one")
    mem.add_semantic_memory("manual memory", source="manual", importance=0.9)
    stats = mem.semantic_memory_stats()
    assert stats["turns"] == 1
    assert stats["facts"] == 1
    assert stats["semantic_total"] >= 1


def test_style_preferences_persist_and_clamp(tmp_path) -> None:
    db_path = tmp_path / "orbit.db"
    mem = MemoryStore(db_path)
    mem.bump_style_preference("pref_concise", 0.4)
    mem.bump_style_preference("pref_concise", 0.9)  # should clamp at 1.0
    mem.bump_style_preference("avoid_followups", -1.5)  # should clamp at -1.0
    prefs = mem.style_preferences()
    assert prefs["pref_concise"] == 1.0
    assert prefs["avoid_followups"] == -1.0
