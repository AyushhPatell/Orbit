"""Temporal labels — written after the 3 PM briefing case (2026-08-03).

Two verified lies in the old `_temporal_label`:
- "weekend"/"next-week" events fell through to PAST after a single day, so future
  plans were briefed as history;
- "today" stayed current until midnight, so a 10 AM breakfast plan was recited as
  "planning now" at 6 PM.

All datetimes here are UTC-naive to match SQLite CURRENT_TIMESTAMP.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from app.main import _age_phrase, _temporal_label

FMT = "%Y-%m-%d %H:%M:%S"
_anchor = datetime(2026, 8, 12, 15, 0, 0)
NOW = _anchor - timedelta(days=_anchor.weekday() - 2)  # a Wednesday, 15:00


def ev(event_date, days_ago=0, hours_ago=0, category="plan"):
    created = NOW - timedelta(days=days_ago, hours=hours_ago)
    return {"event_date": event_date, "created_at": created.strftime(FMT), "category": category}


def test_next_week_shared_yesterday_is_still_upcoming() -> None:
    # THE regression: one day after sharing, "next week" plans were labelled PAST.
    label = _temporal_label(ev("next-week", days_ago=1), 15, now=NOW)
    assert "PAST" not in label


def test_weekend_shared_yesterday_is_still_upcoming() -> None:
    # Shared Tuesday, checked Wednesday — Saturday has not happened yet.
    label = _temporal_label(ev("weekend", days_ago=1), 15, now=NOW)
    assert "PAST" not in label
    assert "UPCOMING" in label


def test_next_week_long_gone_is_past() -> None:
    assert "PAST" in _temporal_label(ev("next-week", days_ago=16), 15, now=NOW)


def test_today_morning_plan_is_likely_done_by_evening() -> None:
    # The breakfast case: shared in the morning, recited as current in the evening.
    label = _temporal_label(ev("today", hours_ago=8), 18, now=NOW)
    assert "LIKELY DONE" in label


def test_today_fresh_plan_is_current() -> None:
    label = _temporal_label(ev("today", hours_ago=1), 15, now=NOW)
    assert label.startswith("TODAY")


def test_today_shared_yesterday_is_past() -> None:
    assert "PAST" in _temporal_label(ev("today", days_ago=1), 15, now=NOW)


def test_tomorrow_shared_yesterday_is_today() -> None:
    assert _temporal_label(ev("tomorrow", days_ago=1), 15, now=NOW).startswith("TODAY")


def test_tomorrow_shared_today_is_upcoming() -> None:
    label = _temporal_label(ev("tomorrow", hours_ago=1), 15, now=NOW)
    assert "UPCOMING TOMORROW" in label


def test_undated_events_age_out() -> None:
    assert "PAST" in _temporal_label(ev(None, days_ago=2), 15, now=NOW)
    fresh = _temporal_label(ev(None, hours_ago=2, category="feeling"), 15, now=NOW)
    assert "CURRENT FEELING" in fresh


def test_age_phrase() -> None:
    assert _age_phrase((NOW - timedelta(minutes=20)).strftime(FMT), now=NOW) == "just now"
    assert _age_phrase((NOW - timedelta(hours=5)).strftime(FMT), now=NOW) == "5 hours ago"
    assert _age_phrase((NOW - timedelta(days=1, hours=2)).strftime(FMT), now=NOW) == "yesterday"
    assert _age_phrase((NOW - timedelta(days=3)).strftime(FMT), now=NOW) == "3 days ago"
