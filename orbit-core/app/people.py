"""People ORBIT knows, and the names it mishears them by (M8, 2026-08-03).

Speech recognition splits one friend into several strangers. In the live DB, Ayush's friend
**Kavan** appears as "Kawan" and as "Kan" — two calendar events, two names, no connection,
and ORBIT once offered to delete one while keeping "the other". Nothing in the system knew
they were the same person.

Design choice, deliberate: this module **informs the brain, it does not rewrite text.**
A hard local rewrite of names is exactly the anti-pattern the orchestrator-split rule warns
about — a matcher claiming an utterance the brain would have understood, with a false match
silently renaming a real person. Instead the known people and their heard variants go into
the system prompt, and the brain resolves them with the conversation in view.

Aliases are seeded from two sources only:
  1. **Observed** mishearings, taken from real data (kawan, kan).
  2. A small set of **phonetic** variants from the substitutions Apple's recogniser actually
     makes on Indian-English names — v↔w above all, which is precisely how Kavan→Kawan
     happened. Nothing speculative beyond that; a wrong alias is worse than a missing one.
"""

from __future__ import annotations

import re
from typing import Iterable, Optional

# Substitutions the recogniser actually makes on these names. Kept short on purpose —
# every extra variant is another chance to attach a stranger's name to a friend.
_PHONETIC_RULES = (
    ("v", "w"),
    ("w", "v"),
    ("sh", "s"),
    ("s", "sh"),
    ("k", "c"),
    ("ee", "i"),
    ("i", "ee"),
    ("th", "t"),
)


def _is_plausible(variant: str) -> bool:
    """Reject the nonsense a naive substitution produces.

    Applying "s"→"sh" to "shreel" gives "shhreel"; to "nishika", "nishhika". Those are not
    things a recogniser would ever emit, and every junk alias is another chance to bind a
    stranger's name to a friend.
    """
    if len(variant) < 2:
        return False
    if "hh" in variant:
        return False
    return not any(variant[i] == variant[i + 1] == variant[i + 2] for i in range(len(variant) - 2))


def phonetic_variants(name: str) -> list[str]:
    """Conservative single-substitution variants of a name, lowercased."""
    base = name.strip().lower()
    if not base:
        return []
    out = set()
    for src, dst in _PHONETIC_RULES:
        if src not in base:
            continue
        # Don't create a digraph that is already there ("s"→"sh" inside "sh").
        if dst.startswith(src) and (src + dst[len(src):]) in base:
            continue
        candidate = base.replace(src, dst, 1)
        if candidate != base and _is_plausible(candidate):
            out.add(candidate)
    return sorted(out)


def build_aliases(name: str, observed: Optional[Iterable[str]] = None) -> list[str]:
    """Heard variants for one person: observed first, then a few phonetic ones."""
    aliases = {a.strip().lower() for a in (observed or []) if a.strip()}
    aliases.update(phonetic_variants(name))
    aliases.discard(name.strip().lower())
    return sorted(aliases)


def resolve_people_in_text(text: str, people: list[dict]) -> tuple[str, list[tuple[str, str]]]:
    """Rewrite known misheard names to the real ones. Returns (text, [(heard, real), …]).

    Prompt guidance alone was not enough, measured: told plainly that "Kawan" IS "Kavan",
    the brain still answered *"your housemates are Krish and Kavan — Kawan is just a close
    friend"*, and titled a reminder "Call Nishka". This project has learned that lesson
    twice already — prompting is not enforcement.

    This is safe to do locally because it is **not a guess**: only an exact, whole-word
    match against a curated list of that person's known variants is rewritten. Nothing
    fuzzy, so it cannot quietly merge two real people the way a similarity score would.
    The same pattern already runs for websites (`siteAliases`, "geetha" → github.com).
    """
    if not text or not people:
        return text, []

    lookup: dict[str, str] = {}
    for person in people:
        canonical = person["name"]
        for alias in person.get("aliases") or []:
            key = alias.strip().lower()
            # A variant that is also someone's real name must never be rewritten.
            if key and key not in lookup:
                lookup[key] = canonical
    for person in people:
        lookup.pop(person["name"].strip().lower(), None)
    if not lookup:
        return text, []

    corrections: list[tuple[str, str]] = []
    pattern = re.compile(
        r"\b(" + "|".join(re.escape(a) for a in sorted(lookup, key=len, reverse=True)) + r")\b",
        re.IGNORECASE,
    )

    def _swap(match: re.Match) -> str:
        heard = match.group(0)
        real = lookup[heard.lower()]
        if (heard, real) not in corrections:
            corrections.append((heard, real))
        return real

    return pattern.sub(_swap, text), corrections


def corrections_note(corrections: list[tuple[str, str]]) -> str:
    """Tell the brain a name was repaired, so it doesn't re-introduce the misheard form."""
    if not corrections:
        return ""
    pairs = "; ".join(f'"{heard}" → {real}' for heard, real in corrections)
    return (
        "\n\n### Name correction applied\n"
        f"Speech recognition misheard a name in his message and it has already been corrected "
        f"for you ({pairs}). The corrected name is the real person. Use it in your reply and in "
        "anything you create. Do not mention the mishearing or the correction — just answer "
        "naturally about the right person.\n"
    )


def people_prompt_block(people: list[dict]) -> str:
    """The people section of the system prompt.

    Aliases are shown as *how the name may be misheard* rather than as facts, so the brain
    treats them as a hint. Without this, a misheard name reads as someone new.
    """
    if not people:
        return ""
    lines = []
    for person in people:
        line = f"- **{person['name']}**"
        if person.get("relationship"):
            line += f" — {person['relationship']}"
        if person.get("notes"):
            line += f". {person['notes']}"
        aliases = person.get("aliases") or []
        if aliases:
            line += f" — ALSO HEARD AS: {', '.join(aliases)}"
        lines.append(line)
    return (
        "\n\n### People he knows\n"
        + "\n".join(lines)
        + "\n\n**These names are the same person, not different people.** Voice input garbles "
        "names constantly, so each person above is listed with the forms speech turns their name "
        "into. A listed variant IS that person — 'Kawan' and 'Kan' are not friends of Kavan, they "
        "are *Kavan*, misheard.\n"
        "- Always answer about the real person, and use the correct spelling in your reply and in "
        "anything you create (calendar events, reminders, notes).\n"
        "- NEVER contrast a variant with its own canonical name — saying \"your housemates are "
        "Kavan and Krish, not Kawan\" is nonsense, because Kawan IS Kavan.\n"
        "- Never invent a relationship that isn't listed above.\n"
        "- Correcting him is not the goal: just use the right name naturally. Only mention the "
        "mishearing if it genuinely matters for what he asked.\n"
        "- If a name is nothing like anyone above, it is someone new — ask, don't guess.\n"
    )
