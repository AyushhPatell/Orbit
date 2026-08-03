"""Test isolation — added 2026-08-03 after finding the suite writing to the real database.

`app.main` binds its MemoryStore at import time to `get_settings().db_path`, which resolves
to Ayush's live `data/orbit.db`. Several tests call endpoint functions directly
(`chat_tool_result`, …) and those endpoints save turns — so **every `pytest` run wrote 12
turns into his personal memory**, and had been doing so for months: 228 rows under the
`test-offline` session id were found in the live DB, alongside his 1184 real ones.

Proven by counting before and after a run, not by reading:

    turns BEFORE pytest: 1402
    turns AFTER  pytest: 1414

This fixture repoints the store at a throwaway file for the whole session. It is autouse and
session-scoped so no test can opt out by forgetting.
"""
from __future__ import annotations

import dataclasses
import tempfile
from pathlib import Path

import pytest

import app.main as main
from app.config import get_settings as real_get_settings
from app.memory import MemoryStore

# A second problem the isolation work exposed: five tests passed **only because Ayush's
# `.env` happened to exist**. `get_settings()` re-reads that file on every call and file
# values win over the environment, so on a clean checkout (or CI) `brain_api_key` was
# empty — `chat_tool_result` then raised 503 and `run_memory_extraction` returned early,
# and the offline-resilience tests never reached the code they claim to cover. Tests must
# not depend on a developer's secrets, so the suite pins its own settings.
TEST_BRAIN_KEY = "test-brain-key-not-a-real-secret"


@pytest.fixture(scope="session", autouse=True)
def isolate_memory_store():
    """Point app.main.memory at a temp DB, and pin settings, for the whole session."""
    tmpdir = tempfile.mkdtemp(prefix="orbit-tests-")
    db_path = Path(tmpdir) / "test-orbit.db"

    def settings_for_tests():
        base = real_get_settings()
        return dataclasses.replace(
            base,
            db_path=db_path,
            brain_api_key=TEST_BRAIN_KEY,
            cloud_api_key=base.cloud_api_key or TEST_BRAIN_KEY,
            chat_audit_log_path=None,
        )

    real_store = main.memory
    real_settings = main.get_settings
    main.memory = MemoryStore(db_path)
    main.get_settings = settings_for_tests
    try:
        yield main.memory
    finally:
        main.memory = real_store
        main.get_settings = real_settings


@pytest.fixture(autouse=True)
def guard_against_production_db(isolate_memory_store):
    """Fail loudly if anything re-binds the store to a real path mid-run."""
    yield
    current = str(getattr(main.memory, "db_path", ""))
    assert "orbit-tests-" in current or current == "", (
        f"A test repointed app.main.memory at {current!r} — tests must never touch the real DB."
    )
