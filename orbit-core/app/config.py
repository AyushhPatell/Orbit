from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

from dotenv import dotenv_values, load_dotenv


def _parse_bool_env(raw: Optional[str], default: bool) -> bool:
    """True/false from env; unknown or empty → default."""
    if raw is None or str(raw).strip() == "":
        return default
    v = str(raw).strip().lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    return default


def _parse_cloud_fallback_chars(raw: Optional[str], default: int = 1200) -> int:
    """Heuristic: route to cloud when user message is longer than this (chars)."""
    if raw is None or str(raw).strip() == "":
        return default
    try:
        v = int(str(raw).strip(), 10)
    except ValueError:
        return default
    return max(200, min(500_000, v))


def _parse_positive_int(raw: Optional[str], default: int, *, min_v: int = 1, max_v: int = 100_000) -> int:
    if raw is None or str(raw).strip() == "":
        return default
    try:
        v = int(str(raw).strip(), 10)
    except ValueError:
        return default
    return max(min_v, min(max_v, v))


def _parse_float_range(raw: Optional[str], default: float, *, min_v: float = 0.0, max_v: float = 1.0) -> float:
    if raw is None or str(raw).strip() == "":
        return default
    try:
        v = float(str(raw).strip())
    except ValueError:
        return default
    return max(min_v, min(max_v, v))


def _parse_token_limit(raw: Optional[str], default: int, *, cap: int = 8192) -> int:
    """Positive int from env; clamp to [1, cap]. Invalid or empty → default."""
    if raw is None or str(raw).strip() == "":
        return default
    try:
        v = int(str(raw).strip(), 10)
    except ValueError:
        return default
    return max(1, min(cap, v))


@dataclass(frozen=True)
class Settings:
    env: str
    port: int
    db_path: Path
    # ollama | openai — how /ready probes; chat always uses /v1/chat/completions
    local_llm_backend: str
    local_llm_url: str
    local_llm_model: str
    cloud_base_url: str
    cloud_model: str
    cloud_api_key: str
    chat_max_tokens_local: int
    chat_max_tokens_cloud: int
    cloud_redact_pii: bool
    redact_local_storage: bool
    cloud_fallback_min_chars: int
    semantic_memory_enabled: bool
    semantic_memory_min_score: float
    semantic_memory_retention_days: int
    semantic_memory_max_items: int
    chat_audit_log_path: Optional[Path]
    chat_audit_max_bytes: int
    chat_audit_backup_count: int
    profile_path: Path
    embed_model: str
    embed_url: str
    brain_model: str
    brain_base_url: str
    brain_api_key: str


def get_settings() -> Settings:
    project_root = Path(__file__).resolve().parents[1]
    env_path = project_root / ".env"
    # Read the file first so values always match what you saved (even if os.environ was polluted earlier).
    file_vals: Dict[str, Optional[str]] = dotenv_values(env_path) if env_path.is_file() else {}

    def from_file_first(*keys: str) -> Optional[str]:
        for k in keys:
            v = file_vals.get(k)
            if v is not None and str(v).strip() != "":
                return str(v).strip()
        return None

    load_dotenv(env_path, override=True)

    db_path = Path(os.getenv("ORBIT_DB_PATH", "./data/orbit.db"))
    if not db_path.is_absolute():
        db_path = project_root / db_path

    profile_path = project_root / "user_profile.md"

    url = from_file_first("LOCAL_LLM_URL", "OLLAMA_BASE_URL")
    if url is None:
        url = os.getenv("LOCAL_LLM_URL") or os.getenv("OLLAMA_BASE_URL") or "http://127.0.0.1:11434"

    model = from_file_first("LOCAL_LLM_MODEL", "OLLAMA_MODEL")
    if model is None:
        model = (
            os.getenv("LOCAL_LLM_MODEL")
            or os.getenv("OLLAMA_MODEL")
            or "qwen2.5:7b-instruct-q4_K_M"
        )

    backend_raw = from_file_first("LOCAL_LLM_BACKEND")
    if backend_raw is None:
        backend_raw = os.getenv("LOCAL_LLM_BACKEND") or "ollama"
    backend = backend_raw.strip().lower()
    if backend not in ("ollama", "openai"):
        backend = "ollama"

    cloud_base = from_file_first("CLOUD_BASE_URL")
    if cloud_base is None:
        cloud_base = os.getenv("CLOUD_BASE_URL", "").strip() or "https://api.openai.com"

    cloud_model = from_file_first("CLOUD_MODEL")
    if cloud_model is None:
        cloud_model = os.getenv("CLOUD_MODEL", "").strip() or "gpt-4o-mini"

    cloud_key = from_file_first("CLOUD_API_KEY")
    if cloud_key is None:
        cloud_key = os.getenv("CLOUD_API_KEY", "").strip()

    local_max_raw = from_file_first("CHAT_MAX_TOKENS_LOCAL", "LOCAL_LLM_MAX_TOKENS")
    if local_max_raw is None:
        local_max_raw = os.getenv("CHAT_MAX_TOKENS_LOCAL") or os.getenv("LOCAL_LLM_MAX_TOKENS")
    cloud_max_raw = from_file_first("CHAT_MAX_TOKENS_CLOUD", "CLOUD_MAX_TOKENS")
    if cloud_max_raw is None:
        cloud_max_raw = os.getenv("CHAT_MAX_TOKENS_CLOUD") or os.getenv("CLOUD_MAX_TOKENS")

    redact_raw = from_file_first("CLOUD_REDACT_PII")
    if redact_raw is None:
        redact_raw = os.getenv("CLOUD_REDACT_PII")
    cloud_redact = _parse_bool_env(redact_raw, default=True)

    local_store_redact_raw = from_file_first("REDACT_LOCAL_STORAGE")
    if local_store_redact_raw is None:
        local_store_redact_raw = os.getenv("REDACT_LOCAL_STORAGE")
    redact_local_storage = _parse_bool_env(local_store_redact_raw, default=False)

    fb_raw = from_file_first("CLOUD_FALLBACK_MIN_CHARS")
    if fb_raw is None:
        fb_raw = os.getenv("CLOUD_FALLBACK_MIN_CHARS")
    cloud_fallback_chars = _parse_cloud_fallback_chars(fb_raw, default=1200)

    sem_raw = from_file_first("SEMANTIC_MEMORY_ENABLED")
    if sem_raw is None:
        sem_raw = os.getenv("SEMANTIC_MEMORY_ENABLED")
    semantic_memory_enabled = _parse_bool_env(sem_raw, default=True)

    sem_score_raw = from_file_first("SEMANTIC_MEMORY_MIN_SCORE")
    if sem_score_raw is None:
        sem_score_raw = os.getenv("SEMANTIC_MEMORY_MIN_SCORE")
    semantic_memory_min_score = _parse_float_range(sem_score_raw, default=0.56, min_v=0.1, max_v=0.95)

    sem_days_raw = from_file_first("SEMANTIC_MEMORY_RETENTION_DAYS")
    if sem_days_raw is None:
        sem_days_raw = os.getenv("SEMANTIC_MEMORY_RETENTION_DAYS")
    semantic_memory_retention_days = _parse_positive_int(sem_days_raw, default=90, min_v=1, max_v=3650)

    sem_max_raw = from_file_first("SEMANTIC_MEMORY_MAX_ITEMS")
    if sem_max_raw is None:
        sem_max_raw = os.getenv("SEMANTIC_MEMORY_MAX_ITEMS")
    semantic_memory_max_items = _parse_positive_int(sem_max_raw, default=500, min_v=20, max_v=50_000)

    audit_raw = from_file_first("CHAT_AUDIT_LOG_PATH")
    if audit_raw is None:
        audit_raw = os.getenv("CHAT_AUDIT_LOG_PATH")
    audit_path: Optional[Path] = None
    if audit_raw is not None and str(audit_raw).strip() != "":
        audit_path = Path(str(audit_raw).strip())
        if not audit_path.is_absolute():
            audit_path = project_root / audit_path

    audit_max_raw = from_file_first("CHAT_AUDIT_MAX_BYTES")
    if audit_max_raw is None:
        audit_max_raw = os.getenv("CHAT_AUDIT_MAX_BYTES")
    chat_audit_max_bytes = _parse_positive_int(
        audit_max_raw,
        default=2_000_000,
        min_v=100_000,
        max_v=200_000_000,
    )

    audit_backups_raw = from_file_first("CHAT_AUDIT_BACKUP_COUNT")
    if audit_backups_raw is None:
        audit_backups_raw = os.getenv("CHAT_AUDIT_BACKUP_COUNT")
    chat_audit_backup_count = _parse_positive_int(
        audit_backups_raw,
        default=4,
        min_v=1,
        max_v=20,
    )

    embed_model_raw = from_file_first("EMBED_MODEL")
    if embed_model_raw is None:
        embed_model_raw = os.getenv("EMBED_MODEL", "nomic-embed-text").strip() or "nomic-embed-text"

    embed_url_raw = from_file_first("EMBED_URL")
    if embed_url_raw is None:
        embed_url_raw = os.getenv("EMBED_URL", "").strip() or url  # default: same as LOCAL_LLM_URL

    brain_model_raw = from_file_first("BRAIN_MODEL")
    if brain_model_raw is None:
        brain_model_raw = os.getenv("BRAIN_MODEL", "").strip() or "gpt-4o-mini"

    # BRAIN_BASE_URL defaults to cloud_base_url so one endpoint serves both.
    brain_base_raw = from_file_first("BRAIN_BASE_URL")
    if brain_base_raw is None:
        brain_base_raw = os.getenv("BRAIN_BASE_URL", "").strip() or cloud_base

    # BRAIN_API_KEY falls back to CLOUD_API_KEY so only one key is needed.
    brain_key_raw = from_file_first("BRAIN_API_KEY") or from_file_first("CLOUD_API_KEY")
    if brain_key_raw is None:
        brain_key_raw = os.getenv("BRAIN_API_KEY") or os.getenv("CLOUD_API_KEY", "")
    brain_key_raw = (brain_key_raw or "").strip()

    return Settings(
        env=os.getenv("ORBIT_ENV", "dev"),
        port=int(os.getenv("ORBIT_PORT", "8787")),
        db_path=db_path,
        local_llm_backend=backend,
        local_llm_url=url,
        local_llm_model=model,
        cloud_base_url=cloud_base,
        cloud_model=cloud_model,
        cloud_api_key=cloud_key,
        chat_max_tokens_local=_parse_token_limit(local_max_raw, default=768),
        chat_max_tokens_cloud=_parse_token_limit(cloud_max_raw, default=1024),
        cloud_redact_pii=cloud_redact,
        redact_local_storage=redact_local_storage,
        cloud_fallback_min_chars=cloud_fallback_chars,
        semantic_memory_enabled=semantic_memory_enabled,
        semantic_memory_min_score=semantic_memory_min_score,
        semantic_memory_retention_days=semantic_memory_retention_days,
        semantic_memory_max_items=semantic_memory_max_items,
        chat_audit_log_path=audit_path,
        chat_audit_max_bytes=chat_audit_max_bytes,
        chat_audit_backup_count=chat_audit_backup_count,
        profile_path=profile_path,
        embed_model=embed_model_raw,
        embed_url=embed_url_raw,
        brain_model=brain_model_raw,
        brain_base_url=brain_base_raw,
        brain_api_key=brain_key_raw,
    )
