from __future__ import annotations

import pytest

from app.router import classify_route, resolve_route


@pytest.mark.parametrize(
    "message,expected",
    [
        ("What's on my calendar tomorrow?", "tooling"),
        ("What's on for today?", "tooling"),
        ("Plan my schedule next week", "tooling"),
        ("Hello", "local"),
        ("deep research on quantum error correction", "cloud"),
        ("x" * 1201, "cloud"),
    ],
)
def test_classify_route(message: str, expected: str) -> None:
    assert classify_route(message) == expected


def test_classify_route_cloud_threshold() -> None:
    assert classify_route("x" * 1201, cloud_min_chars=1200) == "cloud"
    assert classify_route("x" * 1201, cloud_min_chars=5000) == "local"


def test_resolve_route_hint_wins() -> None:
    assert resolve_route("hello", "cloud") == "cloud"
    assert resolve_route("hello", "tooling") == "tooling"
    assert resolve_route("hello", "local") == "local"


def test_resolve_route_invalid_hint_falls_back() -> None:
    assert resolve_route("what's on my calendar", None) == "tooling"
    assert resolve_route("what's on my calendar", "invalid") == "tooling"
