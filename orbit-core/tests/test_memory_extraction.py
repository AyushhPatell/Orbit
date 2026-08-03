"""
Guards on LLM memory extraction.

The model's output is untrusted input: it reaches long-term memory, so malformed categories,
essay-length "facts" and junk shapes must be dropped rather than stored. Also pins the cursor
rule — extraction must never back-fill old conversation, because a month-old "shift today at
4 PM" would be recorded as if it were happening now.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

import app.main as main
from app.memory_extraction import _clean_events, _clean_knowledge


def test_valid_knowledge_survives() -> None:
    cleaned = _clean_knowledge([
        {"category": "work", "fact": "Works as IT Support at Dalhousie University", "importance": 0.9},
        {"category": "routines", "fact": "Shift ends at 4:30 PM", "importance": 0.8},
    ])
    assert [c["fact"] for c in cleaned] == [
        "Works as IT Support at Dalhousie University",
        "Shift ends at 4:30 PM",
    ]


@pytest.mark.parametrize(
    "item",
    [
        {"category": "astrology", "fact": "Is a Leo", "importance": 0.9},   # invented category
        {"category": "work", "fact": "hi", "importance": 0.5},              # too short
        {"category": "work", "fact": "x" * 400, "importance": 0.5},         # essay
        {"fact": "No category at all", "importance": 0.5},
        "not even a dict",
    ],
)
def test_malformed_knowledge_is_dropped(item: object) -> None:
    assert _clean_knowledge([item]) == []


def test_importance_is_clamped_not_trusted() -> None:
    cleaned = _clean_knowledge([
        {"category": "work", "fact": "Works at Dalhousie", "importance": 99},
        {"category": "work", "fact": "Does a co-op at HRM", "importance": "high"},
    ])
    assert all(0.0 <= c["importance"] <= 1.0 for c in cleaned)


def test_event_enums_are_validated() -> None:
    cleaned = _clean_events([
        {"summary": "Meeting with professor at 2 PM", "category": "plan",
         "emotion": "ecstatic", "when": "someday", "importance": 0.7},
    ])
    assert cleaned[0]["emotion"] is None      # not a known emotion
    assert cleaned[0]["event_date"] is None   # not a known window


def test_output_volume_is_capped() -> None:
    many = [{"category": "work", "fact": f"Fact number {i} about work", "importance": 0.5} for i in range(40)]
    assert len(_clean_knowledge(many)) <= 8


@pytest.mark.asyncio
async def test_first_run_starts_from_now_and_never_backfills() -> None:
    """A fresh install must not mine months of history and file it as today."""
    with patch.object(main.memory, "get_meta", return_value=""), \
         patch.object(main.memory, "latest_turn_id", return_value=1188), \
         patch.object(main.memory, "set_meta") as set_meta, \
         patch.object(main.memory, "turns_after") as turns_after:
        stored = await main.run_memory_extraction("orbit-mac")

    assert stored == 0
    turns_after.assert_not_called()               # nothing read on the first pass
    set_meta.assert_called_once_with("extraction.last_turn_id", "1188")


@pytest.mark.asyncio
async def test_extraction_waits_for_enough_conversation() -> None:
    """One or two turns is not enough context to distil a durable fact from."""
    with patch.object(main.memory, "get_meta", return_value="100"), \
         patch.object(main.memory, "turns_after", return_value=[(101, "user", "hi")]), \
         patch.object(main, "memory_extraction") as mod:
        mod.CURSOR_KEY = "extraction.last_turn_id"
        mod.MIN_NEW_TURNS = 6
        mod.MAX_TURNS_PER_RUN = 30
        mod.extract_memories = AsyncMock()
        stored = await main.run_memory_extraction("orbit-mac")

    assert stored == 0
    mod.extract_memories.assert_not_awaited()
