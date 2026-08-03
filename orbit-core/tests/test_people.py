"""People and misheard names (M8, 2026-08-03).

Ayush's friend **Kavan** was stored in his calendar as both "Kawan" and "Kan" — one person
split into two strangers by speech recognition, with nothing connecting them.

Prompt guidance alone was measured and was NOT enough: told plainly that "Kawan" IS "Kavan",
the brain still answered *"your housemates are Krish and Kavan — Kawan is just a close
friend"*, and titled a reminder "Call Nishka". So resolution is structural. It is safe to do
locally because it is not a guess: only an exact, whole-word match against a curated list of
known variants is rewritten — nothing fuzzy, so it cannot merge two real people.
"""
from __future__ import annotations

from app.people import (
    build_aliases,
    corrections_note,
    people_prompt_block,
    phonetic_variants,
    resolve_people_in_text,
)

PEOPLE = [
    {"name": "Kavan", "relationship": "close friend and housemate",
     "aliases": ["cavan", "kan", "kawan", "kevan"], "notes": ""},
    {"name": "Krish", "relationship": "close friend and housemate",
     "aliases": ["crish", "kish", "kreesh", "kris", "krishna"], "notes": ""},
    {"name": "Nishika", "relationship": "close friend",
     "aliases": ["neeshika", "nisheka", "nishica", "nishka", "nisika"], "notes": ""},
    {"name": "Manika", "relationship": "close friend",
     "aliases": ["maneeka", "manica", "monika"], "notes": ""},
]


def test_the_real_mishearings_resolve() -> None:
    """Both forms found in his actual calendar data."""
    for heard in ["Kawan", "Kan"]:
        out, corrections = resolve_people_in_text(f"schedule a call with {heard} on Thursday", PEOPLE)
        assert "Kavan" in out, heard
        assert corrections == [(heard, "Kavan")]


def test_reminder_title_gets_the_real_name() -> None:
    out, _ = resolve_people_in_text("remind me to call Nishka tomorrow at 6 pm", PEOPLE)
    assert "Nishika" in out and "Nishka" not in out


def test_canonical_names_are_left_alone() -> None:
    text = "Kavan and Krish are my housemates, and Nishika studies with me"
    out, corrections = resolve_people_in_text(text, PEOPLE)
    assert out == text
    assert corrections == []


def test_unknown_names_are_untouched() -> None:
    out, corrections = resolve_people_in_text("who is Rajesh", PEOPLE)
    assert out == "who is Rajesh"
    assert corrections == []


def test_matching_is_whole_word_only() -> None:
    """"kan" must not fire inside "cannot", "Kansas" or "can".  """
    for text in ["I cannot do that", "flying to Kansas", "can you help", "scanning the folder"]:
        out, corrections = resolve_people_in_text(text, PEOPLE)
        assert out == text, text
        assert corrections == []


def test_case_is_handled_and_normalised() -> None:
    out, corrections = resolve_people_in_text("call KAWAN later", PEOPLE)
    assert "Kavan" in out
    assert corrections == [("KAWAN", "Kavan")]


def test_several_names_in_one_sentence() -> None:
    out, corrections = resolve_people_in_text("dinner with Kawan and Nishka tonight", PEOPLE)
    assert "Kavan" in out and "Nishika" in out
    assert len(corrections) == 2


def test_a_real_persons_name_is_never_rewritten_as_someone_elses_alias() -> None:
    """If one friend's alias happens to be another friend's actual name, the real name wins."""
    people = [
        {"name": "Kavan", "relationship": "friend", "aliases": ["kris"], "notes": ""},
        {"name": "Kris", "relationship": "friend", "aliases": [], "notes": ""},
    ]
    out, corrections = resolve_people_in_text("meeting Kris today", people)
    assert out == "meeting Kris today"
    assert corrections == []


def test_no_people_means_no_rewriting() -> None:
    assert resolve_people_in_text("call Kawan", []) == ("call Kawan", [])


def test_phonetic_variants_are_plausible() -> None:
    """A naive substitution turns "shreel" into "shhreel" — junk aliases are worse than none."""
    for name in ["Shreel", "Nishika", "Shruti", "Krish"]:
        for variant in phonetic_variants(name):
            assert "hh" not in variant, variant
            assert variant != name.lower()


def test_kavan_to_kawan_is_generated_not_just_observed() -> None:
    """v↔w is the substitution that caused the real bug, so it must be produced on its own."""
    assert "kawan" in phonetic_variants("Kavan")


def test_build_aliases_merges_observed_and_phonetic() -> None:
    aliases = build_aliases("Kavan", ["kan"])
    assert "kan" in aliases and "kawan" in aliases
    assert "kavan" not in aliases


def test_prompt_block_states_variants_are_the_same_person() -> None:
    block = people_prompt_block(PEOPLE)
    assert "Kavan" in block and "kawan" in block
    assert "not different people" in block


def test_corrections_note_names_the_repair() -> None:
    note = corrections_note([("Kawan", "Kavan")])
    assert "Kawan" in note and "Kavan" in note
    assert corrections_note([]) == ""
