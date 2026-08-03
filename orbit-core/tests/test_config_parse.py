from __future__ import annotations

from app.config import _parse_bool_env, _parse_float_range, _parse_positive_int, _parse_token_limit


def test_parse_token_limit_defaults() -> None:
    assert _parse_token_limit(None, 768) == 768
    assert _parse_token_limit("", 768) == 768


def test_parse_token_limit_numeric() -> None:
    assert _parse_token_limit("512", 100) == 512
    assert _parse_token_limit("  1024  ", 100) == 1024


def test_parse_token_limit_clamped() -> None:
    assert _parse_token_limit("0", 100) == 1
    assert _parse_token_limit("999999", 100, cap=2000) == 2000


def test_parse_token_limit_invalid() -> None:
    assert _parse_token_limit("nope", 400) == 400


def test_parse_bool_env() -> None:
    assert _parse_bool_env("true", default=False) is True
    assert _parse_bool_env("0", default=True) is False
    assert _parse_bool_env("unknown", default=True) is True


def test_parse_positive_int() -> None:
    assert _parse_positive_int("50", default=10, min_v=1, max_v=100) == 50
    assert _parse_positive_int("0", default=10, min_v=5, max_v=100) == 5
    assert _parse_positive_int("bad", default=10, min_v=1, max_v=100) == 10


def test_parse_float_range() -> None:
    assert _parse_float_range("0.7", default=0.5, min_v=0.1, max_v=0.9) == 0.7
    assert _parse_float_range("9.0", default=0.5, min_v=0.1, max_v=0.9) == 0.9
    assert _parse_float_range("bad", default=0.5, min_v=0.1, max_v=0.9) == 0.5
