from __future__ import annotations

import json
from typing import Any, Optional

import httpx

from app.models import Message

# ── Tool schemas (OpenAI function-calling format) ─────────────────────────────

ORBIT_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "create_calendar_event",
            "description": (
                "Create a new event in Apple Calendar. "
                "Use when the user wants to schedule a meeting, appointment, or any timed event "
                "AND they have already confirmed they want it created (after your confirmation step). "
                "Requires a title and start time."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "Event title, e.g. 'Meeting with Priya', 'Dentist appointment'.",
                    },
                    "start": {
                        "type": "string",
                        "description": "Start date-time in ISO 8601, e.g. '2026-06-18T15:00:00'. Use the user's local time.",
                    },
                    "duration_minutes": {
                        "type": "integer",
                        "description": "Duration in minutes. Default 60 if not specified.",
                    },
                    "notes": {
                        "type": "string",
                        "description": "Optional notes to attach to the event.",
                    },
                    "recurrence": {
                        "type": "string",
                        "enum": ["daily", "weekly", "biweekly", "monthly", "yearly"],
                        "description": (
                            "How often the event repeats. Omit for one-time events. "
                            "Use 'weekly' for 'every week / every Monday', "
                            "'daily' for 'every day', 'biweekly' for 'every two weeks', "
                            "'monthly' for 'every month', 'yearly' for 'every year'."
                        ),
                    },
                },
                "required": ["title", "start"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_calendar_events",
            "description": (
                "List the user's upcoming events from Apple Calendar. "
                "Use when the user asks about upcoming events, what's on their calendar, "
                "their schedule, or anything about calendar events. "
                "Do NOT use list_reminders for this — calendar events and reminders are separate."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_reminders",
            "description": (
                "List the user's upcoming incomplete reminders from Apple Reminders (the to-do list app). "
                "Use ONLY when the user specifically asks about reminders or to-do items. "
                "Do NOT use this for calendar event queries — use list_calendar_events for those."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_reminder",
            "description": "Create a new reminder in Apple Reminders on the user's Mac.",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "What to remind the user about.",
                    },
                    "due_date": {
                        "type": "string",
                        "description": (
                            "ISO 8601 local date-time, e.g. '2025-06-20T09:00:00'. "
                            "Omit if no specific time was mentioned."
                        ),
                    },
                },
                "required": ["title"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_reminder",
            "description": (
                "Delete a reminder from Apple Reminders. "
                "Use when the user says a reminder should be removed, deleted, is no longer needed, "
                "is outdated, was in the past, or they already handled it."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": (
                            "The reminder title or a distinctive keyword. "
                            "Use the exact title when you can see it from context."
                        ),
                    }
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "complete_reminder",
            "description": "Mark a reminder as done/completed in Apple Reminders.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The reminder title or a distinctive keyword.",
                    }
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_note",
            "description": (
                "Create a new note in Apple Notes. "
                "Use when the user wants to save information, jot something down, "
                "take a note, or remember something in writing. "
                "Do NOT use for time-sensitive reminders — use create_reminder for those."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "body": {
                        "type": "string",
                        "description": "The note content to save.",
                    },
                    "title": {
                        "type": "string",
                        "description": (
                            "Optional title. If omitted, Apple Notes uses the first line of the body."
                        ),
                    },
                },
                "required": ["body"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "append_note",
            "description": (
                "Append content to an existing Apple Notes note. "
                "Use when the user wants to add more to a note they already created. "
                "Requires the exact title of the existing note."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "Exact title of the existing note to append to.",
                    },
                    "content": {
                        "type": "string",
                        "description": "Content to add to the note.",
                    },
                },
                "required": ["title", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_calendar_event",
            "description": (
                "Delete an event from Apple Calendar (the Calendar app — scheduled events with date/time). "
                "Use when the user asks to remove, cancel, or delete a calendar event. "
                "This is NOT for Apple Reminders (to-do items) — use delete_reminder for those."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": (
                            "The event title or a distinctive keyword from the event title. "
                            "Use the exact title when you can see it from the calendar snapshot."
                        ),
                    }
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "update_calendar_event",
            "description": (
                "Change an existing Apple Calendar event: rename it, move it to a different "
                "time, or change how long it lasts. Use this for ANY correction to an event "
                "that already exists — 'change the title to X', 'move it to 4pm', 'make it an "
                "hour'. Do NOT delete and recreate the event to make a change; this tool edits "
                "it in place and keeps everything you do not pass unchanged. "
                "This is NOT for Apple Reminders (to-do items)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": (
                            "Title or distinctive keyword identifying the event to change — "
                            "its CURRENT title, not the new one."
                        ),
                    },
                    "new_title": {
                        "type": "string",
                        "description": "New event title. Omit to leave the title unchanged.",
                    },
                    "new_start": {
                        "type": "string",
                        "description": (
                            "New start time as ISO 8601 local date-time, e.g. "
                            "'2025-06-20T14:00:00'. Omit to leave the time unchanged."
                        ),
                    },
                    "duration_minutes": {
                        "type": "number",
                        "description": (
                            "New length in minutes. Omit to keep the event's existing duration."
                        ),
                    },
                },
                "required": ["query"],
            },
        },
    },
    # ── Mac control tools ─────────────────────────────────────────────────────
    # These map to on-device handlers in OrbitToolDispatcher.swift. Fuzzy name
    # resolution (apps, sites, shortcuts) happens on the Mac — pass names as heard.
    {
        "type": "function",
        "function": {
            "name": "open_app",
            "description": (
                "Open (launch) an application on the user's Mac — Safari, Notes, Spotify, Xcode, etc. "
                "Use whenever the user wants an app opened, even with loose or partial phrasing. "
                "Fuzzy matching against installed apps happens on-device."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "App name as the user said it, e.g. 'chrome', 'notes'."}
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "quit_app",
            "description": "Quit/close a running application on the user's Mac.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "App name as the user said it."}
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_website",
            "description": (
                "Open a website in a browser on the Mac. Accepts common site names (YouTube, GitHub, Gmail…) "
                "or URLs. Use when the user wants to visit, watch, or see a site."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "site": {"type": "string", "description": "Site name or URL as the user said it."},
                    "browser": {
                        "type": "string",
                        "description": "Optional browser: chrome, safari, arc, firefox, brave, edge. Omit for default.",
                    },
                },
                "required": ["site"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Run a web search in a browser on the Mac. Use when the user wants to look something up online.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The search terms only — no lead-ins like 'the web for'.",
                    },
                    "browser": {
                        "type": "string",
                        "description": "Optional browser: chrome, safari, arc, firefox, brave, edge.",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "control_music",
            "description": (
                "Control music playback on the Mac (Apple Music or Spotify — auto-detected). "
                "Use for play, pause, skip, previous, or asking what's playing."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["play", "pause", "next", "previous", "now_playing"],
                    }
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "control_volume",
            "description": (
                "Change the Mac's output volume. Use for any request to make it louder, quieter, "
                "silent, or set a specific level — including indirect phrasing like 'it's too loud'. "
                "The result reports the real resulting volume — always use that number in your reply, "
                "never assume."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["set", "up", "down", "mute", "unmute"],
                        "description": (
                            "Use 'set' when the user names a destination ('to 30%', 'half volume'), "
                            "'up'/'down' for a relative change ('a bit louder', 'down by 25')."
                        ),
                    },
                    "level": {
                        "type": "integer",
                        "description": (
                            "With 'set': the target volume percent (0-100). "
                            "With 'up'/'down': how many percentage points to change by — "
                            "'lower it by 25%' is action='down', level=25. Defaults to 10 if omitted."
                        ),
                    },
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "control_brightness",
            "description": (
                "Change screen brightness on the Mac (up, down, or set a percent). "
                "ALWAYS use this for any brightness request — ORBIT controls brightness directly; "
                "never tell the user to make a Shortcut for it, and never suggest doing it manually "
                "unless this tool has actually reported a failure. "
                "The result reports the real verified brightness — always use that number in your "
                "reply. If it reports a failure, say so plainly; never claim the screen changed."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["set", "up", "down"],
                        "description": (
                            "Use 'set' whenever the user names a destination — 'to 30%', "
                            "'at half', 'full brightness'. Use 'up'/'down' only for a relative "
                            "change — 'a bit lower', 'down by 20'. 'Set it to 30%' is "
                            "action='set', level=30 — NOT down by 30."
                        ),
                    },
                    "level": {
                        "type": "integer",
                        "description": (
                            "With 'set': the target brightness percent (0-100). "
                            "With 'up'/'down': how many percentage points to change by. "
                            "Defaults to 20 if omitted."
                        ),
                    },
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_system_feature",
            "description": (
                "Turn a Mac system feature on or off: dark mode, focus mode (do not disturb), "
                "wi-fi, or bluetooth. ALWAYS use this tool for these — never run_shortcut."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "feature": {"type": "string", "enum": ["dark_mode", "focus_mode", "wifi", "bluetooth"]},
                    "state": {"type": "string", "enum": ["on", "off"]},
                    "mode": {
                        "type": "string",
                        "description": (
                            "Only with feature='focus_mode': which Focus to switch, as the user says it "
                            "— 'do not disturb', 'work', 'sleep'. Infer it from intent: "
                            "'I'm going to bed' → 'sleep', 'starting work' → 'work'. "
                            "Omit for plain Do Not Disturb."
                        ),
                    },
                },
                "required": ["feature", "state"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_battery_status",
            "description": "Read the Mac's battery percentage and charging state.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get current or upcoming weather for the user's location.",
            "parameters": {
                "type": "object",
                "properties": {
                    "when": {
                        "type": "string",
                        "enum": ["now", "tonight", "tomorrow"],
                        "description": "Defaults to 'now'.",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_file",
            "description": (
                "Search the user's Desktop, Documents, and Downloads for a file by name and open it "
                "if there is a clear match. If several files match, the result lists numbered options — "
                "relay them; the user can answer 'open 1'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": (
                            "ONLY the distinctive file-name words — drop filler like 'my'/'file' "
                            "('find my resume file' → 'resume'). Speech-to-text often garbles or "
                            "splits words; reconstruct the intended name first ('re sum e' → 'resume')."
                        ),
                    }
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_folder",
            "description": (
                "Open a folder in Finder. Accepts 'downloads', 'documents', 'desktop', 'trash', "
                "or any folder name to search for across those locations."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Folder name."}
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_shortcut",
            "description": (
                "Run a macOS Shortcut by name — ONLY for smart home devices (lights, plugs, scenes) "
                "and the user's custom automations (e.g. 'Turn On Bedroom Lights', 'Water Eject'). "
                "NEVER use for system settings — wi-fi, focus, dark mode, volume, brightness all have "
                "dedicated tools. Fuzzy matching against available shortcuts happens on-device."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Shortcut name or a description like 'turn on bedroom lights'."}
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_focus_status",
            "description": (
                "Check which macOS Focus mode is currently active (Do Not Disturb, Work, Sleep, or none). "
                "Use when the user asks whether a Focus is on, or what mode they're in."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "lock_screen",
            "description": "Lock the Mac's screen. Only when the user clearly asks to lock the screen/computer.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
]


# ── Public API ────────────────────────────────────────────────────────────────

async def chat_with_brain(
    messages: list[Message],
    *,
    api_key: str,
    base_url: str,
    model: str,
    max_tokens: int = 1024,
) -> tuple[str, list[dict[str, Any]]]:
    """
    First turn: call the brain LLM with tool schemas via OpenAI-compatible API.

    Returns (reply_text, tool_calls). Each entry is
    {"tool": str, "params": dict[str, Any], "id": str}.

    The list can hold several calls — "dim the brightness and turn on sleep mode" is one
    request with two actions, and dropping all but the first is why only one used to run.
    When non-empty the caller should execute every call, then hand all results to
    resume_after_tool() for the final conversational reply.
    """
    if not api_key.strip():
        raise RuntimeError("BRAIN_API_KEY is empty — add it to orbit-core/.env")

    payload: dict[str, Any] = {
        "model": model,
        "messages": [m.model_dump() for m in messages],
        "tools": ORBIT_TOOLS,
        "tool_choice": "auto",
        "max_tokens": max_tokens,
    }

    url = base_url.rstrip("/") + "/v1/chat/completions"
    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.post(
            url, json=payload, headers={"Authorization": f"Bearer {api_key}"}
        )

    if resp.status_code >= 400:
        raise RuntimeError(
            f"Brain LLM returned HTTP {resp.status_code} from {url}. Body: {resp.text[:800]}"
        )

    data = resp.json()
    msg = data["choices"][0]["message"]

    reply = (msg.get("content") or "").strip()
    tool_calls: list[dict[str, Any]] = []

    for tc in msg.get("tool_calls") or []:
        try:
            args = json.loads(tc["function"]["arguments"])
        except (json.JSONDecodeError, KeyError):
            args = {}
        try:
            name = tc["function"]["name"]
        except KeyError:
            continue
        tool_calls.append({"tool": name, "params": args, "id": tc.get("id", "")})

    return reply, tool_calls


async def resume_after_tool(
    messages: list[Message],
    *,
    executed: list[dict[str, Any]],
    api_key: str,
    base_url: str,
    model: str,
    max_tokens: int = 1024,
) -> str:
    """
    Second turn: supply every tool result and get the final conversational reply.

    `messages` is the same list passed to chat_with_brain (conversation up to and
    including the user message that triggered the calls). `executed` holds one dict per
    call: {"tool", "tool_call_id", "params", "result"}.
    """
    msgs = [m.model_dump() for m in messages]

    # One assistant message carrying every tool_call the model asked for.
    msgs.append({
        "role": "assistant",
        "content": None,
        "tool_calls": [
            {
                "id": item["tool_call_id"],
                "type": "function",
                "function": {
                    "name": item["tool"],
                    "arguments": json.dumps(item.get("params") or {}),
                },
            }
            for item in executed
        ],
    })

    # One tool message per result, in the same order.
    for item in executed:
        msgs.append({
            "role": "tool",
            "tool_call_id": item["tool_call_id"],
            "content": item["result"],
        })

    payload: dict[str, Any] = {
        "model": model,
        "messages": msgs,
        "max_tokens": max_tokens,
    }

    url = base_url.rstrip("/") + "/v1/chat/completions"
    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.post(
            url, json=payload, headers={"Authorization": f"Bearer {api_key}"}
        )

    if resp.status_code >= 400:
        raise RuntimeError(
            f"Brain LLM returned HTTP {resp.status_code} from {url}. Body: {resp.text[:800]}"
        )

    data = resp.json()
    reply = (data["choices"][0]["message"].get("content") or "").strip()
    return reply
