from __future__ import annotations

import hashlib
import math
import re
import time
from typing import Iterable, List, Optional, Tuple

_TOKEN_RE = re.compile(r"[A-Za-z0-9']+")


# ---------------------------------------------------------------------------
# Hash-based fallback (deterministic, zero deps, 192-dim)
# ---------------------------------------------------------------------------

def tokenize(text: str) -> list[str]:
    return [m.group(0).lower() for m in _TOKEN_RE.finditer(text)]


def _embed_hash(text: str, *, dims: int = 192) -> list[float]:
    """Deterministic hashing vectorizer — used as fallback when Ollama unavailable."""
    vec = [0.0] * dims
    for tok in tokenize(text):
        digest = hashlib.blake2b(tok.encode("utf-8"), digest_size=8).digest()
        idx = int.from_bytes(digest[:4], "big") % dims
        sign = 1.0 if digest[4] % 2 == 0 else -1.0
        vec[idx] += sign
    norm = math.sqrt(sum(v * v for v in vec))
    if norm > 0:
        vec = [v / norm for v in vec]
    return vec


# ---------------------------------------------------------------------------
# Ollama embedding provider
# ---------------------------------------------------------------------------

class OllamaEmbedder:
    """
    Calls Ollama's /api/embeddings endpoint synchronously.
    Falls back gracefully — callers get None and should use _embed_hash.
    """

    HASH_FALLBACK_MODEL = "__hash_fallback__"
    HASH_FALLBACK_DIMS = 192

    # A cold Ollama has to load the model before it can answer, which easily exceeds a short
    # timeout. Generous enough to cover that, still bounded so a hung server can't stall /chat.
    DEFAULT_TIMEOUT = 20.0
    # How long to keep using hash fallback before trying the real embedder again.
    RETRY_AFTER_SECONDS = 60.0

    def __init__(self, base_url: str, model: str, *, timeout: float = DEFAULT_TIMEOUT) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model.strip()
        self.timeout = timeout
        self._dims: Optional[int] = None
        # None = not yet probed; True = works; False = unavailable (retried after a cooldown)
        self._available: Optional[bool] = None
        self._unavailable_since: float = 0.0

    def _mark_unavailable(self) -> None:
        self._available = False
        self._unavailable_since = time.monotonic()

    def _may_retry(self) -> bool:
        """
        True once the cooldown has elapsed after a failure.

        Without this a single slow cold start latched the embedder off for the entire process
        lifetime — memory silently degraded to hash similarity until the next restart, with no
        symptom other than bad recall.
        """
        return time.monotonic() - self._unavailable_since >= self.RETRY_AFTER_SECONDS

    def probe(self) -> bool:
        """Check if the model is reachable. Re-probes after the cooldown rather than latching."""
        if self._available is True:
            return True
        if self._available is False and not self._may_retry():
            return False
        try:
            import httpx
            with httpx.Client(timeout=self.timeout) as client:
                resp = client.post(
                    f"{self.base_url}/api/embeddings",
                    json={"model": self.model, "prompt": "probe"},
                )
                if resp.status_code == 200:
                    vec = resp.json().get("embedding")
                    if isinstance(vec, list) and len(vec) > 0:
                        self._dims = len(vec)
                        self._available = True
                        return True
        except Exception:
            pass
        self._mark_unavailable()
        return False

    def embed(self, text: str) -> Optional[list[float]]:
        """Return embedding vector, or None if the model is unavailable right now."""
        if self._available is False and not self._may_retry():
            return None
        try:
            import httpx
            with httpx.Client(timeout=self.timeout) as client:
                resp = client.post(
                    f"{self.base_url}/api/embeddings",
                    json={"model": self.model, "prompt": text},
                )
                if resp.status_code != 200:
                    self._mark_unavailable()
                    return None
                vec = resp.json().get("embedding")
                if not isinstance(vec, list) or not vec:
                    return None
                if self._dims is None:
                    self._dims = len(vec)
                self._available = True
                return [float(v) for v in vec]
        except Exception:
            self._mark_unavailable()
            return None

    @property
    def dims(self) -> int:
        if self._dims is not None:
            return self._dims
        if self.probe():
            return self._dims or 768
        return self.HASH_FALLBACK_DIMS

    @property
    def model_key(self) -> str:
        """Stable identifier stored in embedding_meta."""
        return self.HASH_FALLBACK_MODEL if self._available is False else self.model


# ---------------------------------------------------------------------------
# Module-level provider (configured once at server startup)
# ---------------------------------------------------------------------------

_provider: Optional[OllamaEmbedder] = None


def configure_embedder(
    base_url: str, model: str, *, timeout: float = OllamaEmbedder.DEFAULT_TIMEOUT
) -> None:
    """
    Call this once at startup (before any embed_text calls) to enable real embeddings.
    If Ollama / the model is unavailable, embed_text falls back to hash embeddings silently.
    """
    global _provider
    _provider = OllamaEmbedder(base_url=base_url, model=model, timeout=timeout)
    _provider.probe()   # eager probe so dims are known before first request


def get_embed_dims() -> int:
    """Returns the dimensionality of vectors produced by the current provider."""
    if _provider is not None and _provider.probe():
        return _provider.dims
    return OllamaEmbedder.HASH_FALLBACK_DIMS


def get_embed_model_key() -> str:
    """Returns a stable string identifying the current embedding model."""
    if _provider is not None and _provider._available:
        return _provider.model
    return OllamaEmbedder.HASH_FALLBACK_MODEL


def is_real_embedder_active() -> bool:
    return _provider is not None and bool(_provider._available)


# ---------------------------------------------------------------------------
# Public embedding entry point (backward-compatible signature)
# ---------------------------------------------------------------------------

def embed_text(text: str, *, dims: int = 192) -> list[float]:
    """
    Embed text. Uses the Ollama provider if configured and available,
    otherwise falls back to deterministic hash embeddings.
    The `dims` kwarg is only used by the hash fallback (kept for back-compat).
    """
    if _provider is not None:
        vec = _provider.embed(text)
        if vec is not None:
            return vec
    return _embed_hash(text, dims=dims)


def cosine_similarity(a: Iterable[float], b: Iterable[float]) -> float:
    """True cosine similarity, in [-1, 1].

    This was a bare dot product, which is only cosine when both vectors are unit length.
    The hash fallback happens to produce those; `nomic-embed-text` does not — its vectors
    have magnitude ~20, so scores came back around 150-350 instead of 0-1. Every stored
    memory then cleared the 0.6 relevance gate in `semantic_search`, and ranking was skewed
    by vector magnitude rather than meaning. Silent since real embeddings were switched on
    (Phase 3.5): recall returned "the top few of everything" instead of "what is relevant".

    Normalising here rather than at write time fixes existing rows with no re-embedding.
    """
    aa = list(a)
    bb = list(b)
    if len(aa) != len(bb) or not aa:
        return 0.0
    dot = sum(x * y for x, y in zip(aa, bb))
    mag_a = math.sqrt(sum(x * x for x in aa))
    mag_b = math.sqrt(sum(x * x for x in bb))
    if mag_a == 0.0 or mag_b == 0.0:
        return 0.0
    return dot / (mag_a * mag_b)


# ---------------------------------------------------------------------------
# Candidate memory extraction (unchanged)
# ---------------------------------------------------------------------------

def extract_candidate_memories(user_message: str) -> list[str]:
    """
    Minimal mem0-like candidate extraction from user turns.
    Stores only likely durable preferences/context statements.
    """
    text = user_message.strip()
    if not text:
        return []

    parts = re.split(r"[.\n;]+", text)
    out: List[str] = []
    triggers = (
        "i am ",
        "i'm ",
        "my ",
        "i prefer",
        "i like",
        "i don't like",
        "i usually",
        "i need",
        "i want",
        "i use",
        "we are building",
    )
    for raw in parts:
        p = raw.strip()
        if len(p) < 10 or len(p) > 220:
            continue
        lower = p.lower()
        if lower.endswith("?"):
            continue
        if any(t in lower for t in triggers):
            out.append(p)
    deduped: List[str] = []
    seen: set[str] = set()
    for item in out:
        k = item.lower()
        if k in seen:
            continue
        seen.add(k)
        deduped.append(item)
    return deduped[:4]


def extract_personal_knowledge(user_message: str) -> list[dict]:
    """
    Extract personal facts about the user from their messages.
    Returns list of {category, fact, importance}.
    Categories: identity, work, relationships, routines, preferences, interests, goals, location
    """
    text = user_message.strip()
    if not text or len(text) < 12:
        return []
    lower = text.lower()

    # Skip commands and short questions
    if lower.endswith("?") and len(text) < 40:
        return []
    command_starts = ("open ", "close ", "search ", "run ", "set ", "turn ", "play ",
                      "mute", "unmute", "volume", "brightness", "remind me", "take a note",
                      "what's the", "what is the", "summarize")
    if any(lower.startswith(c) for c in command_starts):
        return []
    # Skip dismissive/conversational responses that aren't personal knowledge
    dismissive = (
        "i have not", "i haven't", "i don't know", "i dont know", "i'm not sure",
        "i am not sure", "i don't think", "i dont think", "i don't want to",
        "i dont want to", "no ", "nope", "not really", "nothing", "never mind",
        "forget it", "that's fine", "that is fine", "it's fine", "okay",
        "yes ", "yeah ", "sure ", "nah", "hmm", "huh",
        "you are not", "you're not", "you don't", "you do not",
        "i just", "i was just", "i already",
    )
    if any(lower.startswith(d) for d in dismissive) and len(text) < 60:
        return []

    results: List[dict] = []

    # Work patterns
    work_triggers = [
        (r"\b(?:i work|my work|my job|i do|my shift|my role|i am working)\b.{5,}", "work", 0.7),
        (r"\b(?:at work|my office|my boss|my manager|my team|my colleague)\b.{5,}", "work", 0.6),
        (r"\b(?:my shift is|i have a shift|shift (?:from|until|till|ends))\b.{3,}", "work", 0.7),
        (r"\b(?:i work at|i work for|i work in)\b.{3,}", "work", 0.8),
    ]
    # Relationship patterns
    rel_triggers = [
        (r"\b(?:my (?:mom|dad|mother|father|brother|sister|wife|husband|girlfriend|boyfriend|partner))\b.{3,}", "relationships", 0.7),
        (r"\b(?:my (?:friend|roommate|flatmate|classmate|colleague) \w+)\b", "relationships", 0.6),
        (r"\b(?:my (?:uncle|aunt|cousin|grandma|grandpa|grandmother|grandfather|relative))\b.{3,}", "relationships", 0.6),
    ]
    # Routine patterns
    routine_triggers = [
        (r"\b(?:i usually|i always|i normally|every (?:day|morning|evening|night|week))\b.{5,}", "routines", 0.6),
        (r"\b(?:i wake up|i sleep|i go to bed|i eat|i have (?:breakfast|lunch|dinner) at)\b.{3,}", "routines", 0.6),
        (r"\b(?:my routine|my schedule|i start my day)\b.{5,}", "routines", 0.7),
    ]
    # Preference patterns
    pref_triggers = [
        (r"\b(?:i (?:love|hate|prefer|like|dislike|enjoy|can't stand))\b.{5,}", "preferences", 0.6),
        (r"\b(?:my favorite|i'm a fan of|i'm into)\b.{3,}", "preferences", 0.6),
    ]
    # Interest/hobby patterns
    interest_triggers = [
        (r"\b(?:i'm (?:learning|studying|building|working on|interested in|passionate about))\b.{5,}", "interests", 0.7),
        (r"\b(?:my (?:hobby|passion|project|side project))\b.{3,}", "interests", 0.7),
    ]
    # Goal patterns
    goal_triggers = [
        (r"\b(?:i want to|i plan to|my goal|i'm trying to|i hope to|i aim to|one day i)\b.{5,}", "goals", 0.7),
        (r"\b(?:i'm going to|i will|i'm planning|in the future)\b.{5,}", "goals", 0.5),
    ]
    # Location patterns
    loc_triggers = [
        (r"\b(?:i live in|i'm from|i'm in|my apartment|my house|my place|i moved to)\b.{3,}", "location", 0.7),
        (r"\b(?:my city|my town|my neighborhood|my area)\b.{3,}", "location", 0.6),
    ]
    # Identity patterns
    id_triggers = [
        (r"\b(?:i am a|i'm a|i am an|i'm an)\b.{5,}", "identity", 0.8),
        (r"\b(?:my name is|i'm \w+ years old|i'm from|i study|i'm studying)\b.{3,}", "identity", 0.8),
    ]

    all_triggers = (work_triggers + rel_triggers + routine_triggers + pref_triggers +
                    interest_triggers + goal_triggers + loc_triggers + id_triggers)

    parts = re.split(r"[.\n]+", text)
    for raw in parts:
        p = raw.strip()
        if len(p) < 12 or len(p) > 250:
            continue
        pl = p.lower()
        for pattern, category, importance in all_triggers:
            if re.search(pattern, pl):
                # Clean the fact — remove filler words at start
                fact = p.strip()
                results.append({"category": category, "fact": fact, "importance": importance})
                break  # one category per sentence

    # Deduplicate
    seen: set = set()
    unique: List[dict] = []
    for r in results:
        key = r["fact"].lower()[:50]
        if key not in seen:
            seen.add(key)
            unique.append(r)
    return unique[:4]


def generate_daily_summary(
    turns: list[tuple[str, str]],
    life_events: list[dict],
    moods: list[tuple[str, float]],
) -> tuple[str, str, str]:
    """
    Generate a daily summary from conversation turns, life events, and mood data.
    Returns (summary_text, mood_trend_label, key_topics_csv).
    No LLM call — pure heuristic extraction.
    """
    # Extract topics from user turns
    topics: List[str] = []
    user_messages = [content for role, content in turns if role == "user"]
    topic_keywords = {
        "work": ["shift", "work", "job", "office", "meeting", "project", "deadline", "boss"],
        "study": ["exam", "class", "assignment", "homework", "study", "university", "professor"],
        "social": ["dinner", "party", "friends", "family", "relatives", "birthday", "wedding"],
        "health": ["doctor", "gym", "exercise", "walk", "tired", "sick", "medicine", "hospital"],
        "orbit": ["orbit", "feature", "bug", "fix", "implement", "code", "development"],
        "food": ["lunch", "dinner", "breakfast", "coffee", "eat", "restaurant", "cook"],
        "travel": ["drive", "flight", "airport", "trip", "travel", "commute"],
        "entertainment": ["movie", "music", "game", "netflix", "youtube", "read", "book"],
        "shopping": ["buy", "order", "amazon", "store", "shop", "purchase"],
    }
    topic_counts: dict = {}
    for msg in user_messages:
        lower = msg.lower()
        for topic, keywords in topic_keywords.items():
            if any(kw in lower for kw in keywords):
                topic_counts[topic] = topic_counts.get(topic, 0) + 1

    top_topics = sorted(topic_counts.items(), key=lambda x: x[1], reverse=True)[:4]
    topics_csv = ", ".join(t[0] for t in top_topics) if top_topics else "general"

    # Mood summary
    if moods:
        avg_score = sum(s for _, s in moods) / len(moods)
        if avg_score > 0.3:
            mood_label = "positive"
        elif avg_score < -0.3:
            mood_label = "low"
        elif avg_score < -0.1:
            mood_label = "slightly-low"
        else:
            mood_label = "neutral"
        from collections import Counter
        mood_words = Counter(e for e, _ in moods).most_common(2)
        mood_str = f"{mood_label} ({', '.join(f'{e}' for e, _ in mood_words)})"
    else:
        mood_str = "neutral"
        mood_label = "neutral"

    # Build summary from life events + topics
    parts: List[str] = []

    # Life events
    plans = [ev for ev in life_events if ev.get("category") == "plan"]
    updates = [ev for ev in life_events if ev.get("category") == "life-update"]
    feelings = [ev for ev in life_events if ev.get("category") == "feeling"]

    if plans:
        plan_summaries = "; ".join(ev["summary"][:60] for ev in plans[:3])
        parts.append(f"Plans: {plan_summaries}")
    if updates:
        update_summaries = "; ".join(ev["summary"][:60] for ev in updates[:3])
        parts.append(f"Updates: {update_summaries}")
    if feelings:
        feeling_summaries = "; ".join(ev["summary"][:60] for ev in feelings[:2])
        parts.append(f"Feelings: {feeling_summaries}")

    # Conversation volume
    parts.append(f"Had {len(user_messages)} conversation{'s' if len(user_messages) != 1 else ''}")
    if top_topics:
        parts.append(f"Topics: {topics_csv}")
    parts.append(f"Mood: {mood_str}")

    summary = ". ".join(parts) + "."
    return summary, mood_label, topics_csv


def detect_emotion(user_message: str) -> Optional[tuple[str, float]]:
    """
    Detect the emotional tone of a user message.
    Returns (emotion_label, score) where score is -1.0 (very negative) to +1.0 (very positive).
    Returns None if the message is emotionally neutral (commands, questions, etc.).
    """
    text = user_message.strip().lower()
    if not text or len(text) < 5:
        return None
    # Skip commands and questions
    command_starts = ("open ", "close ", "search ", "run ", "set ", "turn ", "play ",
                      "mute", "unmute", "volume", "brightness", "remind me", "take a note",
                      "what's the", "what is the", "how is the", "check ")
    if any(text.startswith(c) for c in command_starts):
        return None
    if text.endswith("?") and len(text) < 40:
        return None

    # Positive emotions
    strong_positive = ("so happy", "really excited", "amazing", "fantastic", "incredible",
                       "best day", "love it", "so proud", "wonderful", "thrilled", "overjoyed")
    mild_positive = ("happy", "excited", "glad", "enjoying", "fun", "nice", "good day",
                     "great", "looking forward", "can't wait", "feels good", "pleased",
                     "grateful", "thankful", "relieved", "satisfied", "comfortable")

    # Negative emotions
    strong_negative = ("so stressed", "really worried", "terrible", "awful", "worst",
                       "devastated", "heartbroken", "furious", "miserable", "depressed",
                       "overwhelmed", "can't handle", "falling apart", "breaking down")
    mild_negative = ("stressed", "worried", "nervous", "anxious", "tired", "exhausted",
                     "frustrated", "annoyed", "bored", "lonely", "sad", "upset",
                     "disappointed", "confused", "uncertain", "rough day", "bad day",
                     "not feeling great", "not good", "feeling down", "feeling low")

    # Low energy
    low_energy = ("tired", "exhausted", "sleepy", "drained", "burned out", "burnt out",
                  "wiped out", "no energy", "so done", "need a break", "long day")

    for phrase in strong_positive:
        if phrase in text:
            return ("very-positive", 0.9)
    for phrase in strong_negative:
        if phrase in text:
            return ("very-negative", -0.9)
    for phrase in mild_positive:
        if phrase in text:
            return ("positive", 0.5)
    for phrase in low_energy:
        if phrase in text:
            return ("low-energy", -0.3)
    for phrase in mild_negative:
        if phrase in text:
            return ("negative", -0.5)

    # Sentiment from "I feel/I'm feeling" patterns
    feel_match = re.search(r"\bi(?:'m| am| feel| was)\s+(\w+)", text)
    if feel_match:
        feeling = feel_match.group(1)
        pos_feelings = {"happy", "excited", "great", "good", "amazing", "wonderful", "blessed",
                        "grateful", "proud", "relaxed", "calm", "hopeful", "motivated"}
        neg_feelings = {"sad", "stressed", "worried", "anxious", "tired", "frustrated",
                        "angry", "upset", "overwhelmed", "confused", "lost", "stuck",
                        "nervous", "scared", "afraid", "lonely", "bored"}
        if feeling in pos_feelings:
            return ("positive", 0.5)
        if feeling in neg_feelings:
            return ("negative", -0.5)

    return None


def extract_life_events(user_message: str) -> list[dict]:
    """
    Extract life events, plans, and feelings from user messages.
    Returns list of dicts: {summary, category, emotion, event_date, importance}
    """
    text = user_message.strip()
    if not text or len(text) < 15:
        return []

    lower = text.lower()
    # Skip questions, commands, and very short messages
    if lower.endswith("?") and len(text) < 60:
        return []
    command_starts = ("open ", "close ", "search ", "run ", "set ", "turn ", "play ",
                      "mute", "unmute", "volume", "brightness", "remind me")
    if any(lower.startswith(c) for c in command_starts):
        return []

    events: List[dict] = []

    # Plan/schedule triggers
    plan_triggers = (
        "i have to", "i need to", "i'm going to", "i am going to",
        "i will", "i'll", "i have a", "i'm having",
        "tonight", "tomorrow", "this evening", "this afternoon",
        "after work", "after my shift", "later today", "this weekend",
        "next week", "on monday", "on tuesday", "on wednesday",
        "on thursday", "on friday", "on saturday", "on sunday",
    )
    # Feeling/emotion triggers
    feeling_triggers = (
        "i feel", "i'm feeling", "i am feeling",
        "i'm stressed", "i'm tired", "i'm excited", "i'm happy",
        "i'm worried", "i'm nervous", "i'm sad",
        "i'm bored", "i'm frustrated", "i'm overwhelmed",
        "it was great", "it was amazing", "it was terrible",
        "i had a great", "i had a bad", "i had a rough",
    )
    # Life update triggers
    life_triggers = (
        "i just", "i finished", "i completed", "i started",
        "i got", "i received", "i bought", "i ordered",
        "i met", "i spoke to", "i talked to", "i called",
        "i went to", "i visited", "i came from", "i'm coming from",
        "i'm at", "i am at", "i'm on my", "i am on my",
        "my shift", "my class", "my exam", "my interview",
        "i had dinner", "i had lunch", "i had breakfast",
        "birthday", "party", "wedding", "graduation",
        "doctor", "appointment", "meeting with",
    )

    parts = re.split(r"[.\n]+", text)
    for raw in parts:
        p = raw.strip()
        if len(p) < 12 or len(p) > 300:
            continue
        pl = p.lower()

        # Determine category and emotion
        category = "general"
        emotion = None
        importance = 0.5

        has_plan = any(t in pl for t in plan_triggers)
        has_feeling = any(t in pl for t in feeling_triggers)
        has_life = any(t in pl for t in life_triggers)

        if not (has_plan or has_feeling or has_life):
            continue

        if has_plan:
            category = "plan"
            importance = 0.7
        if has_feeling:
            category = "feeling" if not has_plan else category
            importance = max(importance, 0.6)
            # Detect specific emotions
            if any(w in pl for w in ("stressed", "worried", "nervous", "anxious", "overwhelmed")):
                emotion = "stressed"
            elif any(w in pl for w in ("excited", "happy", "great", "amazing", "awesome")):
                emotion = "positive"
            elif any(w in pl for w in ("sad", "terrible", "bad", "rough", "frustrated")):
                emotion = "negative"
            elif any(w in pl for w in ("tired", "bored", "exhausted")):
                emotion = "low-energy"
        if has_life:
            category = "life-update" if category == "general" else category
            importance = max(importance, 0.6)

        # Extract event date hint
        event_date = None
        if "tonight" in pl or "this evening" in pl:
            event_date = "today-evening"
        elif "tomorrow" in pl:
            event_date = "tomorrow"
        elif "today" in pl or "right now" in pl:
            event_date = "today"
        elif "this weekend" in pl:
            event_date = "weekend"
        elif "next week" in pl:
            event_date = "next-week"

        events.append({
            "summary": p,
            "category": category,
            "emotion": emotion,
            "event_date": event_date,
            "importance": importance,
        })

    return events[:3]


def score_memory_candidate(text: str) -> float:
    """
    Heuristic importance score in [0, 1].
    Higher = more likely durable preference/identity/context.
    """
    s = text.strip().lower()
    if not s:
        return 0.0
    score = 0.2
    if len(s) >= 20:
        score += 0.08
    if len(s) >= 40:
        score += 0.06
    strong_signals = (
        "i prefer",
        "i don't like",
        "i am ",
        "i'm ",
        "my goal",
        "we are building",
        "my schedule",
    )
    medium_signals = (
        "i like",
        "i need",
        "i want",
        "i usually",
        "i use",
        "my ",
    )
    if any(k in s for k in strong_signals):
        score += 0.35
    elif any(k in s for k in medium_signals):
        score += 0.22

    transient = ("today", "tomorrow", "right now", "this morning", "this evening")
    if any(k in s for k in transient):
        score -= 0.15
    if s.endswith("?"):
        score -= 0.2
    return max(0.0, min(1.0, score))


def extract_scored_candidate_memories(user_message: str) -> list[Tuple[str, float]]:
    return [(c, score_memory_candidate(c)) for c in extract_candidate_memories(user_message)]


def conflict_signature(text: str) -> Optional[str]:
    """
    Coarse signature for preference statements so new info can replace
    old conflicting memories in the same bucket.
    """
    s = text.strip().lower()
    patterns = (
        r"^i (?:prefer|like|don't like)\s+(.+)$",
        r"^my (?:preferred|favorite)\s+(.+)$",
        r"^i use\s+(.+)$",
        r"^i usually\s+(.+)$",
    )
    for pat in patterns:
        m = re.match(pat, s)
        if not m:
            continue
        tail = m.group(1)
        toks = [t for t in tokenize(tail) if t not in {"a", "an", "the", "to", "for", "of"}]
        if not toks:
            return None
        return "pref:" + "-".join(toks[:3])
    return None
