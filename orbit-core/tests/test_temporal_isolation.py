"""Cross-day bleed (2026-08-03) — the failure that prompted the memory-architecture pass.

Ayush asked "what do you know about today" and got:

    "You worked your co-op shift earlier today from 8:30 to 4:30, planned a quick breakfast
     this morning, and had reminders about calling Shreel which are now all done."

Only the Shreel part was true. The shift came from a ROUTINE fact (a pattern, not a record of
today). The breakfast was from YESTERDAY.

The critical detail: `_temporal_label` had already labelled that breakfast `PAST (yesterday)`
and the prompt already said not to speak of PAST things as current. **The label was right and
the model ignored it.** Labelling is not enforcement — a previous day's event must not reach
the prompt at all.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from app.main import _is_finished_label, _is_from_a_previous_day, _temporal_label

FMT = "%Y-%m-%d %H:%M:%S"
NOW = datetime(2026, 8, 12, 20, 0, 0)


def _event(days_ago: float, event_date="today", category="routine"):
    return {
        "event_date": event_date,
        "created_at": (NOW - timedelta(days=days_ago)).strftime(FMT),
        "occurs_at": None,
        "category": category,
    }


def test_yesterdays_event_is_excluded_from_todays_context() -> None:
    """The breakfast, verbatim: said yesterday with event_date='today'."""
    label = _temporal_label(_event(1), 20, now=NOW)
    assert "PAST" in label
    assert _is_from_a_previous_day(label), label


def test_todays_finished_event_stays_in_context() -> None:
    """"You called Shreel earlier" is true and worth having — only cross-day bleed is the bug."""
    label = _temporal_label(_event(0.4), 20, now=NOW)
    assert not _is_from_a_previous_day(label), label


def test_todays_morning_routine_stays_but_is_marked_done() -> None:
    label = _temporal_label(_event(0.5), 20, now=NOW)
    assert not _is_from_a_previous_day(label), label
    assert _is_finished_label(label), label      # available for a follow-up


def test_older_events_are_excluded() -> None:
    for days in (2, 3):
        label = _temporal_label(_event(days), 20, now=NOW)
        assert _is_from_a_previous_day(label), (days, label)


def test_upcoming_events_are_never_excluded() -> None:
    label = _temporal_label(_event(0, event_date="tomorrow"), 20, now=NOW)
    assert not _is_from_a_previous_day(label), label
    assert not _is_finished_label(label), label


def test_finished_and_previous_day_are_different_questions() -> None:
    """A finished event is follow-up material; a previous-day event is history. Conflating
    them either loses today's context or lets yesterday's leak in."""
    finished_today = _temporal_label(_event(0.5), 20, now=NOW)
    assert _is_finished_label(finished_today) and not _is_from_a_previous_day(finished_today)

    yesterday = _temporal_label(_event(1), 20, now=NOW)
    assert _is_finished_label(yesterday) and _is_from_a_previous_day(yesterday)
