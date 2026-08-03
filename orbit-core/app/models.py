from __future__ import annotations

from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, Field


class ChatRequest(BaseModel):
    session_id: str = Field(min_length=1, max_length=128)
    message: str = Field(min_length=1, max_length=8000)
    # Use Optional[...] instead of X | None for Python 3.9 (PEP 604 is 3.10+).
    route_hint: Optional[Literal["local", "cloud", "tooling", "brain"]] = Field(
        default=None,
        description="Tier from Mac Tier-1 router (Foundation Models or keywords).",
    )
    # Calendar / tool text from the Mac app; injected when route resolves to tooling.
    tooling_context: Optional[str] = Field(
        default=None,
        max_length=12000,
        description="Device tool snapshot (e.g. today’s events). Server uses only when route is tooling.",
    )
    # From the Mac app: authoritative wall clock for greetings (morning vs night).
    client_local_iso: Optional[str] = Field(
        default=None,
        max_length=80,
        description="ISO 8601 local timestamp from the user’s device.",
    )
    client_tz: Optional[str] = Field(
        default=None,
        max_length=80,
        description="IANA timezone id (e.g. America/Halifax) from the user’s device.",
    )
    include_memory_debug: bool = Field(
        default=False,
        description="If true, response includes lightweight memory-debug metadata.",
    )
    save_memory: bool = Field(
        default=True,
        description="If false, this turn is NOT saved to conversation history or semantic memory.",
    )


class MemoryDebug(BaseModel):
    recent_turn_count: int
    semantic_hits: List[str]


class ToolCallInfo(BaseModel):
    tool: str
    params: Dict[str, Any] = {}
    id: str = ""


# Bumped whenever the /chat contract changes shape. The Mac app compares this against its own
# constant: a stale backend paired with a fresh app (or the reverse) used to fail silently —
# tool calls simply vanished and the user saw "Let me check that for you." forever.
PROTOCOL_VERSION = 2


class ChatResponse(BaseModel):
    reply: str
    route: Literal["local", "cloud", "tooling", "brain"]
    model: str
    memory_debug: Optional[MemoryDebug] = None
    # A single request can carry several actions ("dim the screen and turn on sleep mode").
    tool_calls: List[ToolCallInfo] = []
    protocol: int = PROTOCOL_VERSION


class ToolResultItem(BaseModel):
    tool: str
    tool_call_id: str
    params: Dict[str, Any] = {}
    result: str = Field(max_length=4000)


class ToolResultRequest(BaseModel):
    session_id: str = Field(min_length=1, max_length=128)
    original_message: str = Field(min_length=1, max_length=8000)
    results: List[ToolResultItem] = Field(min_length=1)
    tooling_context: Optional[str] = Field(default=None, max_length=12000)
    client_local_iso: Optional[str] = Field(default=None, max_length=80)
    client_tz: Optional[str] = Field(default=None, max_length=80)


class Message(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class FactCreate(BaseModel):
    fact: str = Field(min_length=1, max_length=2000)


class FactRecord(BaseModel):
    id: int
    fact: str


class FactListResponse(BaseModel):
    items: List[FactRecord]


class SemanticMemoryRecord(BaseModel):
    id: int
    text: str
    source: str
    importance: float


class SemanticMemoryCreate(BaseModel):
    text: str = Field(min_length=1, max_length=400)
    source: str = Field(default="manual", min_length=1, max_length=32)
    importance: Optional[float] = Field(default=None, ge=0.0, le=1.0)


class SemanticMemoryImportanceUpdate(BaseModel):
    importance: float = Field(ge=0.0, le=1.0)


class SemanticMemoryListResponse(BaseModel):
    items: List[SemanticMemoryRecord]


class SemanticMemoryPurgeResponse(BaseModel):
    deleted_count: int
