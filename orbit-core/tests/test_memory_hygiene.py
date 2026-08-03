"""Memory hygiene (2026-08-03).

Two verified problems in the live DB:

1. Phase 3.6 introduced an LLM extractor to *replace* regex extraction, but never stopped
   the regex writers — both ran on every turn. All 16 personal_knowledge rows were regex
   ("I want to delete few reminders" filed under *goals*), zero were LLM. That junk is then
   fed back to the LLM as "already known, do not repeat", suppressing the clean version of
   the same fact.

2. The LLM breaks its own "record nothing from commands" instruction: "Turned off sleep
   mode and adjusted screen brightness to 50%" was stored as one of Ayush's life events.
   Prompting is not enforcement.
"""
from __future__ import annotations

from app.memory_extraction import _clean_events, is_tool_operation

# Verbatim from the live database on 2026-08-03.
REAL_TOOL_LOG_ENTRIES = [
    "Turned off sleep mode and adjusted screen brightness to 50%",
    "Reminders to buy tickets were set for next Tuesday; some reminders were deleted today.",
    "Spiderman movie ticket reminder is set for 5 PM today.",
    "Requested to delete a few reminders",
    "Deleted reminder to buy tickets for Spider-Man and set a new reminder",
]

REAL_LIFE_ENTRIES = [
    "User planned a quick breakfast this morning.",
    "Has an extra work shift from 4:00 PM to 7:30 PM today",
    "Has a 30-minute meeting with a professor at 2:00 PM to discuss a project",
    "Call scheduled with Kawan on Thursday at 2 PM",
    "Went to Montreal for a weekend vacation",
    "Feeling tired after a busy day at the co-op",
    "His friend Kawan is visiting",
]


def test_orbit_command_log_is_not_a_life_event() -> None:
    for summary in REAL_TOOL_LOG_ENTRIES:
        assert is_tool_operation(summary), summary


def test_real_life_survives_the_filter() -> None:
    for summary in REAL_LIFE_ENTRIES:
        assert not is_tool_operation(summary), summary


def test_device_actions_are_filtered() -> None:
    for summary in [
        "Wi-Fi was turned off",
        "Turned on dark mode",
        "Lowered the volume to 20%",
        "Opened Safari",
        "Locked the screen",
    ]:
        assert is_tool_operation(summary), summary


def test_calendar_plans_are_kept_deliberately() -> None:
    # A calendar commitment is a real plan worth remembering, even when the sentence
    # describing it came out of bookkeeping. Only ORBIT's own artefacts (reminders,
    # alarms, notes) are excluded — those live in their own apps and are read by tool.
    assert not is_tool_operation("Call with Kawan on Thursday at 2 PM")
    assert not is_tool_operation("Has a meeting with Priya on Thursday")


def test_clean_events_drops_tool_operations() -> None:
    events = _clean_events([
        {"summary": "Turned off sleep mode and adjusted brightness to 50%", "category": "plan"},
        {"summary": "Going to the gym after his shift", "category": "plan", "when": "today"},
        {"summary": "Set a reminder for 5 PM", "category": "plan"},
    ])
    assert len(events) == 1
    assert events[0]["summary"] == "Going to the gym after his shift"


def test_clean_events_still_validates_shape() -> None:
    events = _clean_events([
        {"summary": "ok", "category": "plan"},                      # too short
        {"summary": "x" * 400, "category": "plan"},                 # too long
        {"summary": "Had dinner with family", "category": "plan",
         "when": "yesterday", "emotion": "elated"},                 # invalid enums
    ])
    assert len(events) == 1
    assert events[0]["event_date"] is None
    assert events[0]["emotion"] is None
