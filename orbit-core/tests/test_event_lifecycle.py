"""Event lifecycle (M3, 2026-08-03) — planned → happening → just finished → past.

Coarse day labels ("today") cannot tell 4 PM from 9 PM, so ORBIT either spoke of a
finished thing as still upcoming, or would have asked "how did it go?" about something
hours away. When the user names a clock time, the resolved instant is stored and the
event is phased against it.

The anchor case is real: "Spiderman movie ticket reminder is set for 5 PM today", which
on 2026-08-02 was recited at 3 PM as a current plan.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.main import _lifecycle_phase, _resolve_occurs_at, _temporal_label
from app.memory_extraction import _clean_events

FMT = "%Y-%m-%d %H:%M:%S"


def _utc(dt: datetime) -> str:
    return dt.strftime(FMT)


def _movie_at_five(now_local_hour: int) -> tuple[str, datetime]:
    """The 5 PM movie, and a UTC 'now' at the given local hour on the same day."""
    created_local = datetime.now().astimezone().replace(
        hour=9, minute=0, second=0, microsecond=0
    )
    created_utc = created_local.astimezone(timezone.utc).replace(tzinfo=None)
    occurs_at = _resolve_occurs_at("today", "17:00", created=created_utc)
    now_local = created_local.replace(hour=now_local_hour)
    return occurs_at, now_local.astimezone(timezone.utc).replace(tzinfo=None)


def test_clock_time_resolves_to_an_instant() -> None:
    occurs_at, _ = _movie_at_five(15)
    assert occurs_at is not None
    # Round-trips back to 17:00 in the user's own timezone.
    parsed = datetime.strptime(occurs_at, FMT).replace(tzinfo=timezone.utc)
    assert parsed.astimezone().hour == 17


def test_no_clock_time_means_no_instant() -> None:
    # Never invent an hour — the same rule reminders learned in Phase 3.10.
    assert _resolve_occurs_at("today", None) is None
    assert _resolve_occurs_at("tomorrow", "") is None


def test_the_movie_is_upcoming_at_three_pm() -> None:
    """The exact failure: at 3 PM the 5 PM movie was spoken of as a current plan."""
    occurs_at, now = _movie_at_five(15)
    phase = _lifecycle_phase(occurs_at, duration_minutes=150, now=now)
    assert "UPCOMING" in phase
    assert "NOT happened yet" in phase


def test_the_movie_is_happening_at_six_pm() -> None:
    occurs_at, now = _movie_at_five(18)
    assert _lifecycle_phase(occurs_at, duration_minutes=150, now=now) == "HAPPENING RIGHT NOW"


def test_the_movie_is_worth_asking_about_at_nine_pm() -> None:
    occurs_at, now = _movie_at_five(21)
    phase = _lifecycle_phase(occurs_at, duration_minutes=150, now=now)
    assert "JUST FINISHED" in phase


def test_starting_soon_is_its_own_phase() -> None:
    occurs_at, now = _movie_at_five(16)
    assert _lifecycle_phase(occurs_at, duration_minutes=150, now=now) == "STARTING SOON"


def test_an_instant_overrides_the_coarse_day_label() -> None:
    occurs_at, now = _movie_at_five(15)
    event = {
        "event_date": "today",
        "created_at": _utc(now - timedelta(hours=6)),
        "occurs_at": occurs_at,
        "duration_minutes": 150,
        "category": "plan",
    }
    # Without the instant, six hours of age alone would read as "LIKELY DONE".
    assert "UPCOMING" in _temporal_label(event, 15, now=now)
    assert "LIKELY DONE" not in _temporal_label(event, 15, now=now)


def test_events_without_a_time_still_use_day_labels() -> None:
    now = datetime(2026, 8, 12, 18, 0, 0)
    event = {
        "event_date": "today",
        "created_at": _utc(now - timedelta(hours=8)),
        "occurs_at": None,
        "category": "routine",
    }
    assert "LIKELY DONE" in _temporal_label(event, 18, now=now)


def test_extractor_validates_clock_times() -> None:
    events = _clean_events([
        {"summary": "Seeing the Spiderman movie", "when": "today", "at": "17:00",
         "duration_minutes": 150, "category": "plan"},
        {"summary": "Coffee with a friend", "when": "today", "at": "25:99", "category": "plan"},
        {"summary": "Gym session sometime later", "when": "today", "at": None, "category": "plan"},
    ])
    assert events[0]["at"] == "17:00"
    assert events[0]["duration_minutes"] == 150
    assert events[1]["at"] is None          # nonsense clock time rejected
    assert events[2]["at"] is None
    assert events[2]["duration_minutes"] == 60   # sane default


def test_duration_is_clamped() -> None:
    events = _clean_events([
        {"summary": "Something absurdly long", "category": "plan", "duration_minutes": 99999},
        {"summary": "Something instantaneous", "category": "plan", "duration_minutes": 0},
    ])
    assert events[0]["duration_minutes"] == 12 * 60
    assert events[1]["duration_minutes"] == 5


def test_duration_survives_the_round_trip(isolate_memory_store) -> None:
    """A 150-minute film must still be 'happening' an hour after a 60-minute default
    would have called it finished — so the duration has to reach the database."""
    store = isolate_memory_store
    occurs_at, now = _movie_at_five(15)
    store.add_life_event(
        "Seeing the Spiderman movie",
        category="plan",
        event_date="today",
        occurs_at=occurs_at,
        duration_minutes=150,
    )
    stored = [e for e in store.recent_life_events(limit=5, days=3)
              if e["summary"] == "Seeing the Spiderman movie"]
    assert stored, "event was not stored"
    assert stored[0]["duration_minutes"] == 150
    assert stored[0]["occurs_at"] == occurs_at

    _, at_six_thirty = _movie_at_five(18)
    assert _temporal_label(stored[0], 18, now=at_six_thirty) == "HAPPENING RIGHT NOW"


def test_resolved_events_leave_the_recall_window(isolate_memory_store) -> None:
    """is_resolved existed from the first schema and was never written, so a topic ORBIT
    had already followed up on could resurface forever."""
    store = isolate_memory_store
    store.add_life_event("Went to the dentist", category="plan", event_date="today")
    match = [e for e in store.recent_life_events(limit=20, days=3)
             if e["summary"] == "Went to the dentist"]
    assert match
    store.mark_life_event_resolved(match[0]["id"])
    assert not [e for e in store.recent_life_events(limit=20, days=3)
                if e["summary"] == "Went to the dentist"]
