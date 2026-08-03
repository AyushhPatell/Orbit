# ORBIT Evolution Map

**Written:** 2026-08-03, after the "3 PM briefing" incident.
**What this is:** the complete list — every fix, improvement, and evolution across the whole system, small to large, ordered by what it does for the vision: a companion that says the right thing, at the right time, in the right words — and stays quiet the rest.

**Method honesty:** the core loops (prompt assembly, memory, nudging, voice commit, routing, brain protocol) were read line-by-line and the failing case was reproduced against real code and the real DB. The wider Swift surface (~23K lines) was mapped and spot-verified, not 100% read. Every claim below marked **[verified]** was proven by running code or querying data, not by reading.

---

## 0 · THE CASE — the 3 PM briefing (root cause, fully verified)

Four independent layers failed. Each is its own fix; together they produced the exact behaviour Ayush saw.

**Layer 1 — the ears committed a thought-pause.** [verified]
`OrbitSpeechInputController.swift:258` scales the silence window by transcript *length* — short transcript → shortest pause. A bare "Um" while thinking is the fastest possible commit, the exact opposite of what a thinking human needs. The only guard downstream (`OrbitWakeVoiceBackstage.swift:122`) is `!trimmed.isEmpty` — "Um" passes.

**Layer 2 — "Approach B" rewrote his message.** [verified — reconstructed byte-for-byte]
`main.py:673-684` prepends every non-PAST life event *into the user message*. What the brain actually received at 18:13 on Aug 2 (turns 1349-1350):

```
[Ayush's current context: UPCOMING NEXT WEEK: Reminders to buy tickets… |
 TODAY: User planned a quick breakfast this morning. |
 TODAY: Spiderman movie ticket reminder is set for 5 PM today. |
 UPCOMING NEXT WEEK: Call with Kan… deleted; call with Kawan… remains…]
Um
```

The model answered the only content present: the context block. The comment in code says it outright — *"This makes life events impossible to ignore."* Mission accomplished, in the worst way.

**Layer 3 — no intra-day staleness.** [verified]
`_temporal_label` labels a 10 AM "planning a quick breakfast" event `TODAY` forever — at 6 PM it still reads as *current*, so ORBIT said "you're planning a quick breakfast now."

**Layer 4 — no novelty guard.** [verified — turns 1351-1352]
The nudge system (`_get_nudge_candidates`) has a 48-hour dedupe — but Approach B has **none** and runs on **every turn**. His next utterance, "okay?", got the identical context block prepended, and the recital came back a second time.

### The fix package (proposed — awaiting approval)

1. **Filler-only commits never leave the Mac.** After `stripDisfluencies`, if nothing but filler remains and no question is pending: don't send — keep listening with an *extended* window. Silence is the human response to someone thinking.
2. **Kill Approach B; replace with a proactivity governor.** Life events return to the system prompt only (with ages, layer 3 below). A reply may volunteer at most **one** unprompted item, and only when: (a) the user's message is a greeting/opener or an explicit "what's up today", (b) the item is *novel* (never spoken before — tracked persistently, the way nudges already are), and (c) it's *timely* (due-soon beats historical). A substantive user message means: answer what he said, volunteer nothing.
3. **Ages, not labels.** Every injected memory carries "shared 5h ago"; routine items older than ~3h flip to "earlier today — likely already done; do not mention as current."
4. **Structural repetition guard.** Before returning, compare the candidate reply against the last assistant replies for the session; near-identical → strip the repeated content or regenerate once with "respond only to what he actually said." Prompting is not honesty, and prompting is not variety — this must be structural.
5. **Greet once.** "Afternoon, Ayush" at most once per conversational session, not per turn.

---

## 1 · URGENT — the GitHub push leaked a live key [verified]

- `.gitignore` covers `.env` — but **`orbit-core/.env.backup-2026-08-01` is tracked and pushed**, and it contains the OpenAI `CLOUD_API_KEY`. **Rotate that key today** (platform.openai.com → API keys → revoke + recreate), then `git rm` the backup. Rotation is the real fix — history scrubbing is optional after the key is dead.
- Also pushed, harmless but junk: the entire `.derivedData/` build tree (thousands of files), `.run/logs/*`, `orbit_core.egg-info`. Add to `.gitignore`: `.env*`, `!.env.example`, `.run/`, `.derivedData/`, `*.log`.
- **What did NOT leak:** `data/` is ignored — `orbit.db` (your personal memory) and `chat_audit.jsonl` stayed local. Verified.

---

## 2 · EARS — hearing like a person listens

| # | Item | Size |
|---|---|---|
| E1 | **Filler-only commit guard** (case fix #1). | S |
| E2 | **Invert the endpoint curve's bottom end**: near-empty transcript = *longer* wait, not shorter. The current curve punishes thinking. | S |
| E3 | **Semantic endpointing**: commit on *meaning-complete*, not silence alone. Industry standard is now silence (~800-1200 ms) + a completeness score over the partial transcript; the local Ollama/Foundation-Models tier can score "does this read finished?" — "remind me to…" hangs open, "remind me to call mom" commits. Kills both early-commit and long-sentence-cutoff classes at the source. | M |
| E4 | **Barge-in**: speaking while ORBIT talks should interrupt him (echo-cancelled listening during TTS, "stop/wait" without wake word). A companion is interruptible. | M |
| E5 | **Guest awareness**: "my friend Shruti is here, say hi" stored *Shruti's presence as an Ayush relationship fact* [verified in DB]. Detect the introduce-a-guest pattern → greet the guest, don't file their speech as Ayush's life. | S-M |
| E6 | **Speaker identity (long-term)**: on-device voice ID so ORBIT knows *who* is talking — respond to Ayush, politely handle others, never store guest speech as Ayush facts. Big companion payoff, heavy lift. | L |
| E7 | Wake-word false-positive hardening vs TV/ambient audio (energy + voice-match gate). The replay harness (`say -v Rishi/Aman/Tara`) is the right measurement tool and should become a fixture for every ears change. | M |

## 3 · MEMORY — the heart of the vision

| # | Item | Size |
|---|---|---|
| M1 | **Pollution sweep** (work-list #2): `personal_knowledge` is mostly raw transcript — "I want to delete few reminders" filed under *goals* [verified]. One-time cleanup pass (brain re-extracts real facts from the junk rows, deletes the rest), plus the same validators the new extractor already has. | S |
| M2 | **Temporal label bug** (work-list #3): after one day, `weekend`/`next-week` events are labelled `PAST (yesterday)` [verified by running it]. Future plans read as history — the inverse of the companion vision. Fix the fall-through; add proper day-of-week resolution. | S |
| M3 | **Event lifecycle**: planned → due → likely-done → confirmed/expired. The `is_resolved` column already exists and is never written [verified]. This unlocks the *right* follow-up ("how was the movie?" **after** 5 PM, never before) — the single highest-leverage companion feature on this list. | M |
| M4 | **Absolute timestamps rendered as ages** everywhere a memory enters a prompt ("5h ago", "yesterday morning") — models reason about ages far better than about labels. | S |
| M5 | **Stop recording tool operations as life events**: "Turned off sleep mode and adjusted brightness to 50%" is ORBIT's command log, not Ayush's life [verified in DB]. Filter category/source at extraction. | S |
| M6 | **Duplicate-turn bug**: "turn off the wifi" saved **six times** in the same second, one copy being raw plumbing ("set_system_feature: Wi-Fi is off.") as an assistant turn [verified, turns 1355-1366]. Likely the offline/retry path re-saving. Needs a trace-first diagnosis, then an idempotency key on turn saves. | M |
| M7 | **Nightly consolidation ("sleep cycle")**: dedupe (three Spider-Man entries, three Kan/Kawan entries [verified]), merge contradictions, promote stable episodic facts to semantic knowledge, decay importance, expire dated items. Current research separates an episodic buffer from event-driven semantic consolidation exactly this way. Runs on the brain overnight; ports to iOS unchanged. | M-L |
| M8 | **Entity resolution / personal knowledge graph**: "Kan" and "Kawan" are one person split by an STT mishear [verified — the calendar rename proves it]. Entities (people, places, projects) with relationships and event links, grounded against Contacts. Temporal knowledge graphs (Zep/Graphiti-style) are the state of the art for exactly this. The Kachuful entry shows the payoff: ORBIT knowing *what things are*, not just what was said. | L |
| M9 | **Provenance typing**: every memory records *who said it, when, in what context* — guards against role-collapse (Shruti's words becoming Ayush's facts) and contamination, both active research problems with known designs. | M |
| M10 | Session-scoped `session_id` review: everything is one eternal session today; real session boundaries (wake→farewell) would give "recent turns" honest meaning. | M |

## 4 · VOICE — when to speak, what to say

| # | Item | Size |
|---|---|---|
| V1 | **Proactivity governor** (case fix #2) — one place that decides *whether ORBIT volunteers anything*: novelty + relevance + timing + budget (max one item). Merge the nudge system into it; Approach B dies. | M |
| V2 | **Repetition guard** (case fix #4) — structural near-duplicate detection against recent replies. | S |
| V3 | **Delta briefings**: "what's up today" answers with *what changed since last briefing*, not the full recital. First-ask-of-the-morning gets the full picture. | M |
| V4 | **Presence model**: "I'm going for a bath, back in 30" → warm one-line ack, an away-state that suppresses proactivity, and "welcome back" on return. This is the exact moment in the field test where the vision says a *person* would have said "sure, see you in a bit" — and it's cheap: a local state + timer. | S-M |
| V5 | **Greet once per session** (case fix #5). | S |
| V6 | **Instant local ack while the brain thinks** ("on it…") — latency shaping so tool turns feel alive. Needs care with E4 so the ack is interruptible. | M |
| V7 | **TTS upgrade path**: AVSpeechSynthesizer prosody is the last robotic layer standing once the words are right. Evaluate macOS 26 premium/personal voices; keep first-party (iOS portability rule). | M |
| V8 | Farewell/dismissal handling is now good (Phase 3.13) — protect it with the corpus whenever V1-V5 land. | — |

## 5 · MIND — understanding and routing

| # | Item | Size |
|---|---|---|
| R1 | **Orchestrator collapse stays paused** — Ayush's decision, resume on a real field misfire, corpus-first when it does. Nothing here changes that. | — |
| R2 | **Offline tool-calling decision** (awaiting Ayush): qwen2.5:7b already proved correct tool selection on indirect phrasing [verified earlier]. Would make offline ORBIT able to *act*, at ~4.4 GB resident while loaded. | M |
| R3 | **Foundation Models as the eventual local tier** — no daemon, on-device, exists on iOS 26; Ollama stays a dev convenience per the platform constraint. | L |
| R4 | Streaming + tools on `/chat/stream` — only matters if typed-path streaming ever carries tool intent; currently routed around by design. | M |
| R5 | `router.py` keyword lists are the last pre-brain phrase matching on the Python side; fold into the governor/brain decision when R1 resumes. | — |

## 6 · HANDS — acting, honestly

| # | Item | Size |
|---|---|---|
| H1 | **Per-capability gates for brain tools** — the privacy panel can't restrict what the brain may touch; a tool-permission matrix (already flagged in ORBIT.md) is the missing half of "guardrails & privacy". | M |
| H2 | **Capability registry**: one source of truth for what ORBIT can/can't do, driving both the brain's tool list and honest answers to "can you send email?". The ORBIT.md gap list is that registry, hand-maintained today. | M |
| H3 | **Action journal**: "what did you do today?" answered from the audit log — transparency as a feature. | S |
| H4 | Verification culture (read-back after write, same units) is the project's crown jewel — codify it as a written rule for every new tool. | S |
| H5 | Weather is hardcoded to Halifax [known]; use CoreLocation with a manual fallback. | S |

## 7 · NERVOUS SYSTEM — engineering health

| # | Item | Size |
|---|---|---|
| N1 | **Voice pipeline Phase 2**: the panel path still runs on booleans — 69 `transition()` calls in the backstage, **0** in `ContentView+Chat` [verified]. Two orchestrators for nine broker branches = permanent drift risk. | M |
| N2 | **Orbit Trace**: generalize the Reminder Trace pattern into one pipeline timeline (wake → partials → commit → route → prompt summary → reply → TTS → resume). Every field failure becomes data. This turn's diagnosis took an hour *because* the DB and audit log existed; make that coverage total. | M |
| N3 | **CI now exists for free**: GitHub Actions running pytest (96) + wake corpus (203) + reminder corpus on every push. The suites exist; wire them up. | S |
| N4 | Repo hygiene (section 1): gitignore hardening, purge junk, rotate key. | S |
| N5 | Split the giants gradually: `ContentView.swift` (109K) and `OrbitMacControlCenter.swift` (1862 lines) — opportunistically, never as a big-bang refactor. | ongoing |
| N6 | Python 3.9 floor: fine for now; note it blocks modern typing and some libs. Pin dependencies (`pyproject.toml` is loose). | S |
| N7 | Conversation regression suite: replay real (anonymized) transcripts through the full local pipeline as a fixture — the wake corpus idea, extended to whole conversations. | M |
| N8 | `.claude/agents/*` pin previous-generation models (`claude-opus-4-8`, `claude-sonnet-4-6`); refresh when convenient. | S |

---

## 8 · SEQUENCING (proposal)

**Now (this week):**
1. Rotate the OpenAI key + repo hygiene (N4) — *today*.
2. The case fix package (E1, V1, V2, V5, M4's intra-day part) — kills the entire "context-blind proactivity" class.
3. M1 pollution sweep + M2 temporal bug — small, and they feed directly into the fix package's quality.
4. N3 CI — one YAML file, permanent safety net.

**Next (the companion leap):**
5. M3 event lifecycle + M5 tool-op filter — unlocks *right-time* follow-ups.
6. V4 presence model — the "welcome back" moment.
7. V3 delta briefings, M6 duplicate-turn diagnosis (trace first), M7 consolidation v1 (dedupe only).

**Later (the intelligence leap):**
8. E3 semantic endpointing, E4 barge-in, M8 entity graph, M9 provenance, E5→E6 speaker awareness, H1-H2 capability layer, N1 pipeline completion.

**Someday / iOS-gated:** R3 Foundation Models tier, backend port strategy, V7 voice, E6 full voice ID.

**Standing rules that survive this document:** field failures pick the slice; corpus before refactor; verify effects in the environment that runs them; ask before architecture; paused code has reasons.

---

### Research notes (what the world knows, distilled)

- **Memory:** the 2025-26 frontier is graph-based, hierarchical memory with episodic buffers consolidated into semantic stores on "semantic shift" — the sleep-cycle model of M7/M8. See the [2026 memory literature scan](https://lin-guanguo.github.io/llm-memory-research/memory.literature-scan/), [MemGuard on contamination](https://arxiv.org/pdf/2605.28009), [typed provenance to prevent role collapse](https://arxiv.org/pdf/2605.25869), [MIRIX multi-store memory](https://arxiv.org/pdf/2507.07957), and [dual-process cognitive memory](https://arxiv.org/pdf/2606.09483). Zep-style temporal knowledge graphs are the reference design for M8.
- **Turn-taking:** production voice stacks in 2026 combine ~800-1200 ms silence with a *semantic completeness* score, and are moving to dedicated turn-taking models (backchannel vs barge-in vs continued-thought). See [semantic VAD overview](https://gradium.ai/content/semantic-vad-voice-agents-turn-detection-2026), [barge-in implementation guide](https://futureagi.com/blog/voice-ai-barge-in-turn-taking-2026/), [STEER (Apple, turn extension recognition)](https://arxiv.org/pdf/2310.16990), and [duration-aware endpoint detection](https://arxiv.org/pdf/2606.18094). ORBIT's E1-E3 are squarely on this path, implementable with the local tier it already runs.
