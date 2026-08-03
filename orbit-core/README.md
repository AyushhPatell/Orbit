# ORBIT Core

Local backend service for Project ORBIT.

## Features in this scaffold

- `POST /chat` endpoint
- Local-first routing (`local`, `cloud`, `tooling`); **cloud** calls an OpenAI-compatible `POST /v1/chat/completions` with `CLOUD_API_KEY` (OpenAI, Gemini compat URL, or a LiteLLM proxy)
- **Local LLM via OpenAI-compatible** `POST /v1/chat/completions` (Ollama, **MLX-LM**, LM Studio, etc.)
- SQLite persistence for conversation turns
- Profile-based system prompt from `user_profile.md`

## Prerequisites

- Python 3.9+ (3.12+ recommended on Mac when you can)
- A local LLM server — **either**:
  - **Ollama** at `http://127.0.0.1:11434`, or
  - **MLX-LM** (Apple Silicon) at `http://127.0.0.1:8080` if Ollama’s runner fails on your Mac (common on some **M5** machines until Ollama/macOS catch up)

## Setup

```bash
cd orbit-core
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -e .
cp .env.example .env
```

**Using MLX on Apple Silicon** (your `.env` points at port 8080): install the extra once in this same venv:

```bash
pip install -e ".[mlx]"
# or: pip install "mlx-lm>=0.20.0"
```

Without this, `python -m mlx_lm.server` fails with `No module named 'mlx_lm'`.

If `pip` or `python -m pip` errors with **`No module named 'pip._vendor.packaging'`** or **`No module named 'pip._internal.utils'`**, your venv’s pip install is broken. **Recreate the venv** (simplest), or reinstall pip only:

```bash
cd orbit-core
rm -rf .venv/lib/python*/site-packages/pip .venv/lib/python*/site-packages/pip-*.dist-info
curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
.venv/bin/python /tmp/get-pip.py
.venv/bin/python -m pip install -U pip setuptools wheel
```

Or recreate the whole venv:

```bash
deactivate 2>/dev/null || true
cd orbit-core
rm -rf .venv
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
pip install -e .
pip install -e ".[dev]"
```

Edit `.env`: use **Option A (Ollama)** or **Option B (MLX)** as documented in the file.

Optional **`CHAT_MAX_TOKENS_LOCAL`** (default `768`) and **`CHAT_MAX_TOKENS_CLOUD`** (default `1024`) cap completion length on the OpenAI-compatible API—shorter answers and often lower latency on local MLX. Legacy alias: `LOCAL_LLM_MAX_TOKENS` for local.

ORBIT re-reads `.env` on **every** `/ready` and `/chat` request (so you are not stuck on old values when `uvicorn --reload` does not restart after editing `.env` only). Changing `ORBIT_DB_PATH` still needs a restart so the SQLite file path updates.

## Run ORBIT Core

```bash
uvicorn app.main:app --reload --port 8787
```

## Start both services with one command

Use the helper script to run ORBIT core + MLX together from one terminal:

```bash
cd orbit-core
chmod +x scripts/orbit-services.sh
scripts/orbit-services.sh start
```

Useful commands:

```bash
scripts/orbit-services.sh status
scripts/orbit-services.sh stop
scripts/orbit-services.sh restart
```

Battery note:

- Default mode is battery-friendlier (no `uvicorn --reload`).
- For active backend coding with auto-reload, use:

```bash
scripts/orbit-services.sh --dev start
```

### Terminal shortcuts (zsh)

One-time: append this line to `~/.zshrc`, then open a new terminal tab (or `source ~/.zshrc`):

```bash
source "/Users/ayush/Documents/PJ/ORBIT/orbit-core/scripts/orbit-services-aliases.zsh"
```

Adjust the path if your clone lives elsewhere. Then use:

- `orbit-up` — start ORBIT core + MLX (battery mode, no `--reload`)
- `orbit-up-dev` — start with `uvicorn --reload`
- `orbit-down` — stop both
- `orbit-status` — show PIDs / ports
- `orbit-restart` — stop then start

**Xcode:** keep your Run **Pre-action** calling `orbit-services.sh start`. When you stop the app in Xcode, background services usually keep running by design; run `orbit-down` when you are done coding for a while (saves battery). **Later (scaling):** we can add macOS `launchd` or another lifecycle manager so stop/teardown is automatic and reliable—Xcode Run **Post-actions** are not dependable when you hit Stop.

## Run local LLM: MLX (Apple Silicon — use when Ollama crashes)

Use a **second** terminal (keep ORBIT’s `uvicorn` running in the first).

```bash
cd orbit-core
source .venv/bin/activate
pip install "mlx-lm>=0.20.0"
mlx_lm.server --model mlx-community/Llama-3.2-3B-Instruct-4bit --port 8080
```

First run downloads the model from Hugging Face (can take a while).

Your `.env` should include:

```env
LOCAL_LLM_BACKEND=openai
LOCAL_LLM_URL=http://127.0.0.1:8080
LOCAL_LLM_MODEL=mlx-community/Llama-3.2-3B-Instruct-4bit
```

Then:

```bash
curl -s http://127.0.0.1:8787/ready
curl -s -X POST http://127.0.0.1:8787/chat \
  -H "Content-Type: application/json" \
  -d '{"session_id":"dev","message":"Say hello in one sentence."}'
```

## Tests (optional)

```bash
pip install -e ".[dev]"
pytest -q
```

## Quick manual checks

```bash
curl -s http://127.0.0.1:8787/health
curl -s http://127.0.0.1:8787/ready
curl -s -X POST http://127.0.0.1:8787/chat \
  -H "Content-Type: application/json" \
  -d '{"session_id":"dev","message":"Plan my evening study session"}'
```

Optional **`route_hint`** from the Mac Tier-1 router (`local` | `cloud` | `tooling`). For **`tooling`**, send **`tooling_context`** (e.g. today’s calendar text from the Mac app) so the model sees real schedule data, not only your question:

```bash
curl -s -X POST http://127.0.0.1:8787/chat \
  -H "Content-Type: application/json" \
  -d '{"session_id":"dev","message":"What is on my calendar?","route_hint":"tooling","tooling_context":"Today: 10:00 Standup, 15:00 Lab"}'
```

The Mac app also sends **`client_local_iso`** and **`client_tz`** (device wall clock) on every chat so greetings match real local time; `curl` can omit them.

**Curated facts** (injected into every `/chat` system prompt; each row has a stable **`id`** for deletion):

```bash
curl -s http://127.0.0.1:8787/facts
curl -s -X POST http://127.0.0.1:8787/facts \
  -H "Content-Type: application/json" \
  -d '{"fact":"Ayush is building Project ORBIT as a long-term companion."}'
curl -s -X DELETE http://127.0.0.1:8787/facts/1
```

## Cloud tier (optional)

When the router picks **`cloud`** (long prompt past **`CLOUD_FALLBACK_MIN_CHARS`** default 1200, cloud keywords, or Mac `route_hint`), ORBIT calls **`CLOUD_BASE_URL`** with **`Authorization: Bearer <CLOUD_API_KEY>`** — same wire format as the local MLX path. By default **`CLOUD_REDACT_PII=true`** strips common email / US-phone / SSN-shaped runs from every message block **sent to the cloud** only; SQLite history stays unchanged.

Optional **`CHAT_AUDIT_LOG_PATH`** (for example `./data/chat_audit.jsonl`) appends one JSON line per `/chat` with route/model/timing/length/error metadata for debugging. Raw user/reply text is intentionally excluded. Rotation controls:

- **`CHAT_AUDIT_MAX_BYTES`** (default `2000000`)
- **`CHAT_AUDIT_BACKUP_COUNT`** (default `4`)

Optional **`SEMANTIC_MEMORY_ENABLED=true`** enables a minimal local semantic-memory scaffold:

- auto-extracts likely durable user context statements from user turns (preference/profile-like snippets),
- stores hashed-vector memory rows in SQLite (`semantic_vectors` table),
- recalls top relevant items into the system prompt each turn.

This is a lightweight mem0-style bootstrap (no external embedding service; all local).
Tune it with:

- **`SEMANTIC_MEMORY_MIN_SCORE`** (default `0.56`) — higher = fewer, stronger memories.
- **`SEMANTIC_MEMORY_RETENTION_DAYS`** (default `90`) — auto-prune old semantic rows.
- **`SEMANTIC_MEMORY_MAX_ITEMS`** (default `500`) — cap total semantic rows.

Optional **`REDACT_LOCAL_STORAGE=false`** controls privacy-at-rest:

- `false` (default): store raw turns/facts locally for best recall quality.
- `true`: run PII redaction before writing turns/facts/auto semantic memories to SQLite.

You can inspect auto semantic memories with:

```bash
curl -s http://127.0.0.1:8787/semantic-memory
curl -s -X POST http://127.0.0.1:8787/semantic-memory \
  -H "Content-Type: application/json" \
  -d '{"text":"Ayush prefers concise bullet summaries.","source":"manual"}'
curl -s -X PATCH http://127.0.0.1:8787/semantic-memory/3 \
  -H "Content-Type: application/json" \
  -d '{"importance":0.95}'
curl -s -X DELETE http://127.0.0.1:8787/semantic-memory
curl -s -X DELETE http://127.0.0.1:8787/semantic-memory/3
curl -s http://127.0.0.1:8787/memory/stats
```

Defaults (OpenAI):

```env
CLOUD_API_KEY=sk-...
# CLOUD_BASE_URL=https://api.openai.com
# CLOUD_MODEL=gpt-4o-mini
```

**Gemini (Google AI Studio key)** — use Google’s OpenAI-compatible base (see [Gemini OpenAI API](https://ai.google.dev/gemini-api/docs/openai)):

```env
CLOUD_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
CLOUD_MODEL=gemini-2.0-flash
CLOUD_API_KEY=<your Google AI Studio API key>
```

**LiteLLM proxy:** run LiteLLM locally and set `CLOUD_BASE_URL` to that proxy’s origin (still `/v1/chat/completions`).

If `route` is `cloud` but **`CLOUD_API_KEY` is empty**, `/chat` returns **503** with a short hint (local-only until you add a key).

## ORBITMac — Phase 1 actions (milestone)

The menu-bar app includes an **Actions** section (expand the disclosure):

1. **Run Shortcut** — After **Prepare shortcut run…**, confirm in an **inline** card (not a system sheet—those can dismiss the menu-bar window on macOS). Then the Shortcuts app opens for a name that **matches exactly**.
2. **New calendar event** — **Review before adding…** shows an inline summary; **Add to Calendar** saves via **EventKit** and shows a **success or error banner** (dismissible; successes auto-clear). On failure, the review card stays open so you can fix and retry.
3. **Browser/Web Action Agent (semi-automated)** — Open a site, run a web search, summarize a webpage, or draft a response from webpage content. Each action is **Prepare …** then **Confirm** before execution so user stays in control. Wake/hands-free can trigger the same flow by voice (e.g. `search web for ...`, `summarize this page <url>`) and then confirm with **`yes run web action`** / **`cancel`**.
4. **Communication Drafting (draft-only)** — Draft email/Slack/Teams replies, meeting follow-ups, and status updates from your prompt (+ optional context). It never sends messages automatically. Wake/hands-free can trigger this too (e.g. `draft an email reply ...`) and then confirm with **`yes draft it`** / **`cancel`**.

**Speech (Day 7)** — In the **Conversation** header, use **Speak** / **Stop** to read the current reply with the system voice, or enable **Auto-speak** (also under the **⋯** menu) to read each new reply when it arrives.

**Voice input (push-to-talk)** — Use the mic button beside **Send** to dictate into the composer; text and voice can be mixed freely. For sandboxed macOS builds, keep `com.apple.security.device.audio-input=true` and add these usage descriptions in your app target (Info):

- `NSSpeechRecognitionUsageDescription`
- `NSMicrophoneUsageDescription`

**Memory debug (hidden, opt-in)** — Toggle **Show memory debug** from the **⋯** menu only when you want to inspect memory internals; it adds a small panel inside the **Memory** disclosure with recent-turn count and semantic hits from the latest `/chat`.

**Clipboard helpers** — Copy plain text (**⌘C**), then ask (typed or wake), for example: `summarize my clipboard`, `rewrite clipboard`, `bullet points from clipboard`, `action items from clipboard`, `draft reply to clipboard`. ORBIT reads `NSPasteboard`, builds one expanded user message for `/chat`, and forces **`route_hint: local`** so the clipboard body is handled by your **local MLX** tier (see `docs/ORBIT_CAPABILITIES.md`).

**System deep links, App Store, Chrome, typing** — Typed or wake: e.g. `open system settings`, `open wifi settings`, `open battery settings`, `search app store for …`, `search google for …` (opens **Google Chrome** with a Google results URL). To **type into whatever field already has keyboard focus**, enable ORBITMac under **Privacy & Security → Accessibility**, then say e.g. `type in focused field your text` or `ui type your text`.

**Microsoft 365 (optional)** — Under **Tools → Microsoft 365**: create a **public client** app in [Azure Portal](https://portal.azure.com) (**Authentication** → enable **Allow public client flows**), add delegated permissions **Mail.Read**, **Chat.Read**, **User.Read**, and **offline_access** (grant admin consent if your tenant requires it), paste the **Application (client) ID**, tap **Sign in…**, complete the **device code** flow in the browser, then use **Recent mail** / **Recent chats** for read-only previews (nothing is sent).

**Finder/file helpers (safe v1)** — Uses your **real** home paths (`~/Downloads`, `~/Documents`, `~/Desktop`), not the sandbox container. Commands: `open downloads`, `open documents`, `open desktop`, `open finder`; `open trash` / `show trash`; `empty trash` (asks **yes empty trash** / **cancel** first); `find file resume` or `find patel promissory`; `create project folder …` / `create a folder named …` (under `~/Documents/ORBIT Projects/…` by default, or **`on my desktop`** / **`on my desktop please`** for Desktop). After entitlement changes, **clean rebuild** ORBITMac. If macOS still blocks access, enable ORBITMac under **System Settings → Privacy & Security → Files and Folders** (Downloads/Documents/Desktop).

**Bluetooth (`blueutil`)** — On each **build**, the ORBITMac target runs **Copy blueutil into bundle**: if `brew install blueutil` is present, it copies `/opt/homebrew/bin/blueutil` (or `/usr/local/bin/blueutil`) into **`ORBITMac.app/Contents/MacOS/blueutil`** and ad-hoc **codesign**s it so the sandbox can execute it. At runtime ORBIT prefers that **sibling-of-main-binary** copy, then Homebrew paths (without resolving symlinks). The target sets **`ENABLE_USER_SCRIPT_SANDBOXING = NO`** so the copy script can read Homebrew’s binary during the build. If the script logs that `blueutil` was not found, install Homebrew’s package and rebuild.

**Wake vs typed menu bar** — Local commands (Wi‑Fi, Bluetooth, Trash, find, delete confirm, etc.) use the same parser for both; wake transcripts are normalized (e.g. **wi-fi** / **wi fi** → **wifi**, **blue tooth** → **bluetooth**) so phrasing matches typed commands. After a completed local action from wake, ORBIT may add a short follow-up prompt; it is **omitted** while waiting for **delete**, **empty trash**, or **open N** file-pick confirmation.

**Privacy prompts repeating after every Xcode Run** — macOS ties Calendar, Microphone, Files & Folders, etc. to your app’s **code identity** (signing team + bundle ID + **executable**). Debug runs from **DerivedData** are still the same bundle ID, so toggles should **stick** across ordinary Stop/Run. If the system treats each run as “new,” typical causes are: **bundle identifier** or **team** changed in the target, **Provisional** / ad-hoc signing differences, or you opened a **different** `.app` (e.g. an archive vs the Debug build). Keep **one** stable `PRODUCT_BUNDLE_IDENTIFIER` and team, avoid renaming the target’s bundle ID while testing, and install a **Release** build to `/Applications` when you want long-lived TCC behavior identical to shipped apps. ORBIT also **coalesces** concurrent calendar access requests so two features don’t each trigger a separate “Full Access” sheet at once. Wake word and push-to-talk **check Speech / Mic authorization** before calling `request…` again so already-granted access should not re-prompt every launch.

Requires the same **Calendars** permission you already granted for reading events.

## Notes

- Keep this service bound to `127.0.0.1` for privacy; only you choose when cloud keys are set.

## Troubleshooting

### Cannot reach local LLM / `/ready` is not ok

- **Ollama:** `curl -s http://127.0.0.1:11434/api/tags` and set `LOCAL_LLM_BACKEND=ollama`.
- **MLX:** ensure `mlx_lm.server` is running and `LOCAL_LLM_BACKEND=openai`, `LOCAL_LLM_URL=http://127.0.0.1:8080`.

### Ollama: `llama runner process has terminated`

Often **RAM**, a **bad pull**, or **Ollama + Metal + new Macs**. Try a smaller Ollama model, reinstall Ollama, or **switch to MLX** (section above) on Apple Silicon.
