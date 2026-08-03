from __future__ import annotations

from app.semantic_memory import (
    _embed_hash,
    conflict_signature,
    embed_text,
    extract_candidate_memories,
    extract_scored_candidate_memories,
    score_memory_candidate,
)


def test_hash_embedding_is_deterministic_and_fixed_width() -> None:
    """The offline fallback used when no embedding service is reachable."""
    a = _embed_hash("I prefer evening study sessions")
    b = _embed_hash("I prefer evening study sessions")
    assert a == b
    assert len(a) == 192


def test_embed_text_returns_a_usable_vector() -> None:
    """
    Provider-agnostic on purpose: real embeddings when Ollama is reachable, hash otherwise.

    This previously asserted 192 dimensions, which silently also asserted "no real embedder is
    configured" — so it broke the moment embeddings actually started working.
    """
    vector = embed_text("I prefer evening study sessions")
    assert len(vector) > 0
    assert all(isinstance(value, float) for value in vector)


def test_extract_candidate_memories_filters_questions() -> None:
    msg = (
        "I prefer dark mode and short bullet plans. "
        "My classes are usually in the afternoon. "
        "Do you remember this?"
    )
    items = extract_candidate_memories(msg)
    assert any("prefer dark mode" in x.lower() for x in items)
    assert any("usually in the afternoon" in x.lower() for x in items)
    assert all(not x.endswith("?") for x in items)


def test_score_memory_candidate_strong_vs_weak() -> None:
    strong = score_memory_candidate("I prefer dark mode and concise bullet summaries.")
    weak = score_memory_candidate("maybe today we can see later")
    assert strong > weak
    assert 0.0 <= strong <= 1.0


def test_extract_scored_candidate_memories() -> None:
    msg = "I prefer dark mode. I like short answers."
    items = extract_scored_candidate_memories(msg)
    assert items
    assert items[0][0]
    assert isinstance(items[0][1], float)


def test_conflict_signature() -> None:
    a = conflict_signature("I prefer short bullet plans")
    b = conflict_signature("I don't like short bullet plans")
    assert a is not None
    assert a == b
