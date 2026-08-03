from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from app.models import Message
from app.semantic_memory import (
    cosine_similarity,
    embed_text,
    get_embed_dims,
    get_embed_model_key,
)


class MemoryStore:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(str(self.db_path))

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS turns (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS semantic_facts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    fact TEXT NOT NULL UNIQUE,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS semantic_vectors (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT NOT NULL UNIQUE,
                    vector_json TEXT NOT NULL,
                    source TEXT NOT NULL DEFAULT 'auto',
                    importance REAL NOT NULL DEFAULT 0.5,
                    conflict_sig TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS style_prefs (
                    key TEXT PRIMARY KEY,
                    score REAL NOT NULL DEFAULT 0.0,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS embedding_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )
            # Small key/value store for bookkeeping that isn't user data — e.g. how far the
            # memory extractor has read, so it never re-processes the same conversation.
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS personal_knowledge (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    category TEXT NOT NULL,
                    fact TEXT NOT NULL,
                    importance REAL NOT NULL DEFAULT 0.5,
                    source_turn TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS proactive_checkins (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    topic TEXT NOT NULL,
                    question_asked TEXT NOT NULL,
                    response_sentiment TEXT,
                    follow_up_state TEXT NOT NULL DEFAULT 'pending',
                    last_asked_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    follow_up_after DATETIME,
                    attempts INTEGER NOT NULL DEFAULT 1,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS daily_summaries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    day_date TEXT NOT NULL UNIQUE,
                    summary TEXT NOT NULL,
                    mood_trend TEXT,
                    key_topics TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS mood_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    emotion TEXT NOT NULL,
                    score REAL NOT NULL DEFAULT 0.0,
                    source_text TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS life_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    summary TEXT NOT NULL,
                    category TEXT NOT NULL DEFAULT 'general',
                    emotion TEXT,
                    event_date TEXT,
                    importance REAL NOT NULL DEFAULT 0.5,
                    is_resolved INTEGER NOT NULL DEFAULT 0,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            # Backward-compatible migration for existing DBs.
            try:
                conn.execute(
                    "ALTER TABLE semantic_vectors ADD COLUMN importance REAL NOT NULL DEFAULT 0.5"
                )
            except sqlite3.OperationalError:
                pass
            try:
                conn.execute("ALTER TABLE semantic_vectors ADD COLUMN conflict_sig TEXT")
            except sqlite3.OperationalError:
                pass
            conn.commit()

    def append_turn(self, session_id: str, role: str, content: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO turns (session_id, role, content) VALUES (?, ?, ?)",
                (session_id, role, content),
            )
            conn.commit()

    def recent_turns(self, session_id: str, limit: int = 8) -> list[Message]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT role, content
                FROM turns
                WHERE session_id = ?
                ORDER BY id DESC
                LIMIT ?
                """,
                (session_id, limit),
            ).fetchall()
        rows.reverse()
        return [Message(role=row[0], content=row[1]) for row in rows]

    def add_fact(self, fact: str) -> None:
        text = fact.strip()
        if not text:
            return
        with self._connect() as conn:
            # Preserve stable row ids (INSERT OR REPLACE would churn ids on UNIQUE conflicts).
            conn.execute("INSERT OR IGNORE INTO semantic_facts (fact) VALUES (?)", (text,))
            conn.commit()

    def delete_fact(self, fact_id: int) -> bool:
        with self._connect() as conn:
            cur = conn.execute("DELETE FROM semantic_facts WHERE id = ?", (fact_id,))
            conn.commit()
        return cur.rowcount > 0

    def list_fact_records(self, limit: int = 50) -> list[tuple[int, str]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, fact FROM semantic_facts
                ORDER BY id DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [(int(r[0]), r[1]) for r in rows]

    def recent_facts(self, limit: int = 12) -> list[str]:
        return [text for _, text in self.list_fact_records(limit=limit)]

    # --- Minimal semantic memory scaffold ---
    def add_semantic_memory(
        self,
        text: str,
        *,
        source: str = "auto",
        importance: float = 0.6,
        conflict_sig: Optional[str] = None,
    ) -> None:
        cleaned = text.strip()
        if not cleaned:
            return
        vec = embed_text(cleaned)
        imp = max(0.0, min(1.0, float(importance)))
        with self._connect() as conn:
            sig = (conflict_sig or "").strip() or None
            if sig is not None:
                conn.execute(
                    "DELETE FROM semantic_vectors WHERE conflict_sig = ? AND text <> ?",
                    (sig, cleaned),
                )
            conn.execute(
                """
                INSERT INTO semantic_vectors (text, vector_json, source, importance, conflict_sig)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(text) DO UPDATE SET
                    vector_json=excluded.vector_json,
                    source=excluded.source,
                    importance=MAX(semantic_vectors.importance, excluded.importance),
                    conflict_sig=COALESCE(excluded.conflict_sig, semantic_vectors.conflict_sig),
                    created_at=CURRENT_TIMESTAMP
                """,
                (cleaned, json.dumps(vec), source.strip() or "auto", imp, sig),
            )
            conn.commit()

    def semantic_search(
        self,
        query: str,
        *,
        limit: int = 3,
        min_score: float = 0.56,
    ) -> list[str]:
        q = query.strip()
        if not q:
            return []
        qvec = embed_text(q)
        scored: list[tuple[float, str]] = []
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT text, vector_json, importance, created_at FROM semantic_vectors ORDER BY id DESC LIMIT 400"
            ).fetchall()
        for text, vec_json, importance, created_at in rows:
            try:
                dvec = json.loads(vec_json)
            except Exception:
                continue
            sim = cosine_similarity(qvec, dvec)
            imp = max(0.0, min(1.0, float(importance or 0.5)))
            recency = self._recency_score(str(created_at))
            # Rank = semantic relevance + memory importance + recency.
            rank = (0.62 * sim) + (0.28 * imp) + (0.10 * recency)
            if rank >= min_score:
                scored.append((rank, str(text)))
        scored.sort(key=lambda x: x[0], reverse=True)
        return [t for _, t in scored[: max(1, limit)]]

    def list_semantic_records(self, limit: int = 80) -> list[tuple[int, str, str, float]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, text, source, importance
                FROM semantic_vectors
                ORDER BY id DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [(int(r[0]), str(r[1]), str(r[2]), float(r[3])) for r in rows]

    def delete_semantic_memory(self, memory_id: int) -> bool:
        with self._connect() as conn:
            cur = conn.execute("DELETE FROM semantic_vectors WHERE id = ?", (memory_id,))
            conn.commit()
        return cur.rowcount > 0

    def set_semantic_memory_importance(self, memory_id: int, importance: float) -> bool:
        imp = max(0.0, min(1.0, float(importance)))
        with self._connect() as conn:
            cur = conn.execute(
                "UPDATE semantic_vectors SET importance = ? WHERE id = ?",
                (imp, memory_id),
            )
            conn.commit()
        return cur.rowcount > 0

    def clear_semantic_memory(self) -> int:
        with self._connect() as conn:
            cur = conn.execute("DELETE FROM semantic_vectors")
            conn.commit()
        return int(cur.rowcount or 0)

    # --- Embedding model migration ---

    def _get_stored_embed_meta(self) -> Optional[tuple[str, int]]:
        """Returns (model_key, dims) from DB, or None if not recorded yet."""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT key, value FROM embedding_meta WHERE key IN ('model', 'dims')"
            ).fetchall()
        d = {r[0]: r[1] for r in rows}
        if "model" not in d or "dims" not in d:
            return None
        try:
            return (d["model"], int(d["dims"]))
        except (ValueError, KeyError):
            return None

    def _update_embed_meta(self, model_key: str, dims: int) -> None:
        with self._connect() as conn:
            for k, v in [("model", model_key), ("dims", str(dims))]:
                conn.execute(
                    "INSERT INTO embedding_meta (key, value) VALUES (?, ?) "
                    "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    (k, v),
                )
            conn.commit()

    def migrate_embeddings_if_needed(self) -> int:
        """
        Re-embed all stored vectors when the current embedding model/dims
        differ from what was used to build the stored vectors.
        Returns the number of rows re-embedded (0 if already up to date).
        Safe to call on every startup — no-ops if nothing changed.
        """
        current_model = get_embed_model_key()
        current_dims = get_embed_dims()
        stored = self._get_stored_embed_meta()

        if stored is not None:
            stored_model, stored_dims = stored
            if stored_model == current_model and stored_dims == current_dims:
                return 0

        with self._connect() as conn:
            rows = conn.execute("SELECT id, text FROM semantic_vectors").fetchall()

        count = 0
        for row_id, text in rows:
            try:
                new_vec = embed_text(str(text))
                with self._connect() as conn:
                    conn.execute(
                        "UPDATE semantic_vectors SET vector_json=? WHERE id=?",
                        (json.dumps(new_vec), row_id),
                    )
                    conn.commit()
                count += 1
            except Exception:
                continue

        self._update_embed_meta(current_model, current_dims)
        return count

    def prune_semantic_memory(self, *, retention_days: int, max_items: int) -> int:
        """
        Deletes old/overflow semantic memories.
        Returns total rows removed.
        """
        deleted = 0
        with self._connect() as conn:
            # Age-based pruning first.
            cur_age = conn.execute(
                """
                DELETE FROM semantic_vectors
                WHERE julianday('now') - julianday(created_at) > ?
                """,
                (retention_days,),
            )
            deleted += int(cur_age.rowcount or 0)

            count_row = conn.execute("SELECT COUNT(*) FROM semantic_vectors").fetchone()
            total = int(count_row[0]) if count_row else 0
            overflow = max(0, total - max_items)
            if overflow > 0:
                cur_overflow = conn.execute(
                    """
                    DELETE FROM semantic_vectors
                    WHERE id IN (
                        SELECT id
                        FROM semantic_vectors
                        ORDER BY id ASC
                        LIMIT ?
                    )
                    """,
                    (overflow,),
                )
                deleted += int(cur_overflow.rowcount or 0)
            conn.commit()
        return deleted

    def semantic_memory_stats(self) -> dict[str, int]:
        with self._connect() as conn:
            total_turns = int(conn.execute("SELECT COUNT(*) FROM turns").fetchone()[0] or 0)
            total_facts = int(conn.execute("SELECT COUNT(*) FROM semantic_facts").fetchone()[0] or 0)
            total_semantic = int(conn.execute("SELECT COUNT(*) FROM semantic_vectors").fetchone()[0] or 0)
            manual_semantic = int(
                conn.execute("SELECT COUNT(*) FROM semantic_vectors WHERE source = 'manual'").fetchone()[0] or 0
            )
            auto_semantic = int(
                conn.execute("SELECT COUNT(*) FROM semantic_vectors WHERE source = 'auto'").fetchone()[0] or 0
            )
        return {
            "turns": total_turns,
            "facts": total_facts,
            "semantic_total": total_semantic,
            "semantic_manual": manual_semantic,
            "semantic_auto": auto_semantic,
        }

    # --- Personal knowledge profile ---

    def add_personal_knowledge(self, category: str, fact: str, importance: float = 0.5,
                                source_turn: str = "") -> None:
        cleaned = fact.strip()
        if not cleaned:
            return
        imp = max(0.0, min(1.0, float(importance)))
        with self._connect() as conn:
            # Check for duplicate/similar facts in same category
            existing = conn.execute(
                "SELECT id, fact FROM personal_knowledge WHERE category = ?",
                (category,),
            ).fetchall()
            for row_id, existing_fact in existing:
                # If very similar fact exists, update instead of duplicate
                if self._facts_similar(cleaned.lower(), existing_fact.lower()):
                    conn.execute(
                        "UPDATE personal_knowledge SET fact=?, importance=MAX(importance, ?), "
                        "updated_at=CURRENT_TIMESTAMP WHERE id=?",
                        (cleaned, imp, row_id),
                    )
                    conn.commit()
                    return
            conn.execute(
                "INSERT INTO personal_knowledge (category, fact, importance, source_turn) VALUES (?, ?, ?, ?)",
                (category, cleaned, imp, source_turn[:200]),
            )
            conn.commit()

    def get_core_profile(self, max_per_category: int = 3) -> dict[str, list[str]]:
        """Returns the top facts per category for the always-on core profile."""
        categories = ["identity", "work", "relationships", "routines", "preferences",
                       "interests", "goals", "location"]
        profile: dict[str, list[str]] = {}
        with self._connect() as conn:
            for cat in categories:
                rows = conn.execute(
                    """
                    SELECT fact FROM personal_knowledge
                    WHERE category = ?
                    ORDER BY importance DESC, updated_at DESC
                    LIMIT ?
                    """,
                    (cat, max_per_category),
                ).fetchall()
                if rows:
                    profile[cat] = [str(r[0]) for r in rows]
        return profile

    def search_personal_knowledge(self, query: str, limit: int = 5) -> list[dict]:
        """Keyword search in personal knowledge for relevant context injection."""
        words = query.lower().split()
        if not words:
            return []
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT category, fact, importance FROM personal_knowledge ORDER BY importance DESC, updated_at DESC LIMIT 100"
            ).fetchall()
        scored = []
        for cat, fact, imp in rows:
            fact_lower = fact.lower()
            matches = sum(1 for w in words if w in fact_lower and len(w) >= 3)
            if matches > 0:
                score = matches * 0.4 + float(imp) * 0.6
                scored.append({"category": str(cat), "fact": str(fact), "score": score})
        scored.sort(key=lambda x: x["score"], reverse=True)
        return scored[:limit]

    def personal_knowledge_stats(self) -> dict[str, int]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT category, COUNT(*) FROM personal_knowledge GROUP BY category"
            ).fetchall()
        return {str(r[0]): int(r[1]) for r in rows}

    @staticmethod
    def _facts_similar(a: str, b: str) -> bool:
        """Simple similarity: if 70%+ of words overlap, consider them the same fact."""
        wa = set(a.split())
        wb = set(b.split())
        if not wa or not wb:
            return False
        overlap = len(wa & wb)
        return overlap / min(len(wa), len(wb)) > 0.7

    # --- Proactive care engine ---

    def log_proactive_checkin(self, topic: str, question: str) -> int:
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO proactive_checkins (topic, question_asked) VALUES (?, ?)",
                (topic, question),
            )
            conn.commit()
            return cur.lastrowid or 0

    def update_checkin_response(self, checkin_id: int, sentiment: str, follow_up_state: str,
                                 follow_up_after: Optional[str] = None) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE proactive_checkins
                SET response_sentiment=?, follow_up_state=?, follow_up_after=?
                WHERE id=?
                """,
                (sentiment, follow_up_state, follow_up_after, checkin_id),
            )
            conn.commit()

    def has_asked_about(self, topic: str, within_hours: int = 48) -> bool:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT COUNT(*) FROM proactive_checkins
                WHERE topic = ? AND datetime(last_asked_at) > datetime('now', ?)
                """,
                (topic, f"-{within_hours} hours"),
            ).fetchone()
        return int(row[0]) > 0 if row else False

    def pending_follow_ups(self) -> list[dict]:
        """Returns topics that need a gentle follow-up (negative response, cooldown passed)."""
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, topic, question_asked, response_sentiment, attempts FROM proactive_checkins
                WHERE follow_up_state = 'needs-follow-up'
                  AND (follow_up_after IS NULL OR datetime('now') > datetime(follow_up_after))
                  AND attempts < 3
                ORDER BY created_at DESC
                LIMIT 5
                """,
            ).fetchall()
        return [
            {"id": r[0], "topic": r[1], "question": r[2], "sentiment": r[3], "attempts": r[4]}
            for r in rows
        ]

    def mark_checkin_resolved(self, checkin_id: int) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE proactive_checkins SET follow_up_state='resolved' WHERE id=?",
                (checkin_id,),
            )
            conn.commit()

    def increment_checkin_attempt(self, checkin_id: int, next_follow_up_hours: int = 24) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE proactive_checkins
                SET attempts = attempts + 1,
                    last_asked_at = CURRENT_TIMESTAMP,
                    follow_up_after = datetime('now', ?)
                WHERE id = ?
                """,
                (f"+{next_follow_up_hours} hours", checkin_id),
            )
            conn.commit()

    # --- Daily summaries for multi-day context ---

    def save_daily_summary(self, day_date: str, summary: str, mood_trend: str = "",
                           key_topics: str = "") -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO daily_summaries (day_date, summary, mood_trend, key_topics)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(day_date) DO UPDATE SET
                    summary=excluded.summary,
                    mood_trend=excluded.mood_trend,
                    key_topics=excluded.key_topics,
                    created_at=CURRENT_TIMESTAMP
                """,
                (day_date, summary.strip(), mood_trend, key_topics),
            )
            conn.commit()

    def recent_daily_summaries(self, days: int = 7) -> list[dict]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT day_date, summary, mood_trend, key_topics FROM daily_summaries
                WHERE julianday('now') - julianday(day_date) <= ?
                ORDER BY day_date DESC
                LIMIT ?
                """,
                (days + 1, days),
            ).fetchall()
        return [
            {"date": r[0], "summary": r[1], "mood": r[2], "topics": r[3]}
            for r in rows
        ]

    def has_summary_for_date(self, day_date: str) -> bool:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) FROM daily_summaries WHERE day_date = ?",
                (day_date,),
            ).fetchone()
        return int(row[0]) > 0 if row else False

    def turns_for_date(self, session_id: str, day_date: str) -> list[tuple[str, str]]:
        """Returns (role, content) pairs for a specific date."""
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT role, content FROM turns
                WHERE session_id = ? AND date(created_at) = ?
                ORDER BY id ASC
                """,
                (session_id, day_date),
            ).fetchall()
        return [(str(r[0]), str(r[1])) for r in rows]

    def life_events_for_date(self, day_date: str) -> list[dict]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT summary, category, emotion, event_date FROM life_events
                WHERE date(created_at) = ?
                ORDER BY created_at ASC
                """,
                (day_date,),
            ).fetchall()
        return [
            {"summary": r[0], "category": r[1], "emotion": r[2], "event_date": r[3]}
            for r in rows
        ]

    def mood_for_date(self, day_date: str) -> list[tuple[str, float]]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT emotion, score FROM mood_log
                WHERE date(created_at) = ?
                ORDER BY created_at ASC
                """,
                (day_date,),
            ).fetchall()
        return [(str(r[0]), float(r[1])) for r in rows]

    def compress_old_summaries(self) -> int:
        """Compress daily summaries older than 7 days into weekly summaries,
        and weekly summaries older than 30 days into monthly summaries."""
        compressed = 0
        with self._connect() as conn:
            # Find weeks with 3+ daily summaries older than 7 days that aren't compressed yet
            rows = conn.execute(
                """
                SELECT strftime('%Y-W%W', day_date) as week_key,
                       GROUP_CONCAT(summary, ' | ') as combined,
                       GROUP_CONCAT(mood_trend) as moods,
                       GROUP_CONCAT(key_topics) as topics,
                       MIN(day_date) as start_date, MAX(day_date) as end_date
                FROM daily_summaries
                WHERE julianday('now') - julianday(day_date) > 7
                  AND day_date NOT LIKE 'week-%'
                  AND day_date NOT LIKE 'month-%'
                GROUP BY week_key
                HAVING COUNT(*) >= 2
                """,
            ).fetchall()
            for week_key, combined, moods, topics, start_date, end_date in rows:
                # Create a compressed weekly summary
                parts = combined.split(" | ")
                short = ". ".join(p[:80] for p in parts[:5])
                if len(short) > 400:
                    short = short[:400] + "..."
                mood_list = [m for m in (moods or "").split(",") if m.strip()]
                from collections import Counter
                top_mood = Counter(mood_list).most_common(1)
                mood_label = top_mood[0][0] if top_mood else "neutral"
                topic_set = set(t.strip() for t in (topics or "").split(",") if t.strip())
                topics_csv = ", ".join(list(topic_set)[:5])
                week_date_key = f"week-{week_key}"
                conn.execute(
                    """
                    INSERT OR REPLACE INTO daily_summaries (day_date, summary, mood_trend, key_topics)
                    VALUES (?, ?, ?, ?)
                    """,
                    (week_date_key, f"Week of {start_date}: {short}", mood_label, topics_csv),
                )
                # Remove the individual daily entries that were compressed
                conn.execute(
                    "DELETE FROM daily_summaries WHERE day_date >= ? AND day_date <= ? AND day_date NOT LIKE 'week-%'",
                    (start_date, end_date),
                )
                compressed += 1
            conn.commit()
        return compressed

    def prune_daily_summaries(self, retention_days: int = 90) -> int:
        with self._connect() as conn:
            cur = conn.execute(
                "DELETE FROM daily_summaries WHERE julianday('now') - julianday(day_date) > ?",
                (retention_days,),
            )
            conn.commit()
        return int(cur.rowcount or 0)

    # --- Emotional state tracking ---

    def log_mood(self, emotion: str, score: float, source_text: str = "") -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO mood_log (emotion, score, source_text) VALUES (?, ?, ?)",
                (emotion, max(-1.0, min(1.0, score)), source_text[:200]),
            )
            conn.commit()

    def mood_trend(self, hours: int = 24) -> dict:
        """Returns the emotional trend over the last N hours."""
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT emotion, score, created_at FROM mood_log
                WHERE datetime(created_at) > datetime('now', ?)
                ORDER BY created_at DESC
                LIMIT 30
                """,
                (f"-{hours} hours",),
            ).fetchall()
        if not rows:
            return {"baseline": 0.0, "trend": "neutral", "recent_emotions": [], "count": 0}

        scores = [float(r[1]) for r in rows]
        emotions = [str(r[0]) for r in rows]

        # Exponential weighted average — recent moods matter more
        weights = [0.9 ** i for i in range(len(scores))]
        total_weight = sum(weights)
        baseline = sum(s * w for s, w in zip(scores, weights)) / total_weight if total_weight > 0 else 0.0

        if baseline > 0.3:
            trend = "positive"
        elif baseline < -0.3:
            trend = "low"
        elif baseline < -0.1:
            trend = "slightly-low"
        else:
            trend = "neutral"

        # Most frequent recent emotion
        from collections import Counter
        top_emotions = Counter(emotions).most_common(3)

        return {
            "baseline": round(baseline, 2),
            "trend": trend,
            "recent_emotions": [(e, c) for e, c in top_emotions],
            "count": len(rows),
        }

    def prune_mood_log(self, retention_days: int = 30) -> int:
        with self._connect() as conn:
            cur = conn.execute(
                "DELETE FROM mood_log WHERE julianday('now') - julianday(created_at) > ?",
                (retention_days,),
            )
            conn.commit()
        return int(cur.rowcount or 0)

    # --- Episodic life event memory ---

    def add_life_event(
        self,
        summary: str,
        *,
        category: str = "general",
        emotion: Optional[str] = None,
        event_date: Optional[str] = None,
        importance: float = 0.5,
    ) -> None:
        cleaned = summary.strip()
        if not cleaned:
            return
        imp = max(0.0, min(1.0, float(importance)))
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO life_events (summary, category, emotion, event_date, importance)
                VALUES (?, ?, ?, ?, ?)
                """,
                (cleaned, category, emotion, event_date, imp),
            )
            conn.commit()

    def recent_life_events(self, limit: int = 10, days: int = 3) -> list[dict]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT id, summary, category, emotion, event_date, importance, is_resolved, created_at
                FROM life_events
                WHERE julianday('now') - julianday(created_at) <= ?
                  AND is_resolved = 0
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (days, limit),
            ).fetchall()
        return [
            {
                "id": r[0], "summary": r[1], "category": r[2], "emotion": r[3],
                "event_date": r[4], "importance": r[5], "is_resolved": r[6], "created_at": r[7],
            }
            for r in rows
        ]

    def resolve_life_event(self, event_id: int) -> bool:
        with self._connect() as conn:
            cur = conn.execute("UPDATE life_events SET is_resolved = 1 WHERE id = ?", (event_id,))
            conn.commit()
        return cur.rowcount > 0

    def prune_life_events(self, retention_days: int = 30) -> int:
        with self._connect() as conn:
            cur = conn.execute(
                "DELETE FROM life_events WHERE julianday('now') - julianday(created_at) > ?",
                (retention_days,),
            )
            conn.commit()
        return int(cur.rowcount or 0)

    # --- Adaptive conversation style memory (lightweight local preference tags) ---
    # ---- meta key/value -------------------------------------------------

    def get_meta(self, key: str, default: str = "") -> str:
        with self._connect() as conn:
            row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return str(row[0]) if row else default

    def set_meta(self, key: str, value: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO meta (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )

    def turns_after(self, session_id: str, after_id: int, limit: int = 40) -> list[tuple[int, str, str]]:
        """Rows newer than `after_id` as (id, role, content) — the extractor's read cursor."""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT id, role, content FROM turns WHERE session_id = ? AND id > ? "
                "ORDER BY id ASC LIMIT ?",
                (session_id, after_id, limit),
            ).fetchall()
        return [(int(r[0]), str(r[1]), str(r[2])) for r in rows]

    def latest_turn_id(self, session_id: str) -> int:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COALESCE(MAX(id), 0) FROM turns WHERE session_id = ?", (session_id,)
            ).fetchone()
        return int(row[0]) if row else 0

    def existing_knowledge_facts(self, limit: int = 120) -> list[str]:
        """Current facts, so the extractor can be told not to repeat what is already known."""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT fact FROM personal_knowledge ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
        return [str(r[0]) for r in rows]

    def style_preferences(self) -> dict[str, float]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT key, score FROM style_prefs ORDER BY key ASC"
            ).fetchall()
        out: dict[str, float] = {}
        for key, score in rows:
            try:
                out[str(key)] = max(-1.0, min(1.0, float(score)))
            except Exception:
                continue
        return out

    def bump_style_preference(self, key: str, delta: float) -> None:
        cleaned = key.strip().lower()
        if not cleaned:
            return
        d = max(-1.0, min(1.0, float(delta)))
        with self._connect() as conn:
            row = conn.execute(
                "SELECT score FROM style_prefs WHERE key = ?",
                (cleaned,),
            ).fetchone()
            current = float(row[0]) if row is not None else 0.0
            updated = max(-1.0, min(1.0, current + d))
            conn.execute(
                """
                INSERT INTO style_prefs (key, score, updated_at)
                VALUES (?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(key) DO UPDATE SET
                    score=excluded.score,
                    updated_at=CURRENT_TIMESTAMP
                """,
                (cleaned, updated),
            )
            conn.commit()

    @staticmethod
    def _recency_score(created_at: str) -> float:
        # SQLite CURRENT_TIMESTAMP format: YYYY-MM-DD HH:MM:SS
        try:
            dt = datetime.strptime(created_at, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
        except Exception:
            return 0.0
        age_days = max(0.0, (datetime.now(timezone.utc) - dt).total_seconds() / 86_400.0)
        # Smooth decay: recent memories keep stronger weight.
        return 1.0 / (1.0 + (age_days / 30.0))
