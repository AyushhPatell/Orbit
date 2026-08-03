# ORBIT Evolution Map

**Written:** 2026-08-03, after the "3 PM briefing" incident.
**What this is:** the complete list — every fix, improvement, and evolution across the whole system, small to large, ordered by what it does for the vision: a companion that says the right thing, at the right time, in the right words — and stays quiet the rest.

**Method honesty:** the core loops (prompt assembly, memory, nudging, voice commit, routing, brain protocol) were read line-by-line and the failing case was reproduced against real code and the real DB. The wider Swift surface (~23K lines) was mapped and spot-verified, not 100% read. Every claim below marked **[verified]** was proven by running code or querying data, not by reading. *(One claim was marked `[verified]` in error on 2026-08-03 and is corrected in §0 rather than deleted — a wrong diagnosis stays on the record.)*

### Status legend — nothing is marked done on assumption

- ✅ **DONE** — shipped **and** confirmed working by Ayush in real use.
- 🟡 **SHIPPED** — code in, tests + replay green, **not yet confirmed in daily use.** Not done.
- ⬜ **OPEN** — not started.
- ⛔ **WITHDRAWN** — proposed on a wrong diagnosis; kept visible with the reason.

Anything 🟡 stays 🟡 until Ayush says it behaves right. A passing test is evidence, not confirmation.

---

## 0 · THE CASE — the 3 PM briefing (root cause, fully verified)

Four independent layers failed. Each is its own fix; together they produced the exact behaviour Ayush saw.

**Layer 1 — the ears committed a thought-pause.** [verified — *corrected 2026-08-03, see below*]
There was **no filler guard anywhere**. "Um" waited out its silence window and was committed as a real message; the only downstream guard (`OrbitWakeVoiceBackstage.swift:122`) is `!trimmed.isEmpty`, which "Um" passes.

> **Correction — my original claim here was wrong.** I first wrote that the endpoint curve gave short transcripts the *shortest* pause, and marked it `[verified]` without running it. It isn't true. Compiling the pre-fix `endpointPauseSeconds` from git and running it:
>
> ```
> "Um"                  -> 1.70s      (words<=2 branch: base + 0.45)
> "turn off the wifi"   -> 1.25s      (base)
> "That's done."        -> 1.00s      (shortest — trailing punctuation)
> ```
>
> Short transcripts already got *more* time, not less. The real defect was simply that **1.7 s is not long enough for a person deciding what to say, and nothing checked whether the committed text was content at all.** The shipped fix (6 s window for filler + never send filler-only) is unaffected and works — but the stated cause was wrong, and roadmap item **E2 was built on that error and is withdrawn.** Recorded here rather than quietly edited, per the same rule that governs ORBIT.md.

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

### The fix package — ✅ **DONE** (shipped Phase 3.16, confirmed by Ayush 2026-08-03: *"it is fine now"*)

Field-confirmed by Ayush. Further real-use evidence from his own session on 2026-08-03,
while this work was in progress — indirect phrasing acted on, contextual follow-up
understood, a greeting answered warmly with **no memory recital**:

```
"I think the volume is too high"  → "Turned the volume down to 78%. Let me know if it's better now."
"Increase a bit."                 → "Bumped the volume up to 85%. How's that?"
"Good morning"                    → "Good morning! Hope you're feeling ready for the day…"
"Nothing, I'm just being lazy"    → "Sometimes lazy mornings are the best kind. Chill for a bit—you've earned it."
```

1. **Filler-only commits never leave the Mac.** After `stripDisfluencies`, if nothing but filler remains and no question is pending: don't send — keep listening with an *extended* window. Silence is the human response to someone thinking.
2. **Kill Approach B; replace with a proactivity governor.** Life events return to the system prompt only (with ages, layer 3 below). A reply may volunteer at most **one** unprompted item, and only when: (a) the user's message is a greeting/opener or an explicit "what's up today", (b) the item is *novel* (never spoken before — tracked persistently, the way nudges already are), and (c) it's *timely* (due-soon beats historical). A substantive user message means: answer what he said, volunteer nothing.
3. **Ages, not labels.** Every injected memory carries "shared 5h ago"; routine items older than ~3h flip to "earlier today — likely already done; do not mention as current."
4. **Structural repetition guard.** Before returning, compare the candidate reply against the last assistant replies for the session; near-identical → strip the repeated content or regenerate once with "respond only to what he actually said." Prompting is not honesty, and prompting is not variety — this must be structural.
5. **Greet once.** "Afternoon, Ayush" at most once per conversational session, not per turn.

---

## 1 · ✅ DONE — the GitHub push leaked a live key [verified, resolved 2026-08-03]

Key rotated by Ayush the same day (GitHub's scanner flagged it on push). Repo cleaned:
`.env.backup` untracked, `.gitignore` hardened against every `.env` variant plus build/runtime
junk, **3,247 → 136 tracked files**. `data/` never leaked — verified. Original record below.



- `.gitignore` covers `.env` — but **`orbit-core/.env.backup-2026-08-01` is tracked and pushed**, and it contains the OpenAI `CLOUD_API_KEY`. **Rotate that key today** (platform.openai.com → API keys → revoke + recreate), then `git rm` the backup. Rotation is the real fix — history scrubbing is optional after the key is dead.
- Also pushed, harmless but junk: the entire `.derivedData/` build tree (thousands of files), `.run/logs/*`, `orbit_core.egg-info`. Add to `.gitignore`: `.env*`, `!.env.example`, `.run/`, `.derivedData/`, `*.log`.
- **What did NOT leak:** `data/` is ignored — `orbit.db` (your personal memory) and `chat_audit.jsonl` stayed local. Verified.

---

## 2 · EARS — hearing like a person listens

| # | Item | Size |
|---|---|---|
| E1 | ✅ **DONE** — filler-only commit guard. `isFillerOnly` + 6 s thinking window; filler never leaves the Mac. Confirmed by Ayush. | S |
| ~~E2~~ | ~~Invert the endpoint curve's bottom end~~ — **WITHDRAWN 2026-08-03.** Based on a wrong reading of `endpointPauseSeconds` (see the correction in §0): short transcripts already get *more* time. Nothing to invert. | — |
| E3 | 🟡 **SHIPPED 2026-08-03 (Phase 3.21), awaiting field confirmation** — commit now reads what was SAID, not silence alone. `OrbitUtteranceCompleteness.swift` holds the whole endpoint decision as a pure function; four signals mark an unfinished thought (dangling function word, all-function-word frame, ending on the subject, transitive verb with no object). Linguistic not model-based on purpose: it runs on every partial, so it must be instant, offline, and portable to iOS. A new 69-check corpus caught **7 real failures on its first run** — "cancel that" was being made to wait, and "how are you" vs "can you" share a final word and needed the wh-opening to separate them. Wired into CI. **Honest limit:** a pause after a grammatically complete clause is invisible to text alone. Original note: **Semantic endpointing**: commit on *meaning-complete*, not silence alone. Industry standard is now silence (~800-1200 ms) + a completeness score over the partial transcript; the local Ollama/Foundation-Models tier can score "does this read finished?" — "remind me to…" hangs open, "remind me to call mom" commits. Kills both early-commit and long-sentence-cutoff classes at the source. | M |
| E4 | ⛔ **HARDWARE AEC RULED OUT (Phase 3.29).** The 3.27 attempt enabled macOS voice processing on the capture engine and **broke audio input entirely** — mic light on, nothing heard, `Voice_Processor … downlink DSP (I/O fault)` repeating. VPIO is a **duplex** unit that cancels against audio the *same engine plays*; ORBIT's engine only captures, and TTS goes out via AVSpeechSynthesizer separately — so there was never a reference signal. Input-only engines cannot use VPIO. A second bug compounded it: the barge-in listener held the mic and discarded everything, blocking the real session. Both fixed. Barge-in survives with **content-based rejection only**, default off — the honest ceiling of this approach. **Lesson: "behind a toggle" did not contain it**, because the flag persisted on the node beyond the toggle's scope; anything touching capture must be verified with the mic actually running. Original note: **SHIPPED BUT NOT WORKING (Phase 3.27) — first field test failed.** Ayush said "stop" repeatedly with the toggle on and nothing happened. One definite bug found and fixed: the SpeechAnalyzer path (default ON) returns before echo cancellation is applied, so AEC was never active. That does not explain a total failure, and code reading cannot separate "mic never opened" from "mic heard only ORBIT" — a trace was added instead of a guess (say "barge-in diagnostics"). Key finding: the wake word owns a **separate** `AVAudioEngine`, so echo cancellation touches only the voice-session path — the original risk to the tuned wake word did not apply. AEC first line, **content matching second** (mic output compared against what ORBIT is currently saying), because hardware cancellation can fail quietly and content matching cannot. "Stop" always wins, before any echo test. Conservative: filler and single stray words never interrupt. Corpus in CI. Original note: **Barge-in**: speaking while ORBIT talks should interrupt him (echo-cancelled listening during TTS, "stop/wait" without wake word). A companion is interruptible. | M |
| E5 | 🟡 **SHIPPED 2026-08-03 (Phase 3.23), awaiting field confirmation** — ORBIT reads "my friend Shruti is here" as a *situation*, not a fact about Ayush. Greets the guest once; **volunteering stops entirely** while someone else can hear (reminders, calendar, mood, health); a direct question is still answered — discretion, not lockdown. Names confirmed against the people table so a stray word can't invent a guest. Expires after 45 min or on "she left". Verified live end to end. **Still open:** knowing WHO is speaking (E6). Original note: **Guest awareness**: "my friend Shruti is here, say hi" stored *Shruti's presence as an Ayush relationship fact* [verified in DB]. Detect the introduce-a-guest pattern → greet the guest, don't file their speech as Ayush's life. | S-M |
| E6 | **Speaker identity (long-term)**: on-device voice ID so ORBIT knows *who* is talking — respond to Ayush, politely handle others, never store guest speech as Ayush facts. Big companion payoff, heavy lift. | L |
| E7 | Wake-word false-positive hardening vs TV/ambient audio (energy + voice-match gate). The replay harness (`say -v Rishi/Aman/Tara`) is the right measurement tool and should become a fixture for every ears change. | M |

## 3 · MEMORY — the heart of the vision

| # | Item | Size |
|---|---|---|
| M13 | 🟡 **SHIPPED 2026-08-03 (Phase 3.28)** — **cross-day bleed.** ORBIT reported yesterday's breakfast as "this morning" and a month-old ROUTINE as "you worked today". Reproduced against the live DB: `_temporal_label` had already returned `PAST (yesterday)` and the model ignored it — **labelling is not enforcement** (third time this lesson landed today). A previous day's event now never reaches the prompt; the day boundary is the filter, the phase is only a label. Today's finished events stay, so no context is lost. | M |
| M14 | 🟡 **SHIPPED 2026-08-03 (Phase 3.28)** — **routines are patterns, not records.** A routine fact is no evidence the thing happened today, and ORBIT cannot know whether it did. Now answers "I don't have today's attendance info, but your usual shift is… did you work today?" instead of asserting. | S |
| M15 | 🟡 **SHIPPED 2026-08-03 (Phase 3.28)** — consolidation only expired events that carried a clock time, so a dated-but-timeless event never aged out. Expires by day now. This is what left a day-old breakfast in the live window. | S |
| M11 | ✅ **DONE 2026-08-03 (Phase 3.19)** — **`cosine_similarity` was a bare dot product.** Only correct for unit-length vectors; `nomic-embed-text` has magnitude ~20, so scores were 150-350 instead of 0-1 — **every** stored memory cleared the 0.6 relevance gate in `semantic_search`, and ranking was skewed by vector magnitude rather than meaning. Silent since real embeddings were enabled (Phase 3.5). Normalising at comparison time fixed existing rows with no re-embedding. Measured after: the right memory ranks first for every probe. | S |
| M12 | ✅ **DONE 2026-08-03 (Phase 3.19)** — the **third** regex writer (semantic candidates) gated like the other two, after measuring that all 19 stored vectors were conversational debris ("I am doing good, thank for asking!"). Purged, and semantic memory seeded from the 7 curated facts so recall works immediately rather than waiting for extraction. | S |
| M1 | ✅ **DONE 2026-08-03** — confirmed by Ayush. — pollution sweep. Root cause [verified]: Phase 3.6 added the LLM extractor but **never stopped the regex writers**, so both ran on every turn; all 16 `personal_knowledge` rows were regex-written, **zero** from the LLM — and that junk was fed back as "already known, do not repeat", suppressing the clean version of the same fact. Executed: 16 rows → **7 curated facts**; 24 life events → **6** (removed ORBIT's command log + legacy verbatim-speech fragments); 5 mirroring semantic vectors dropped. DB backed up, every removed row archived to JSON. | S |
| M2 | ✅ **DONE (Phase 3.16)** — confirmed by Ayush. — temporal label bug (work-list #3). `_temporal_label` rewritten: date words resolve against the day they were said, so `weekend`/`next-week` no longer flip to PAST after one day. Also fixed a silent 3-hour age skew (DB stores UTC, code compared local). 10 regression tests. Needs multi-day real use to confirm. | S |
| M3 | ✅ **DONE (Phase 3.18)** — confirmed by Ayush. — event lifecycle. A named clock time is resolved to an instant (`occurs_at` + `duration_minutes`) and phased: STARTING SOON → HAPPENING RIGHT NOW → JUST FINISHED → FINISHED EARLIER TODAY → PAST. Follow-ups fire only in the finished window, so "how was the movie?" can only arrive **after** the movie. `is_resolved` is now written, closing loops permanently instead of deferring 48h. No clock time = no instant; never invent an hour. 12 tests. | M |
| M4 | ✅ **DONE (Phase 3.16)** — memories now enter the prompt with human ages ("shared 5 hours ago"). Part of the confirmed package, but the ages themselves haven't been spot-checked in use. | S |
| M5 | ✅ **DONE 2026-08-03** — confirmed by Ayush. — tool operations no longer recorded as life events. Two parts: regex writers now run **only** when no brain key exists (they were never meant to run alongside the LLM pass), and `is_tool_operation()` structurally drops ORBIT's command log at extraction — prompting alone had failed. Calendar *plans* deliberately survive; only ORBIT's own artefacts (reminders/alarms/notes) and device actions are dropped. 20/20 on real DB entries, 6 new tests. | S |
| M6 | ✅ **SOLVED 2026-08-03 — and it was not a retry bug at all.** The **test suite was writing to the production database.** `app.main` binds its `MemoryStore` at import to the live `data/orbit.db`, and several tests call endpoint functions directly, so **every `pytest` run inserted 12 turns into Ayush's personal memory** — proven by counting (1402 → 1414), not inferred. **228 rows** had accumulated under `test-offline`. My earlier guess ("likely the offline/retry path") was wrong; the identical reply sequence repeating at four timestamps was the tell — those were *my own test runs*. Fixed with an autouse session fixture (`tests/conftest.py`) repointing the store at a temp DB; verified delta 0. Rows purged. | M |
| M6b | ✅ **DONE 2026-08-03** — isolating M6 exposed that **five tests passed only because Ayush's `.env` existed.** `get_settings()` re-reads that file every call and file values beat the environment, so on a clean checkout `brain_api_key` was empty, `chat_tool_result` raised 503, and the offline-resilience tests never reached the code they claim to cover. The suite now pins its own settings and passes with no secrets. Found by running the suite in a fresh clone — which is exactly what CI does. | S |
| M7 | 🟡 **SHIPPED 2026-08-03 (Phase 3.19), v1** — deterministic daily pass: retires near-duplicate life events and events whose moment has passed; merges facts filed under different categories (write-time dedupe only looks within one). Nothing deleted — marked `is_resolved`. Paraphrase detection uses the embedder when live, lexical distance when not. **Not yet done:** LLM-driven contradiction merging. Original note: **Nightly consolidation ("sleep cycle")**: dedupe (three Spider-Man entries, three Kan/Kawan entries [verified]), merge contradictions, promote stable episodic facts to semantic knowledge, decay importance, expire dated items. Current research separates an episodic buffer from event-driven semantic consolidation exactly this way. Runs on the brain overnight; ports to iOS unchanged. | M-L |
| M8 | 🟡 **SHIPPED 2026-08-03 (Phase 3.20), v1 — people**, awaiting field confirmation. New `people` table with each person's known heard-variants; his six close friends seeded from ground truth he gave. Kavan/Kawan/Kan is now one person. **Prompt guidance alone was measured and failed** (the brain still said "Kawan is just a close friend"), so resolution is structural — exact whole-word match against a curated variant list only, never fuzzy, so it cannot merge two real people. Applied once at the door, so brain + tools + recall + stored history all get the real name. **Still open:** places/projects as entities, relationships between them, and the Swift-side name paths. Original note: **Entity resolution / personal knowledge graph**: "Kan" and "Kawan" are one person split by an STT mishear [verified — the calendar rename proves it]. Entities (people, places, projects) with relationships and event links, grounded against Contacts. Temporal knowledge graphs (Zep/Graphiti-style) are the state of the art for exactly this. The Kachuful entry shows the payoff: ORBIT knowing *what things are*, not just what was said. | L |
| M9 | **Provenance typing**: every memory records *who said it, when, in what context* — guards against role-collapse (Shruti's words becoming Ayush's facts) and contamination, both active research problems with known designs. | M |
| M10 | Session-scoped `session_id` review: everything is one eternal session today; real session boundaries (wake→farewell) would give "recent turns" honest meaning. | M |

## 4 · VOICE — when to speak, what to say

| # | Item | Size |
|---|---|---|
| V1 | ✅ **DONE (Phase 3.16)** — proactivity governor. Approach B deleted; volunteering gated structurally on `_is_conversational_opener`, so a substantive message can't trigger a briefing. Confirmed by Ayush. | M |
| V2 | ✅ **DONE (Phase 3.16)** — structural near-duplicate guard (difflib ≥ 0.85 vs last 3 assistant turns, short replies exempt, one regeneration). Tested, but no real repeat has occurred in use yet. | S |
| V3 | 🟡 **SHIPPED 2026-08-03 (Phase 3.19)** — an explicit rundown request within ~6h names what he already heard so the brain leads with what changed, or says "nothing new" in one line. Original note: **Delta briefings**: "what's up today" answers with *what changed since last briefing*, not the full recital. First-ask-of-the-morning gets the full picture. | M |
| V4 | ✅ **DONE (Phase 3.18)** — confirmed by Ayush. — presence model. Departure detected ("back in 30 minutes", "brb", "going for a shower"), away-state recorded, and the next message after a real gap is understood as a return. Wording comes from the brain with a context note, never a canned string; it is told explicitly not to turn the welcome into a briefing. Guarded against plans-for-later ("going to the gym after my shift"). Verified live end-to-end, 11 tests. **Not yet done:** suppressing Swift-side proactive notifications while away. | S-M |
| V9 | 🟡 **SHIPPED 2026-08-03 (Phase 3.22)** — **card policy.** Phase 3.15 carded every reply ending in "?"; most of ORBIT's questions are conversation, so it became noise. The card now appears only when content is worth reading or getting exactly right: pending choice, consequential confirmation, verifying a misheard name, a missing detail for a record, or real multi-fact data. TTL follows the reason. 55-check corpus in CI. | M |
| V10 | 🟡 **SHIPPED 2026-08-03 (Phase 3.26)** — **deferred curiosity.** A private question held back because someone was listening is now parked rather than deleted, and surfaces when the room is clear. ORBIT may ask "are you on your own?" first; Ayush can also invite it ("what did you want to ask?"). Asked once, expires after 3 days, and explicitly not softened into a safer question. | M |
| V5 | ✅ **DONE (Phase 3.16)** — a repeated time-of-day greeting is stripped when the previous reply already opened with one. Tested; not yet seen in use. | S |
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
| N3 | ✅ **DONE 2026-08-03** — `.github/workflows/ci.yml`: pytest (121) + wake corpus (203) + reminder corpus + an unsigned ORBITMac build, on every push. Validated by running the suite in a fresh clone with no `.env` — which is how M6b's five hidden failures surfaced. | S |
| N4 | ✅ **DONE 2026-08-03** — see §1. Key rotated, repo cleaned, 3,247 → 136 tracked files. | S |
| N5 | Split the giants gradually: `ContentView.swift` (109K) and `OrbitMacControlCenter.swift` (1862 lines) — opportunistically, never as a big-bang refactor. | ongoing |
| N6 | Python 3.9 floor: fine for now; note it blocks modern typing and some libs. Pin dependencies (`pyproject.toml` is loose). | S |
| N7 | Conversation regression suite: replay real (anonymized) transcripts through the full local pipeline as a fixture — the wake corpus idea, extended to whole conversations. | M |
| N8 | `.claude/agents/*` pin previous-generation models (`claude-opus-4-8`, `claude-sonnet-4-6`); refresh when convenient. | S |

---

## 8 · SEQUENCING (proposal)

**Now (this week):**
1. ~~Rotate the OpenAI key + repo hygiene (N4)~~ — ✅ **DONE 2026-08-03.**
2. ~~The case fix package (E1, V1, V2, V5, M4)~~ — ✅ **DONE, Phase 3.16**, confirmed by Ayush.
3. ~~M2 temporal bug~~ — 🟡 shipped. **M1 pollution sweep** — prevention shipped (M5); the destructive cleanup awaits Ayush's decision.
4. **N3 CI** — one YAML file, permanent safety net. ⬅ *next up*

**Next (the companion leap):** ⬅ *we are here*
5. ~~M5 tool-op filter~~ 🟡 done. **M3 event lifecycle** — planned → due → likely-done → confirmed. Unlocks *right-time* follow-ups ("how was the movie?" **after** 5 PM, never before). The `is_resolved` column already exists and has never been written.
6. **V4 presence model** — "back in 30 minutes" → away-state → *"welcome back"*. The exact moment from the field test.
7. V3 delta briefings; ~~M6~~ ✅ solved; M7 consolidation v1 (dedupe only).

**Later (the intelligence leap):**
8. E3 semantic endpointing, E4 barge-in, M8 entity graph, M9 provenance, E5→E6 speaker awareness, H1-H2 capability layer, N1 pipeline completion.

**Someday / iOS-gated:** R3 Foundation Models tier, backend port strategy, V7 voice, E6 full voice ID.

**Standing rules that survive this document:** field failures pick the slice; corpus before refactor; verify effects in the environment that runs them; ask before architecture; paused code has reasons.

---

### Research notes (what the world knows, distilled)

- **Memory:** the 2025-26 frontier is graph-based, hierarchical memory with episodic buffers consolidated into semantic stores on "semantic shift" — the sleep-cycle model of M7/M8. See the [2026 memory literature scan](https://lin-guanguo.github.io/llm-memory-research/memory.literature-scan/), [MemGuard on contamination](https://arxiv.org/pdf/2605.28009), [typed provenance to prevent role collapse](https://arxiv.org/pdf/2605.25869), [MIRIX multi-store memory](https://arxiv.org/pdf/2507.07957), and [dual-process cognitive memory](https://arxiv.org/pdf/2606.09483). Zep-style temporal knowledge graphs are the reference design for M8.
- **Turn-taking:** production voice stacks in 2026 combine ~800-1200 ms silence with a *semantic completeness* score, and are moving to dedicated turn-taking models (backchannel vs barge-in vs continued-thought). See [semantic VAD overview](https://gradium.ai/content/semantic-vad-voice-agents-turn-detection-2026), [barge-in implementation guide](https://futureagi.com/blog/voice-ai-barge-in-turn-taking-2026/), [STEER (Apple, turn extension recognition)](https://arxiv.org/pdf/2310.16990), and [duration-aware endpoint detection](https://arxiv.org/pdf/2606.18094). ORBIT's E1-E3 are squarely on this path, implementable with the local tier it already runs.
