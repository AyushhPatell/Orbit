from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest

from app.device_time import daypart_for_local_hour, device_clock_prompt_block


@pytest.fixture
def patched_memory(monkeypatch: pytest.MonkeyPatch) -> None:
    import app.main as main_mod

    mock_mem = MagicMock()
    mock_mem.recent_facts.return_value = []
    mock_mem.recent_turns.return_value = []
    mock_mem.semantic_search.return_value = []
    mock_mem.get_core_profile.return_value = {}
    mock_mem.search_personal_knowledge.return_value = []
    mock_mem.recent_life_events.return_value = []
    mock_mem.mood_trend.return_value = {"count": 0, "trend": "neutral", "recent_emotions": []}
    mock_mem.recent_daily_summaries.return_value = []
    # _generate_pending_summaries runs inside build_messages; True short-circuits it
    # before it touches turns_for_date/life_events_for_date.
    mock_mem.has_summary_for_date.return_value = True
    monkeypatch.setattr(main_mod, "memory", mock_mem)


def test_build_messages_includes_device_clock_when_provided(
    patched_memory: None, tmp_path: Path
) -> None:
    import app.main as main_mod

    profile = tmp_path / "user_profile.md"
    profile.write_text("You are ORBIT.", encoding="utf-8")
    msgs = main_mod.build_messages(
        "session",
        "Hello",
        profile,
        route="local",
        client_local_iso="2026-04-20T22:56:00-03:00",
        client_tz="America/Halifax",
    )
    system = msgs[0].content
    assert "### Device time" in system
    assert "22:56" in system
    assert "America/Halifax" in system
    assert "Greeting daypart" in system
    assert "night" in system  # hour 22 → night


def test_build_messages_omits_device_clock_when_partial(
    patched_memory: None, tmp_path: Path
) -> None:
    import app.main as main_mod

    profile = tmp_path / "user_profile.md"
    profile.write_text("You are ORBIT.", encoding="utf-8")
    msgs = main_mod.build_messages(
        "session",
        "Hello",
        profile,
        route="local",
        client_local_iso="2026-04-20T22:56:00-03:00",
        client_tz="",
    )
    assert "### Device time" not in msgs[0].content


def test_daypart_boundaries() -> None:
    assert daypart_for_local_hour(5) == "morning"
    assert daypart_for_local_hour(11) == "morning"
    assert daypart_for_local_hour(12) == "afternoon"
    assert daypart_for_local_hour(16) == "afternoon"
    assert daypart_for_local_hour(17) == "evening"
    assert daypart_for_local_hour(21) == "evening"
    assert daypart_for_local_hour(22) == "night"
    assert daypart_for_local_hour(4) == "night"


def test_device_clock_prompt_evening() -> None:
    block = device_clock_prompt_block("2026-04-18T19:30:00-03:00", "America/Halifax")
    assert block is not None
    assert "**evening**" in block
    assert "19:30" in block
    assert "America/Halifax" in block
    assert "Do not" in block


def test_device_clock_prompt_empty_tz() -> None:
    assert device_clock_prompt_block("2026-04-18T19:30:00-03:00", "") is None
