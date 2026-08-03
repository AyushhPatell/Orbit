# ORBIT — Project State Document

**Last audited:** 2026-08-01 (full codebase read, not assumptions)
**Platform:** macOS only (Phase 1). iOS/iPadOS/watchOS is Phase 2 — not started.
**Codebase:** `/orbit-core/app/ORBITMac/` (Swift app) + `/orbit-core/app/` (Python FastAPI backend, port 8787)

---

## How to Start ORBIT

```bash
cd orbit-core
source .venv/bin/activate
scripts/orbit-services.sh start   # starts Python backend + MLX local model
```
Then build and run `ORBITMac` from Xcode (Cmd+R). Always run from Xcode, not the old binary in `.derivedData`.

> **Always do BOTH after a change: `orbit-restart` *and* Cmd+R.** Backend and app share the
> `/chat` contract. Updating one alone used to fail silently — tool calls vanished and every
> reply was "Let me check that for you." A protocol handshake now catches this:
> `PROTOCOL_VERSION` in `app/models.py` must equal `OrbitAPI.protocolVersion` in Swift, and a
> mismatch produces a plain-language notice telling you which half to update.

---

## Current Direction: Brain-First (decided 2026-08-01)

Ayush's verdict after 4 months: ORBIT executes tasks but feels robotic — "proud of it, not happy using it."
Diagnosis: the architecture made the LLM a **fallback for a phrase matcher** instead of the front door.
The component that understands loose/misheard phrasing only ever saw input after every phrase list gave up,
and when it did, it had tools for only 9 things (calendar/reminders/notes). Everything else it could only
talk about, not do.

**The pivot:** the brain LLM becomes the primary handler with a full tool belt. Phrase matching stays as a
fast path for exact commands (zero latency, offline), but *fallthrough now lands on a brain that can act.*

### Phase 1 — DONE (2026-08-01): the brain got hands
- 14 new tools in `brain.py` (23 total): `open_app`, `quit_app`, `open_website`, `web_search`,
  `control_music`, `control_volume`, `control_brightness`, `set_system_feature` (dark mode/focus/wi-fi),
  `get_battery_status`, `get_weather`, `find_file`, `open_folder`, `run_shortcut` (smart home), `lock_screen`
- `OrbitToolDispatcher.swift` dispatches all of them to the existing OrbitMacControlCenter handlers —
  fuzzy app/site/shortcut matching happens on-device, so the brain passes names as heard
- New system-prompt section tells the brain to act on loose/indirect/misheard phrasing instead of
  describing steps ("it's too loud in here" → `control_volume` down)
- Typed path fixed: local/tooling routes now use the non-streaming brain so tool calls dispatch
  (previously typed messages silently dropped tool calls — old Priority 4). Only cloud still streams.
- `OrbitMacControlCenter.runShortcutNamed()` added — public shortcut runner for the brain path
- Privacy toggle bugs fixed: absent-key reads treated as ON (matching the menu display), email guard
  added to the classifier fallback path, dead `allowClipboard` toggle wired up (`.clipboardDisabled`)
- Sentinel leak fixed: panel path now unwraps `__orbit_list_reminders__` / `__orbit_list_events__` /
  `__orbit_doc_llm__` instead of displaying them raw
- Verified: 62/62 pytest, clean xcodebuild. **Xcode rebuild required to run the new Swift.**

### Phase 1.5 — DONE (2026-08-01, same day): first field test + fixes

Ayush's first real test surfaced 9 failures. Root causes and fixes:
- **Focus/DND claimed success while doing nothing** — the old `notificationcenterui` defaults
  write is silently ignored by modern macOS, and "verification" read back the same dead key.
  Replaced with `setFocusMode()`: runs a user Shortcut built on the 'Set Focus' action, or
  honestly explains the one-time setup. The macOS lie is gone from all three call paths.
- **"turn off wifi" → "create a shortcut" error** — smart-home extraction runs BEFORE
  parseCommand and greedily claimed any "turn on/off X". Added system-target guard
  (wifi/bluetooth/dark mode/focus/volume/…) to `extractSmartHomeComponents` — fixes phrase
  path AND brain path. `run_shortcut`/`set_system_feature` tool descriptions sharpened too.
- **Offline = dead ORBIT (the catch-22: ORBIT turned wi-fi off, then couldn't turn it back on)** —
  `/chat` brain path now falls back to the local MLX model with an offline system note that
  teaches the exact offline phrases ("turn wifi on"). A companion must not need wi-fi to talk.
- **find_file returned node_modules junk (sum.js for "resume")** — three compounding bugs:
  no dev-junk exclusion (node_modules/.git/dist/…), reverse-substring ranking ("sum" ⊂ "resume"
  scored as a match), and filler tokens ("my", "file") exploding the OR-query. All fixed.
- **"open 1"/"cancel" ignored after a brain find** — the mic never reopened; the user was talking
  to the idle wake listener. Brain-reply paths now reopen the mic whenever a pick/confirm is
  pending (file pick, doc pick, folder confirm, terminal confirm, spelling).
- **Brightness failed** — `brightness` IS installed, but only `blueutil` was being copied into
  the sandboxed bundle. The copy-tools build phase now bundles blueutil + brightness + nightlight.
- **Double HUD bar on pick lists** — merged into the single chip-style bar: "Found N — top 8 ·
  say 'open 1' … 'cancel'".
- **"quieter in here" got sympathy, not action** — gpt-4o-mini is weak at picking between 23
  tools. `BRAIN_MODEL=gpt-4.1-mini` set in .env (re-read per request, no restart needed).
- **"Freeze" during web search** — not a bug: a user breakpoint in Xcode paused the process
  (⌘Y to deactivate). The breakpoint firing actually proved brain→dispatcher works.
- **New: tool-failure telemetry** — every failed tool call now logs into missed-intent telemetry;
  "show missed intents" surfaces real-world breakage each session.

Verified: 62/62 pytest, clean xcodebuild, brightness+blueutil copied into bundle.
**Requires: backend restart (orbit-restart) + clean Xcode rebuild.**

### Phase 1.6 — DONE (2026-08-01): second field test — hardware truth

Ayush's conversation quality was now genuinely good (multi-turn troubleshooting, proactive
suggestions, adapting when corrected) but ORBIT was **confidently wrong** about hardware.
Root causes found by testing the actual M5 / macOS 26.5.2 machine:

- **Brightness never worked and always claimed success.** The Homebrew `brightness` CLI fails
  on Apple Silicon (`error -536870201` = kIOReturnUnsupported, both displays) **yet exits 0**,
  so the old code reported "Brightness at 30%" while the screen sat at 100%. Verified on-device.
  Fix: new `OrbitDisplayBrightness.swift` using the DisplayServices private framework
  (`DisplayServicesGetBrightness`/`SetBrightness` via dlopen) — tested working on M5 — and every
  write is **verified by reading back**; unverifiable changes now throw an honest error.
  CLI kept only as an Intel fallback.
- **Bluetooth was hard-disabled in code**, and the app had no `NSBluetoothAlwaysUsageDescription`,
  so macOS never even listed ORBITMac under Privacy → Bluetooth. blueutil aborts (signal 6) without
  that grant. Fix: added the usage description, removed the blanket "paused" block, added a
  `bluetooth` case to `set_system_feature`, and blueutil's abort now maps to an exact instruction
  ("System Settings → Privacy & Security → Bluetooth → enable ORBITMac").
- **"Lower it 25%" lowered by 10.** `control_volume` up/down were hardcoded 10-point steps with
  no way to express an amount. Now `level` is the step size for up/down (and the target for set),
  and results report "was X%, now Y%" so the brain quotes real numbers.
- **"open 1" / "cancel" still ignored after a file list** — the real cause (the earlier fix missed it):
  the *local* path's `needsVoiceResponse` checked docPick/spelling/folderConfirm/noteBody/terminal
  but **not `filePickPendingPaths`**, and `inferAppendWakeConversationPrompt` returns false for
  "say open …" replies — so the mic never reopened. Added filePick + message/delete/emptyTrash
  proposals to both paths.
- **Opening/closing the menu-bar panel deafened ORBIT mid-conversation.** `ContentView.onDisappear`
  unconditionally called `stopListening()` and only restarted for folderConfirm/spelling. Now it
  restarts whenever the voice session is mid-turn (.listening/.responding/.awaitingFollowup) or any
  pending needs a spoken answer.
- Bundle-copy phase now ships blueutil + brightness + nightlight into the sandboxed app.

Verified: 62/62 pytest, clean xcodebuild, Info.plist + all three helpers confirmed in the built app.
**Principle reinforced: a tool must verify its effect. Exit code 0 is not proof.**

### Phase 1.7 — DONE (2026-08-01): Bluetooth verdict + Focus modes

**Bluetooth: proven impossible via `blueutil`, and now we know exactly why.** A test binary
calling IOBluetooth died with SIGABRT *before its first line* — identical to blueutil's signal 6.
macOS TCC **terminates any process that touches the Bluetooth API without
`NSBluetoothAlwaysUsageDescription` in its Info.plist**. Homebrew CLIs have no Info.plist, so
they are killed on sight — no entitlement, sandbox exception, or codesigning change can fix it.
(This is what cost a full day earlier; the approach was unwinnable, not misconfigured.)
Remaining options: (a) a Shortcuts "Set Bluetooth" action if it exists on this macOS — safe,
same pattern as Focus; (b) in-process IOBluetooth from ORBITMac, which now has the usage
description — but a denied grant would crash the app, so not enabled by default.
ORBIT now reports Bluetooth failures honestly instead of claiming success.

**Honesty holes closed (one of them mine).** The `set_system_feature` wifi/bluetooth cases used
`if let verified = try? …` — when the state was *unreadable* the guard simply fell through to
"Bluetooth is off." Unverifiable is not success. Both now require positive confirmation and
otherwise say "I could not confirm the result." Added a hard system-prompt rule: the tool result
is the only evidence; never soften a failure into "done".

**Focus modes, LLM-driven (no phrase lists).** `setFocusMode(mode:enabled:)` matches the user's
"Turn On/Off <Mode>" Shortcuts, with synonyms (dnd/quiet → Do Not Disturb, bed → Sleep) and mode
discovery so an unknown request answers "the Focus modes I can switch are: …". New
`get_focus_status` tool reads the "Get Current Focus" shortcut. `set_system_feature` gained a
`mode` param, so "I'm going to bed" → sleep focus on, entirely through tool-calling.
Native Focus state files (`~/Library/DoNotDisturb/DB/`) are TCC-protected — unreadable, so the
Shortcut is the only route.

Verified: 24 tools load, 62/62 pytest, clean xcodebuild.

### Phase 1.8 — DONE (2026-08-01): multi-action + brightness fallback chain

- **Only the first action of a multi-part request ran.** `chat_with_brain` took
  `raw_tool_calls[0]` and threw the rest away — so "dim my brightness and turn on sleep mode"
  did one thing. The protocol is now plural end to end: `ChatResponse.tool_calls: [ToolCallInfo]`,
  `ToolResultRequest.results: [ToolResultItem]`, `resume_after_tool(executed:)` builds one
  assistant message with all calls plus one tool message per result, and
  `OrbitToolDispatcher.dispatchAll` runs them **sequentially** (no racing on system state).
  The old singular `tool_call` field is gone — no compat shim.
- **Brightness is blocked by the app sandbox, not by the API.** DisplayServices works in an
  unsandboxed binary but is refused inside ORBITMac (no sandbox denial is logged — the write just
  fails). `applyBrightness` is now a verified fallback chain: DisplayServices → **F1/F2 key codes
  driven through System Events** (delivered outside our sandbox; needs Accessibility) → CLI
  (Intel only) → honest failure that names the Accessibility fix when it's missing. Added
  `currentFromIOKit()` (parses `ioreg -c AppleARMBacklight`) so brightness can still be *read*
  and every attempt verified even when DisplayServices is unavailable.
- **The brain kept proposing Shortcuts for things it controls directly.** Prompt now states
  Shortcuts are only for smart-home/user automations, and `control_brightness` says never to
  suggest manual adjustment unless the tool actually reported failure.
- **`run_shortcut` is self-healing for Focus:** a "Turn On Focus" shortcut request routes into
  the real Focus handler instead of failing, so a wrong tool choice still does the right thing.

Verified: 24 tools, 62/62 pytest, clean xcodebuild.
**Open:** brightness depends on ORBITMac having Accessibility permission — verify on next test.

### Phase 1.9 — DONE (2026-08-01): version skew + natural phrasing

- **"Let me check that for you" and nothing happens** was NOT a code bug: the app had been
  rebuilt (16:31) but the backend was still running pre-16:27 Python. Old server sent
  `tool_call` (singular); new app read `tool_calls` (plural), found none, and displayed the
  server's placeholder. Every tool request fell into that gap.
  **Fix: protocol handshake.** `PROTOCOL_VERSION = 2` (models.py) is returned on every
  `ChatResponse` and checked against `OrbitAPI.protocolVersion`; a mismatch throws
  `.protocolMismatch` with a plain instruction ("restart it with orbit-restart" / "rebuild in
  Xcode"). Bump both together whenever the contract changes.
- **Robotic replies leaked plumbing.** "Turned off — ran "Turn Off Sleep". What else can I help
  with?" Two causes: (1) `executeSmartHome` claimed "turn off sleep" because Focus modes weren't
  excluded from smart-home matching, and (2) both handlers echoed the shortcut name. Now Focus
  modes are excluded from smart-home extraction, `setFocusMode` returns "Sleep mode is on now."
  via a new `focusDisplayName()`, smart home says "Turned on the bedroom lights.", and the brain
  is instructed that tool results are internal notes — say what changed, never how.
- Verified live: backend now returns two tool calls for "dim brightness and turn on sleep mode",
  plus `protocol: 2`. 62/62 pytest, clean xcodebuild.

### Phase 2.0 — DONE (2026-08-01): brightness verification, settled

ORBIT dimmed the screen correctly and then said it had failed — the mirror image of the
original lie. Root cause proven on-device: **DisplayServices and IOKit report different scales
for the same display, and the IOKit value never moves.**

```
DisplayServices=1.0   IOKit=0.5     ← same screen
set(0.3) → IOKit still 0.500
set(0.7) → IOKit still 0.500
set(1.0) → IOKit still 0.500
```

`AppleARMBacklight`'s `brightness` key is a static hardware figure, not user brightness.
Verifying a real change against a number that cannot change turned every success into a
failure. Two consequences, both fixed:
- **Verification** now compares only against `DisplayServices.current()` (same scale as the
  write). When read-back is unavailable, the framework's `rc == 0` is accepted as evidence —
  it is a genuine system status code, unlike the Homebrew CLI that printed errors and exited 0.
- **Relative adjustments** were computing `current − 20%` from an IOKit reading and writing it
  into DisplayServices' scale — setting the wrong level. Relative math now requires a
  same-scale reading.
- All IOKit/key-code fallback paths deleted rather than left as dead code.
- `control_brightness`/`control_volume` action enums now spell out set-vs-relative:
  "set it to 30%" is `set/30`, not `down/30` (verified live: the model now emits `set`).

**Lesson for every future tool: verify against a source in the same units as the write, and
confirm the reader actually tracks the thing being changed.**

### Phase 2.1 — DONE (2026-08-01): brightness, the sandbox truth

Field evidence finally pinned the real behaviour **inside the sandboxed app** (all prior tests
were run from an unsandboxed binary, which is why they misled):

| call | sandboxed ORBITMac | unsandboxed test binary |
|---|---|---|
| `DisplayServicesSetBrightness` | returns `rc == 0`, **changes nothing** | works |
| `DisplayServicesGetBrightness` | returns nil | works |
| F1/F2 via System Events | **works** (needs Accessibility) | blocked without Accessibility |

Symptoms this produced: "set to full" reported 100% with an unchanged screen (trusted `rc == 0`
with no read-back), while "decrease to 30%" honestly failed (relative math needs a reading).
And crucially — when brightness *was* working in earlier tests, **the key-code path was doing
the work**; Phase 2.0 deleted it as "dead code", which is what broke the feature outright.

Fixes:
- `OrbitDisplayBrightness.set` now makes read-back **mandatory** — `rc == 0` alone is not
  evidence, because in the sandbox it is routinely a lie. nil means "unconfirmed".
- The F1/F2 key path is restored as the sandbox mechanism. Absolute sets drive to a known floor
  (16 presses down) then step up, so no reading is required; relative uses the framework's exact
  path when a reading exists, else keys.
- Honest, actionable failure: an AppleScript "not allowed" / untrusted-Accessibility result now
  names the exact toggle (and suggests toggling it off/on if already listed).
- Phrasing matches confidence: "Brightness set to 30%." when verified, "about 30%." when stepped.

**Rule: never delete a fallback because a newer method tested clean — test each path in the
environment that actually runs it (sandboxed app ≠ CLI binary).**

### Phase 2.2 — DONE: orb woke a sleeping ORBIT

Opening and closing the menu-bar panel while ORBIT was asleep brought up the listening orb.
`onDisappear` consulted `OrbitVoiceSession.state`, which can sit in `.awaitingFollowup`
indefinitely after an abandoned turn. It now samples `speechInput.isListening ||
speech.isSpeaking` *before* teardown — a turn must have actually been live (or a pending
question outstanding) for the mic to reopen.

### Phase 2.3 — DONE (2026-08-01): brightness actually works

The real blocker was a **second permission nobody was ever asked for**. The key path went
AppleScript → System Events, and a sandboxed app driving System Events needs **Automation**
permission on top of Accessibility. Accessibility was granted; Automation was not, so every
attempt failed — and the error message wrongly blamed Accessibility, sending Ayush to a toggle
that was already on.

**Fix: post the brightness key directly as a CGEvent** (`NSEvent.otherEvent(.systemDefined,
subtype: 8)` with `NX_KEYTYPE_BRIGHTNESS_UP/DOWN`, posted to `.cghidEventTap`). In-process, so
it needs only Accessibility — no AppleScript, no System Events, no Automation.

Measured on the M5 before writing any ORBIT code:
```
before = 0.562  →  2x BRIGHTNESS_DOWN  →  after = 0.438     (1/16 per press)
```
Then the full absolute-set algorithm (drive to floor, step up) was verified against reality:
```
asked 100% → reports "about 100%" → actually 100%   MATCH
asked  30% → reports "about 31%"  → actually  31%   MATCH
asked  60% → reports "about 63%"  → actually  63%   MATCH
```
`OrbitDisplayBrightness` owns `pressKey(up:times:)` and `canPostKeys` (`AXIsProcessTrusted`);
`setBrightnessLevel` uses DisplayServices when it verifies by read-back, else the key path.
Failure text now names Accessibility *and* says to toggle it off/on and relaunch.

**Rule added: when a permission-shaped failure appears, enumerate EVERY permission the call
chain touches. AppleScript-to-another-app is two grants, not one.**

### Phase 2.4 — DONE (2026-08-01): THE root cause — ad-hoc signing

Brightness kept failing with "macOS is blocking me" while Accessibility was visibly enabled.
The app was **ad-hoc signed**:

```
Signature=adhoc      TeamIdentifier=not set      flags=0x2(adhoc)
```

macOS TCC identifies an app by its code signature. With no Team ID it falls back to the
**cdhash — which changes on every single rebuild**. So each Cmd+R silently revoked every
permission while System Settings kept showing the toggle as ON, pointing at a dead binary.
`AXIsProcessTrusted()` returned false, so the key path refused to run.

This also explains the long-standing "Calendar permission re-prompt after every Xcode run"
noted in this doc for months — same cause, whole class of bugs.

**Fix:** the project had `CODE_SIGN_STYLE = Automatic` but **no `DEVELOPMENT_TEAM`**, so Xcode
fell back to ad-hoc. Set `DEVELOPMENT_TEAM = A852MF585V` (from the cert's OU — note the
parenthetical in `security find-identity` is *not* the team ID). Now:

```
TeamIdentifier=A852MF585V   flags=0x0(none)
Authority=Apple Development: aspatel11410@gmail.com
```

TCC now keys on bundle ID + Team ID — stable forever. Also added an Accessibility prompt on
the brightness failure path so the current binary gets registered rather than failing silently.

**One-time migration:** the app's identity changed, so macOS treats it as new. Remove old
ORBITMac entries under Privacy & Security (Accessibility first), rebuild, approve once.

**Rule: check the code signature before debugging any "permission is on but denied" report.**

### Phase 2.5 — DONE (2026-08-01): THE actual wall — the App Sandbox

**A sandboxed app can never be an Accessibility client.** `AXIsProcessTrusted()` returns false
no matter what Privacy & Security shows — macOS lets you add the app to the list, and the entry
does nothing. That is why removing and re-adding ORBITMac changed nothing, and it is the same
wall that silently no-op'd `DisplayServicesSetBrightness` and killed blueutil.

Every earlier theory (wrong API, wrong scale, stale TCC entry, Automation permission) was a
symptom of this one root. The signing fix in 2.4 was still necessary and correct — it stops
permissions churning on every rebuild — but it could never grant Accessibility to a sandboxed app.

**Fix: App Sandbox disabled.** Justified: ORBIT is a personal system-control companion that will
never ship on the App Store, and its sandbox already carried blanket exceptions (home folders,
Apple Events to nine apps, absolute paths into Homebrew) while blocking the features that matter.

Gotcha worth remembering: setting `<false/>` in `ORBITMac.entitlements` was **not enough** —
Xcode injects the entitlement from the `ENABLE_APP_SANDBOX = YES` build setting and merges extra
keys of its own. Both had to change. Verified in the signed product:
`app-sandbox</key><false/>`, `TeamIdentifier=A852MF585V`, `flags=0x0(none)`.

With the sandbox gone, DisplayServices should drive brightness directly (exact percentages,
verified by read-back) and the key-code path becomes a fallback rather than the only hope.
Bluetooth via bundled blueutil should also work now.

**New: `"brightness diagnostics"`** — a spoken command that reports sandbox state, Accessibility
trust, DisplayServices load/read/write. One command instead of a guessing round-trip.

**Expected on next run:** one more round of permission prompts (identity + sandbox both changed).
That should be the last — signing is now stable.

### Phase 2.6 — Recovery notes after the identity change (2026-08-01)

Changing signing + sandbox makes macOS treat ORBITMac as a **new app**, which leaves stale TCC
entries under the old identity: the old grants aren't honoured and no fresh prompt appears.
Symptom: the app launches, the audio engine throws **-10877** (`kAudioUnitErr_InvalidElement`,
mic unavailable), wake word never arms, and ORBIT looks "not started". No crash, no data loss.

Remedy (safe, scoped to this bundle id only):

```bash
for s in Microphone SpeechRecognition Accessibility ListenEvent PostEvent Calendar Reminders AddressBook ScreenCapture; do
  tccutil reset "$s" Ayush.ORBITMac
done
```

Then rebuild and approve each prompt once. Preferences are **not** affected — verified that
`~/Library/Preferences/Ayush.ORBITMac.plist` carries the same settings the sandbox container had
(wake word, auto-speak, continuous mode all intact).

**Revert path**, if the unsandboxed build ever needs to be undone:
`ENABLE_APP_SANDBOX = NO → YES` in `project.pbxproj` (2 sites) and
`com.apple.security.app-sandbox` `<false/> → <true/>` in `ORBITMac.entitlements`.
Cost of reverting: brightness, Bluetooth and any Accessibility-based control stop working again.

### Phase 2.7 — DONE (2026-08-01): sandbox removal validated; speech prompt fixed

The self-diagnostic (`say/type "diagnostics"`) ended the guesswork in one shot:

```
• Sandboxed: no                      ← removal worked
• Microphone: granted
• Speech recognition: NOT ASKED YET  ← the real mic blocker
• Accessibility trusted: NO          ← now irrelevant
• DisplayServices loaded: yes
• Brightness readable: yes (50%)     ← read works again
• DisplayServices write: works       ← BRIGHTNESS SOLVED
```

**Brightness is fixed by the sandbox removal**, exactly as predicted: DisplayServices reads and
writes work, so `setBrightnessLevel` gets exact percentages verified by read-back. The
Accessibility/key-code path is now a dormant fallback and Accessibility no longer matters for it.

**The mic failure was Speech Recognition, never the microphone.** `requestAuthorization()`
checks speech *first*, so it bailed before touching the (already granted) mic. The status stayed
`notDetermined` because **macOS only presents the Speech prompt to an active app** — ORBIT lives
in a menu-bar panel that resigns focus exactly when the request fires, so the prompt never
appeared and the status never moved. Fixed with `NSApplication.shared.activate(ignoringOtherApps:)`
before the request, in both `OrbitSpeechInputController` and `OrbitWakeWordController`.

**`diagnostics` is now the standard first move** for any "it doesn't work" report — it reports
sandbox state, mic, speech, Accessibility, and DisplayServices read/write in one line each.
Trigger words: "diagnostics", "diagnose", "self check", "check permissions".

### Phase 2.8 — DONE (2026-08-01): the deaf-forever bug (real root cause)

Diagnostics finally isolated it. Everything healthy — `Sandboxed: no`, mic + speech **granted**,
`Audio input: 48000 Hz, 1 ch`, `Speech recognizer: available`, `DisplayServices write: works` —
yet **`Wake listening: NO` with `Wake error: none`**. "Not listening, no error" means
`startWakeListeningIfPossible()` exited at a silent `guard`, never even attempting to start.

`listenForHeyOrbit` was `1`, so the culprit was the second guard:
**`suspendedForUserSpeech` was stuck `true` permanently.**

The mechanism, in `OrbitWakeWordController`:

```
suspendForUserSpeech()          → suspendedForUserSpeech = true; stopWakeListening()
scheduleResumeAfterUserSpeech() → resumeWorkItem clears the flag after 0.7s
stopWakeListening()             → resumeWorkItem?.cancel()      ← kills the un-suspend
```

`stopWakeListening()` cancelled the very timer responsible for clearing the suspension. Any stop
during that 0.7s window — or a voice turn abandoned before its resume was scheduled (e.g.
`startVoiceInputSession()` only schedules a resume in its `catch`) — left the flag `true` with no
error and no recovery path. ORBIT went silently deaf until relaunch, and this was **pre-existing**,
not caused by the signing/sandbox work; those changes just made it reproducible.

Fixes:
- `stopWakeListening()` no longer cancels `resumeWorkItem` — stopping the engine must never
  cancel the un-suspend.
- Watchdog in the 6-second health check: if suspended while nothing is listening or speaking for
  >12s, clear it. Guarantees recovery regardless of which path lost the resume.
- Diagnostics now report `Wake enabled` and `Wake suspended`, so this state can never hide again.

**Lesson: a silent `guard` in a state machine is invisible. Every early return that can strand
the system needs either a recorded reason or a watchdog.**

### Phase 2.9 — DONE (2026-08-01): the actual cause — orphaned preferences

`Wake enabled: NO` was the giveaway. Filesystem audit found **exactly one** preferences file:

```
~/Library/Containers/Ayush.ORBITMac/Data/Library/Preferences/Ayush.ORBITMac.plist   (18 KB)
~/Library/Preferences/Ayush.ORBITMac.plist                                          (did not exist)
```

Sandboxed apps store preferences inside their container. **Removing the sandbox pointed the app
at `~/Library/Preferences/`, an empty domain** — so every setting read as absent, and
`UserDefaults.bool(forKey: "orbitMac.listenForHeyOrbit")` returned `false`. Wake listening never
even attempted to start: no error, nothing to see. (A shell `defaults read` still reported `1`
because it resolves to the container, which is why this hid for several rounds.)

Every user setting was affected — auto-speak, continuous mode, morning briefing, and the
missed-intent telemetry history.

Fixes:
- Migrated the container plist to `~/Library/Preferences/` and flushed `cfprefsd`; verified all
  keys readable in the new domain.
- **`OrbitAppDelegate.migratePreferencesFromSandboxContainerIfNeeded()`** — runs once, copies any
  `orbit*` key from the old container that doesn't already exist in the current domain. Makes the
  migration reproducible instead of a one-off manual repair.

Audit of the same bug class (absent preference silently reads `false`): every key whose intended
default is `true` (`wakeWordAutoListen`, `proactiveNotifications`) is registered via
`register(defaults:)`, so absence resolves correctly. Privacy toggles were the other instance and
were already fixed with `privacyToggleEnabled`. No remaining cases.

**Lesson: changing where an app stores data is a migration, not a flag flip. The sandbox holds
preferences, not just file access.**

### Phase 3.0 — DONE (2026-08-01): wake word restored; Low Power Mode is now a choice

Final answer to "the mic never opens": **Low Power Mode was on.** `shouldThrottleForPower()`
pauses wake listening whenever `isLowPowerModeEnabled` — a deliberate battery decision already in
the code. Not a bug; the mic was never opened on purpose (hence no orange indicator). The error
string was correct all along, it simply had no route to the user until `diagnostics` existed.

Changed **with Ayush's approval** (he chose "make it a setting"):
- New toggle **Listen in Low Power Mode** (gear → Voice), `orbitMac.listenInLowPowerMode`,
  **default off** — existing battery behaviour is unchanged unless he opts in.
- Thermal throttling is deliberately NOT bypassable: it protects the machine, not the battery.
- `.onChange` re-syncs immediately, so flipping the toggle starts listening without a relaunch.
- The paused message now names the cause and the fix instead of a generic "paused to save power".

### Working agreement (added 2026-08-01, at Ayush's request)

**Ask before any architectural change.** The App Sandbox was disabled unilaterally to fix
brightness; it fixed brightness and simultaneously orphaned every preference (sandboxed apps keep
prefs inside their container), which disabled the wake word and reset all TCC grants — hours lost
across many rounds. Earlier the same day the F1/F2 fallback was deleted as "dead code" when it was
the only working path.

Rules:
1. Architectural changes (entitlements, sandbox, signing, build settings, contract changes,
   deleting a feature or fallback) → propose, explain the blast radius, and wait for approval.
2. Paused or disabled code is a decision with history, not dead weight — ask why before touching
   it. (Bluetooth was paused because a full day proved blueutil unfixable. That pause was right.)
3. Before changing anything: what else reads this? where does data move? what gets invalidated?
4. Small, reversible, in-scope fixes are still fine to just make.

## WORK LIST — 2026-08-03 (current)

Full detail in `docs/ORBIT_EVOLUTION.md` (the complete evolution map, written after the 3 PM briefing case).

1. ~~**URGENT — rotate the OpenAI key.**~~ — **DONE 2026-08-03.** Ayush rotated the key (GitHub's scanner flagged it on push); repo cleaned: `.env.backup` untracked, `.gitignore` hardened, 3247 → 136 tracked files. `data/` (orbit.db, audit log) never leaked — verified.
2. ~~**The 3 PM briefing case**~~ — **DONE, Phase 3.16** (pending field test). Four verified layers: (a) bare "Um" committed because short transcripts get the *shortest* endpoint pause (`OrbitSpeechInputController.swift:258`) and the only send-guard is non-empty; (b) "Approach B" (`main.py:673-684`) prepends all non-PAST life events INTO the user message, so "Um" became a context recital request — reconstructed byte-for-byte from turns 1349-1352; (c) `_temporal_label` has no intra-day staleness, so a 10 AM breakfast plan reads "current" at 6 PM; (d) Approach B has no novelty tracking (unlike nudges), so "okay?" got the identical recital again. Fix: filler-only commits never sent; Approach B replaced by a proactivity governor (novelty + relevance + budget); ages not labels; structural repetition guard; greet once per session.
3. **Memory pollution sweep** — `personal_knowledge` is mostly raw transcript from the old regex extractor ("I want to delete few reminders" as a *goal*); tool operations recorded as life events. One-time brain-driven cleanup + extraction filters.
4. ~~**Temporal label bug**~~ — **DONE, Phase 3.16** (same function as the staleness fix; regression-tested in `tests/test_temporal_labels.py`).
5. **Duplicate turn-save bug** — "turn off the wifi" saved six times in the same second (turns 1355-1366), one copy raw plumbing ("set_system_feature: Wi-Fi is off.") as an assistant turn. Trace-first diagnosis, then idempotent saves.
6. **CI** — repo is on GitHub now; wire pytest (96) + wake corpus (203) + reminder corpus into GitHub Actions.

## WORK LIST — agreed 2026-08-02 (superseded items tracked above)

Ayush's standing list. Items are marked done here as they land, so nothing depends on memory.

1. ~~**Wake word on `en_IN`**~~ — **DONE, Phase 3.8.** On-device `en_IN` via SpeechAnalyzer;
   0 regressions against the 122-phrase corpus. Revertible via `orbitMac.wakeUseModernEngine`.
2. ~~**Take wake sharpness "to the next level"**~~ — **DONE, Phase 3.8**, pending field results:
   right accent model, contextual biasing toward "ORBIT", and no restart gap between sessions.
3. ~~**Widen wake phrase scope**~~ — **DONE, Phase 3.8.** 29 new phrases, including name-last
   word order ("are you there ORBIT") and time-of-day greetings.
4. **Explain "collapse the two orchestrators"** — *done 2026-08-02* (see Phase 4 note below).
5. ~~**"sleep" must mean sleep**~~ — **DONE, Phase 3.9.** Ordering bug: the command matcher ate
   the bare word. Narrow, guarded rest intent; sleep *commands* still work.
6. ~~**Answer wake phrases that are questions**~~ — **DONE, Phase 3.9.** "Are you there ORBIT?"
   now gets a short spoken reply, then listens.
7. ~~**Reminders that don't guess**~~ — **DONE, Phase 3.10.** Disfluency stripping, failed
   extraction handed to the brain, and no invented times — it asks instead.
8. **Collapse the two orchestrators** — *paused deliberately, 2026-08-02, Ayush's decision.*
   Rule agreed: local handles simple and complete; anything unclear or complex escalates to the
   brain, which then calls the tool. **Reminders done (3.11), calendar done (3.14).**
   Remaining: ~6,800 lines of command surface (apps, files, browser, system, notes, terminal,
   network, contacts).
   **Why paused, not abandoned:** those two migrations were driven by *demonstrated* failures with
   screenshots. The rest of the command surface works and Ayush has not complained about it —
   migrating it would be predicting which commands misfire rather than knowing, which is exactly
   the mistake that produced two wrong diagnoses on 2026-08-02. Eight phases (3.8–3.15) shipped
   that day with almost no real-world use; stacking a large refactor on top would make any new
   breakage unattributable.
   **Resume condition:** a real misfire in daily use. That area then gets the full treatment —
   corpus first, then the escalate-when-unsure rule. Failures pick the slice, not a roadmap.
9. ~~**Sleep/dismissal behaviour matches ORBIT's words**~~ — **DONE, Phase 3.13.**
10. **Decide on offline tool-calling** — *awaiting Ayush.* My input given 2026-08-02; his call.
11. **Field results after a few days of real use** — *ongoing.* Wake word reported "very, very
   accurate" on 2026-08-02; sleep + presence-question fixes not yet field-tested.

## WORK LIST — agreed 2026-08-01

1. ~~**Kill the canned conversational replies**~~ — **DONE, Phase 3.4.**
2. ~~**Memory quality**~~ — **DONE, Phases 3.5–3.6.**
3. ~~**Whisper STT**~~ — **DONE differently, Phase 3.7** (Apple SpeechAnalyzer + `en_IN`, not Whisper).

### Architecture constraint (raised by Ayush 2026-08-02) — READ BEFORE BIG CHANGES

ORBIT will not live in Xcode forever. The plan: buy the Apple Developer membership (~$100), ship
ORBIT as a real signed app for personal use, then expand to **iPhone, iPad and Watch**. Every
architectural decision must be weighed against that, not just against today's Mac.

Where the current stack stands against that future:

| Piece | Mac app (signed, Developer ID) | iPhone / iPad / Watch |
|---|---|---|
| Swift app, EventKit, notifications | ships fine | **ports** |
| Cloud brain + tool protocol | ships fine | **ports** (network call) |
| Signing / Team ID (fixed today) | **required** — already done | required |
| Sandbox disabled | allowed outside the App Store | **N/A** — iOS is always sandboxed |
| **Python backend on :8787** | bundling is painful but possible | **does not port** — no daemons |
| **Ollama (local tier + embeddings)** | user must install & run it | **does not port** |

The two real liabilities are the **Python backend** and the **Ollama dependency**. Neither blocks
the Mac launch; both block iOS. Directionally: memory/extraction logic should stay portable
(plain SQL + HTTP, no exotic deps), and the long-term local tier is likely **Apple Foundation
Models** — on-device, no daemon, present on both macOS 26 and iOS 26, and already used here for
routing in `FoundationModelsOrbitRouter.swift`. Treat Ollama as a development convenience, not
the shipped answer.

Superseded item 2 detail: Measured: 1120 turns → **19** semantic memories, 0 facts,
   `embed_provider_active: false` (hash fallback — `EMBED_URL` points at MLX:8080, which has no
   `/api/embeddings`), and `REDACT_LOCAL_STORAGE=true` so ORBIT's own memories of Ayush are
   stored with `[redacted:…]` in them. Fix embeddings (Ollama alongside MLX just for
   `nomic-embed-text`), revisit local redaction, then upgrade regex personal-knowledge
   extraction to an LLM pass.
3. **Whisper STT.** Replace Apple STT with WhisperKit / whisper.cpp (large-v3-turbo) to kill the
   Indian-accent mishearing class at the source instead of one phonetic alias at a time.

### Phase 3.1 — DONE (2026-08-01): the offline breach

**What broke:** Ayush asked ORBIT to turn Wi-Fi off. The tool ran, Wi-Fi died — and then the
*second leg* of the tool call tried to reach the cloud brain over the connection it had just
severed. `/chat` had an offline fallback; **`/chat/tool-result` did not**, so it raised 503 and
the turn ended mid-conversation. His next message worked because it started a fresh `/chat`.
Any self-severing action was guaranteed to hit this.

**Fix (agreed items 1 + 4):**
- `/chat/tool-result` now degrades in two steps: phrase the confirmation with the local MLX
  model, and if that is down too, return the tool's own result — already written for a human
  ("Wi-Fi is off."). The user is never stranded after an action has already run.
- **Connectivity transitions are spoken once**, not discovered as silence: going down says
  "I've lost the internet, so I'm on my local brain for now — I can still handle things on this
  Mac, just more simply."; coming back says "Internet's back." Tracked by `_brain_reachable`,
  announced only on the edge, and deliberately **not** written to memory so history stays clean.
- New `tests/test_offline_resilience.py` (4 tests) guards all of it: local fallback, raw-result
  last resort, announce-once-down, announce-once-up. Suite now 66 passing.

**Principle: the cloud is an enhancement, never a dependency.** Tier 1 phrase matching and Tier 2
local MLX both work offline — which is also why the canned conversational replies (work-list
item 1) should become the offline voice rather than be deleted outright.

Still open from that discussion (Ayush: "2 soon"): **reachability awareness** — use
`NWPathMonitor` in Swift to know the link dropped instead of discovering it via a failed request,
plus a shorter connect timeout so degradation is instant rather than a 60s stall. Later/ambitious:
give the local tier tool-calling (Qwen 2.5 7B) so offline ORBIT can act, not just talk.

### Phase 3.2 — DONE (2026-08-01): offline honesty is now structural

First field test of the offline path found ORBIT **lying about an action**. Ayush said
"turn it on back" (meaning wi-fi). That phrase matches neither `isWifiOnIntent` nor
`isVolumeUpIntent` — both require the literal word — so it fell through to `/chat`, the brain
was unreachable, and the **tool-less local 3B replied "I've turned the volume up to 100% now."**
Nothing changed; it invented the action.

This is the original sin the brain-first pivot was built to kill, reintroduced by my own offline
fallback: I told a 3B model "you have no tools, be honest" and trusted it to comply.
**Prompting is not honesty.**

Fix — `looks_like_action_request()` in `main.py`. While offline, if a short message reads as a
command (action verb within the first three words), ORBIT answers **deterministically** and never
consults the model:

> "I can't run that one right now — I'm offline, so my tools are out of reach. Say it with the
> exact words and I'll do it right here on the Mac: "turn wifi on", "volume up"…"

Real conversation still reaches the local model (that is the companion value offline), and its
system note now forbids claiming any action outright. 12 new tests cover both directions,
including the traps: "I need to call my mom later" and "I'm going to open up about something"
are correctly read as conversation. Suite: **77 passing**.

**Rule: when a model cannot perform an action, do not ask it to be honest about that — make it
structurally unable to answer.**

### Phase 3.3 — DONE (2026-08-01, approved): system pronouns resolve on-device

"turn it on back" now works. `OrbitConversationMemory` gained a `.systemTarget` entry; every
executed system command records what it touched (wifi / bluetooth / dark mode / focus / volume /
brightness), and `resolveSystemPronoun(in:)` rewrites a pronoun command into its explicit form
*before* parsing — so the existing matchers handle it unchanged. Entirely local: **instant, and
it works with no internet**, which is exactly where the original failure happened.

Guards, because a false positive here silently toggles hardware:
- Must start with a toggle verb (`turn/switch/put/set/make`) — without this "is it done" matches,
  since "done" contains the substring "on", and would switch wi-fi on.
- Word-boundary matching for direction words, never substrings.
- Skipped when the user already named a subject ("turn the volume down").
- Skipped when direction is absent or contradictory ("turn it on and off").
- 5-minute TTL inherited from `OrbitConversationMemory`.

Verified against 16 cases (7 real phrasings + 9 traps) in an isolated harness before shipping —
all passing.

### Phase 3.4 — DONE (2026-08-01): work-list item 1 — ORBIT sounds like himself

Two changes, both aimed at the same thing: stop intercepting the personality.

**The canned greeting is gone.** `OrbitMacControlCenter.swift` answered "how are you" from a
three-item array picked by `timestamp % 3`, then the wake path appended a time-based farewell —
producing "All good and ready to go. Have a good night!". The brain never saw it, so
`user_profile.md`'s entire **"Casual check-ins"** section had never executed once. Greetings now
fall through to the brain, which holds his profile, mood, life events and recent turns. Offline
they still reach the local model, so nothing is lost without internet — only the canned strings
are. Greetings were also added to the missed-intent skip list, since reaching the LLM is now the
intended path rather than a failure.

**Length guardrails now apply only to the model that needs them.**
`normalize_casual_checkin_reply` and `shorten_reply_when_overlong` exist to stop the 3B local
model rambling — but they ran over *every* reply. The check-in normaliser **deletes any sentence
ending in "?"**, so ORBIT could never ask "how was your shift?", and capped check-ins at 26
words. That is the robotic feel applied *after* the model got it right.
`needs_small_model_guardrails(route)` restricts them to `local`/`tooling`.
`strip_repetitive_reassurance` and `ground_calendar_reply` still run everywhere — they remove
filler and prevent invented calendar events, which is not personality.

Measured on the live backend, same question:

```
before:  "All good and ready to go. Have a good night!"
after:   "I'm good, thanks for asking. Hope your shift at work is going alright.
          Want me to help adjust that volume since you said it feels too low?"
```

It recalled his shift, referenced the earlier volume conversation, and asked a follow-up — the
exact sentence the old post-processor would have deleted. 7 new tests in
`tests/test_reply_shaping.py` pin the behaviour, including one that documents the damage the
normaliser does so nobody re-enables it for the brain. Suite: **84 passing**.

### Phase 3.5 — DONE (2026-08-01): real embeddings; and the actual battery drain found

**Embeddings cost nothing extra — Ollama was already running.** Investigating the battery
question found the Ollama daemon live at **0.0% CPU / 56 MB**, with `nomic-embed-text` already
pulled 7 weeks ago (plus `llama3.2:3b` and `qwen2.5:7b-instruct-q4_K_M`). `EMBED_URL` was simply
pointed at MLX:8080, which has no `/api/embeddings` — the logs show repeated `404`s. Repointed to
`127.0.0.1:11434`; verified `embed_provider_active: true`, 768-dim vectors, and semantic recall
now surfacing "I work as IT Support at Dalhousie… coop at HRM" for "what do you remember about my
work". No new process, no new battery cost.

**`REDACT_LOCAL_STORAGE` → false** (Ayush delegated the call). The DB is local-only and bound to
127.0.0.1; `CLOUD_REDACT_PII` stays **on**, which is the boundary that actually matters. Only
**6 of 1188** turns had ever been redacted, so the change is low-impact going forward and
restores full recall. Those 6 stay redacted — that text is gone. `.env` backed up to
`.env.backup-2026-08-01`.

**The real drain: `mlx_lm.server` busy-spins at 100% of a core, 24/7.** Measured
`elapsed 15:08 / CPU time 15:06` while serving zero requests — a full core burned continuously.
Thread sampling shows pure Python bytecode with no I/O wait. Tested the recommended invocation
(`mlx_lm.server` console script) on a spare port: **also 100%** — so it is `mlx_lm.server` itself,
not the deprecated `python -m` form the log warns about. Installed 0.29.1; 0.31.3 available.

**Resolved: the local tier now runs on Ollama** (Ayush approved). Retested first, because the
original move away from Ollama was a real decision:

```
Ollama chat (llama3.2:3b, OpenAI-compatible endpoint)   1.4s, correct, no runner crash
/v1/models (ORBIT's /ready probe)                        works
qwen2.5:7b tool-calling, "it is way too loud in here" → control_volume {action:down, level:10}
```

Deliberately a **like-for-like swap** — same `llama3.2:3b` MLX was already serving — so the only
variable is the runtime. `LOCAL_LLM_URL → 127.0.0.1:11434`; `start_mlx()` now skips unless
`ORBIT_USE_MLX=1`, keeping the path trivially reversible. Result: **a permanently pinned CPU core
is gone**, one daemon instead of two, and `/ready` confirms Ollama.

Worth noting for later: `qwen2.5:7b-instruct` produced a correct tool call from indirect phrasing
that gpt-4o-mini got wrong earlier today — so the "let the local tier act offline" idea is now
demonstrably possible, at ~4.4 GB resident while loaded (16 GB machine, unloads when idle).

**Embedder no longer latches off.** The first Ollama-backed startup still reported
`embed_provider_active: false` — the 4-second probe expired while Ollama cold-loaded a model, and
`_available = False` was permanent for the process, silently degrading memory to hash similarity
for the whole session with no symptom but poor recall. Timeout raised to 20s and failures now
retry after a 60s cooldown instead of latching. Verified `true`, and `embedding_meta` shows
`nomic-embed-text / dims 768` — existing vectors were re-embedded by `migrate_embeddings_if_needed`.

A test broke and was fixed rather than silenced: `test_embed_text_is_deterministic` asserted 192
dimensions, which implicitly asserted "no real embedder configured" — true only while embeddings
were broken. Split into an explicit hash-fallback test and a provider-agnostic one. **85 passing.**

**Still open in work-list item 2:** extraction quality. 1188 turns produced 19 semantic memories
and several are noise ("I am high what do you think about that you judge me") because
`extract_candidate_memories` is regex-based and fires on any "i am"/"my ". Recall for
"what is my job" answers correctly today via personal-knowledge search, not via those vectors.
Upgrading extraction to an LLM pass is the remaining piece.

### Phase 3.6 — DONE (2026-08-02): memory extraction is now an LLM pass

Regex extraction stored transcript fragments, not knowledge: 1188 turns → 19 "memories" such as
*"I am high what do you think about that you judge me"*, with
*"I want to go for a sleep could you please turn on the sleep"* filed under **goals**. Buried in
the same turns was a genuine fact — his shift ends at 4:30 — that regex could never distil.

`app/memory_extraction.py` replaces it. Same conversation, new extractor:

```
work     | Has a 30-minute meeting with a professor at 2:00 PM to discuss a project
routines | Has an extra work shift from 4:00 PM to 7:30 PM today
+ dated events with category/emotion/when
```

Design decisions, all made against the iOS future above:
- **Runs on the brain, not Ollama** — the brain is the component that ports to iPhone unchanged.
- **Background** (`asyncio.create_task`) — extraction never touches the reply path.
- **Batched behind a cursor** (≥6 new turns, ≤30 per run) — "my shift" and "until 4:30" only
  become one fact when read together.
- **Degrades, never fails** — offline, the regex path continues as before.
- Model output is treated as **untrusted**: categories validated against a fixed set, lengths
  bounded, importance clamped, volume capped.

**Ayush's catch, implemented:** the cursor must never start at 0. A first run from turn 0 would
mine month-old conversation and file its "today" references as current. First run now sets the
cursor to the latest turn and reads nothing; only new conversation is ever distilled. Live cursor
initialised to 1176.

11 new tests (`tests/test_memory_extraction.py`) cover the validators and both cursor rules.
Suite: **96 passing**.

### Phase 3.7 — DONE (2026-08-02): new speech engine, and the accent fixed at the source

Investigated before reaching for Whisper, and the probe changed the plan:

```
SpeechTranscriber supported: en_ZA en_CA en_SG en_IN en_NZ en_GB en_AU en_US en_IE
installed on this Mac:       all of them, including en_IN
best audio format:           16000 Hz, 1 ch
```

**Apple ships a dedicated `en_IN` acoustic model and it was already installed.** ORBIT had been
running `Locale.current` — **en_CA** — a Canadian English model listening to an Indian accent.
That is the actual source of the "kachuful → a game catch full" class of mishearing that
`siteAliases` has been patching one phonetic entry at a time.

Chose macOS 26's **SpeechAnalyzer** over WhisperKit, weighed against the platform constraint:
- first-party framework, present on macOS 26 **and iOS 26** → moves to iPhone/iPad/Watch unchanged
- no 1.5 GB model to bundle, download or version; assets already on the machine
- no 60-second server timeout, so the `isFinal`-mid-sentence recycling workaround is unnecessary
- a bundled Whisper binary would have repeated the blueutil mistake — an external artefact macOS
  has to be persuaded to trust

`OrbitSpeechTranscriber.swift` wraps `SpeechAnalyzer` + `SpeechTranscriber`
(`.progressiveTranscription` for live partials), converting the 48 kHz mic feed to the analyzer's
16 kHz mono via `AVAudioConverter`. Locale preference is **en_IN → en_CA → en_GB → en_US**:
matching the speaker beats matching the region.

Integrated behind `orbitMac.useModernSpeech` (**default on**, gear → Voice) with automatic
fallback to `SFSpeechRecognizer` when the OS is older, no model is installed, or the toggle is
off. Silence-based committing and every downstream behaviour are untouched — only the recogniser
changed. `diagnostics` now reports the live engine and locale, e.g. `SpeechAnalyzer, en_IN`.

Wake word deliberately left on `SFSpeechRecognizer` for now: it is latency-critical, currently
working, and worth migrating separately once the push-to-talk path is proven in daily use.
*(Superseded by Phase 3.8.)*

### Phase 3.8 — DONE (2026-08-02): wake word on en_IN, without losing the tuning

Ayush's constraint came first: **more than a month of tuning produced the current wake accuracy,
and it must not regress.** `wakeup orbit` was the only phrase working reliably; the rest needed
two or three tries. He also asked to widen the scope ("are you there ORBIT", "are you awake
ORBIT") and make detection smarter.

**The obvious fix was a trap, and measuring caught it.** Pointing `SFSpeechRecognizer` at `en_IN`
is a two-line change — and it would have been a serious regression:

```
en_IN: created, available=true,  onDevice=FALSE   ("No Assistant asset for language en-IN")
en_CA: created, available=true,  onDevice=true
```

Wake listening would have silently become a **server** recogniser: audio streamed to Apple 24/7,
a 60-second session limit, and **dead the moment the network drops** — the exact flaw Ayush called
ORBIT's biggest. `en_IN` on-device is reachable *only* through SpeechAnalyzer.

**Structure.** The tuned decision logic was lifted out of the controller **verbatim** into
`OrbitWakePhraseMatcher.swift` — pure functions over text plus per-token confidence, no audio, no
permissions. Both engines feed the same matcher, so swapping the ears cannot disturb the brain.
`OrbitWakeSpeechEngine.swift` is the new en_IN recogniser; the legacy `SFSpeechRecognizer` path is
untouched and still there. The controller keeps all of its policy (1.6 s cooldown, suspension
handoff, power/thermal throttling, 6 s health check, generation guards, backoff).

Two capabilities the old engine could not offer:
- **Contextual biasing** — `AnalysisContext.contextualStrings` names "ORBIT" to the decoder, so a
  rare word stops losing to common neighbours.
- **Per-token confidence** via `.transcriptionConfidence`, which the tuned gates need.

The 45-second proactive recycle is *not* carried over: it existed solely to dodge Apple's server
session limit, and SpeechAnalyzer has none. One continuous session, no restart gap — and that gap
is where fast utterances used to be lost.

**Proof, not assertion.** Two harnesses now exist, because "it compiles" has already been wrong
once in this project:
1. `Tests/run-wake-corpus.sh` — 122 phrases. Before the change it was run as a *differential*
   against the old matcher: every phrase the old one accepted, the new one must accept. Result:
   **0 regressions, 29 phrases gained.**
2. An end-to-end replay harness that synthesizes Indian-English speech (`say -v Rishi/Aman/Tara`)
   and pushes it through the real engine. **8/8.**

The replay harness turned tuning from guesswork into measurement, and immediately produced three
real mishearings that hand-written aliases had missed:

| said | en_IN heard |
|---|---|
| hey orbit | "here or bit" |
| orbit are you there | "what bit are you there" |
| listen orbit | "listen now a bit" |

All three are now matched by **fully anchored** patterns — the surrounding words carry the wake
intent, so they cannot fire as a bare name and cause a false wake. The corpus caught one such
false wake during development ("listen now a bit **later**"), fixed by end-anchoring.

Gotcha worth recording: `say` output ends the instant the last phoneme does, so the analyzer never
commits the final word. Every phrase lost its last word — including "today" in the control — which
looked exactly like "orbit is never recognised". A live mic never does this; the harness pads with
silence.

Reversible by design: `orbitMac.wakeUseModernEngine` (**default on**) returns to the previous
en_CA behaviour exactly, no rebuild. Wake diagnostics in the menu bar now show which ears are in
use (`ears: SpeechAnalyzer, en_IN`), amber when it has fallen back.

### Phase 3.9 — DONE (2026-08-02): "sleep" means sleep, and a question gets an answer

Field results on Phase 3.8: *"the wake words are very, very accurate."* Two gaps left, both the
same complaint underneath — ORBIT heard the **words** but not the **situation**.

**1. "sleep" opened Safari; "go to sleep" worked.** Same intent, opposite behaviour. Not a
matching problem — an **ordering** one. `performIfCommand` runs at
`ContentView+Chat.swift:16`, *before* the stop-intent check at line 167, so the command matcher
claimed the bare word and answered "Opening sleep." `isSessionStopCommand("sleep")` would have
handled it correctly and never got the chance.

Fixed at the shared choke point rather than by reordering: `performIfCommand` now **declines**
unambiguous rest intents up front, so both call sites (menu and wake) reach the stop path. The
full stop check was deliberately *not* moved earlier — it treats "pause the music" as a session
stop, and today `performIfCommand` correctly claims that first.

`OrbitVoiceIntentHelpers.isRestIntent` is deliberately narrow: ≤5 words, fully anchored patterns,
and rejects anything naming a target. Sleep is a legitimate *object* of commands — the display, a
Focus mode, a timer, a memory about bedtime — and all of those still work.

**2. "Are you there ORBIT?" opened a silent orb.** It is a question as well as a summons;
answering only the summons is the machine-feeling Ayush keeps naming. The matcher now flags
`isPresenceQuestion`, the wake notification carries it, and the backstage speaks a short line
before opening the mic — one motion, since `startVoiceInputSession` already waits for speech to
finish (`isSpeaking` is set synchronously in `speak()`, so the mic can never open over it).

`OrbitWakeAcknowledgement` is **local text**, which needs justifying against Phase 3.4's removal
of canned replies. Those were canned *answers* — "how are you?" met with a fixed sentence, a
machine pretending to converse. This is an acknowledgement of presence, formulaic even between
people ("Yeah?", "I'm here"). It also has to be instant (the ask is that ORBIT "speaks and
immediately listens back") and to work offline. It never repeats the previous line and varies by
time of day. Anything that needs to be *about* something belongs in the brain, not here.

Plain summons ("hey ORBIT", "wake up ORBIT") stay silent — answering those would be chatter.

Corpus now **176 phrases**, covering both new behaviours: 12 questions vs 8 plain summons, and 19
rest intents vs 15 sleep *commands* that must still reach the matcher. Verified the test has teeth
by breaking both guards deliberately — it fails loudly, naming every hijacked command.

### Phase 3.10 — DONE (2026-08-02): reminders that don't guess

The failure, verbatim. Ayush said *"would you please remind me to buy tickets for SpiderMan for
Tuesday"*; the transcript carried his disfluencies, and Apple Reminders received:

```
title: "Um, would you please remind me to buy tickets for Spiderman, um, on for   today"
due:   Tuesday 12:00      ← a time he never said
```

**Three independent failures, none of them "the matcher needs more phrases".**

1. **One filler word defeated the whole parser.** `cleanAsTitle` strips ~90 request-framing
   prefixes with `hasPrefix`, anchored at position 0. The sentence began "Um, ", so *none* of them
   matched and the raw utterance became the title. Speech is full of "um" — an extractor anchored
   at character zero cannot survive a real voice. Fixed by `OrbitUtteranceCleanup.stripDisfluencies`
   before parsing, restricted to words that are never English content ("um", "uh", "er", "hmm").
   "like" and "so" are deliberately left alone — mangling "remind me to **like** the post" would
   trade one wrong title for another.
2. **The safety net was too literal.** The broker already bails to the brain when "title equals
   the whole input" — but it compares exact strings, and stripping one date word was enough for
   that test to pass while extraction had plainly failed. What matters is not whether the string
   changed but whether it still reads like a *request*. `looksLikeUnextractedRequest` now checks
   for surviving framing ("remind me", "would you", "set a reminder") and hands those to the brain.
3. **Noon was invented.** `NSDataDetector` resolves a bare "Tuesday" to Tuesday 12:00 and offers
   no way to tell an inferred hour from a spoken one. `hasExplicitClockTime` makes that
   distinction, and a day without a time now asks — *"Sure — what time on Tuesday should I remind
   you?"* — instead of guessing. The follow-up grafts the answered time onto the **known day**, so
   answering "3 PM" cannot silently mean today (`mentionsExplicitDay` lets "actually Wednesday"
   still move it).

Also made trailing-preposition cleanup **iterative**: removing a date can strand several words at
once, and a single pass left the title as "Buy tickets for Spiderman, on".

New suite: `Tests/run-reminder-corpus.sh`, anchored on the real utterance.

**Still open — the deeper issue.** This is the same pathology as Phase 3.9's "sleep": a local
regex matcher claims an utterance that the **brain would have understood correctly**. `brain.py`
already exposes a `create_reminder` tool; it never got asked, because the broker answered first.
Hand-written prefix tables cannot cover natural speech, and every gap costs a hand-tuned entry.
The structural fix is to let the brain extract `{title, due, missing_fields}` and demote the local
path to a fast lane that must **decline when unsure** rather than guess. That is the same work as
"collapse the two orchestrators" — proposed, not yet approved.

### Phase 3.11 — DONE (2026-08-02): the orchestrator split, starting with reminders

Phase 3.10 stopped ORBIT inventing times, and it started asking instead. Then the *conversation*
broke — twice, identically:

```
Ayush : …remind me to buy tickets for Spider-Man for Friday
ORBIT : Sure — what time on Friday should I remind you?
Ayush : remind me today at five PM
ORBIT : What should the today at 17:00 reminder be for?   ← the title is gone
Ayush : to buy tickets for Spider-Man for Tuesday
ORBIT : [creates "Buy tickets for Spiderman for Tuesday", due today 17:00]
```

**Root cause: NOT YET KNOWN.** A first diagnosis — that the 2-minute `pendingTTL` expired —
was **wrong and was retracted**. Ayush replied within seconds each time; he never paused. That
theory was fitted to a mechanism that happened to exist, not derived from evidence, and it cost
him a round trip. Recorded here so it is not proposed again.

What is actually established: the reply *"What should the today at 17:00 reminder be for?"* can
only come from `handleReminderCreate`'s no-title branch, so `process()` did **not** take the
`.active` pending path — the draft was already gone. Several mechanisms could each cause that
(`clearPending()` from the wake backstage, both transcript consumers processing one utterance,
or the state never being set), and the code cannot be read backwards to a single one.

So the broker now records its own decisions — utterance, pending state, outcome, and any
`clearPending()` — in `OrbitClarificationBroker.decisionTrace`, shown in a **Reminder Trace**
panel beside the wake diagnostics. One reproduction will settle it with facts.

**The split, as Ayush specified it:**

> *"locally should handle this kind of tasks, which are very simple and straightforward. But if
> this situation appears where local ORBIT is not able to understand the sentence or it is getting
> complex, then it should send the case forward to the brain, and he should then activate the
> tool."*

`handleReminderCreate` now has exactly two outcomes:

| condition | outcome |
|---|---|
| title **and** an explicitly spoken clock time | create it locally, instantly |
| anything missing, ambiguous, or still reading like a request | `.none` → the brain |

**This fix does not depend on knowing the root cause.** Whatever was losing the draft, there is
now no local draft to lose: both turns of a clarification go to the brain, which holds the
conversation itself. The trace above is still worth having — the same mechanism may affect
calendar, which still uses the pending machinery.

Every local `.ask(...)` for reminder creation is gone, and with it the `pendingTTL`. The brain
already holds the whole exchange, so a follow-up answer resolves with no timer to expire and no
draft to lose. Prompt guidance added in `main.py`: never invent a time, the title is the *task*
not the request, and a follow-up answer belongs to the reminder just asked about rather than
starting a new one.

The pending machinery itself is untouched — calendar flows still use it. Only reminder creation
stopped entering those states.

This is the first slice of "collapse the two orchestrators", done on the strongest case rather
than all at once. 96 Python tests, 176 wake phrases, reminder corpus — all passing.

### Phase 3.12 — DONE (2026-08-02): the three real causes, found by testing not reading

Ayush ran it again and got three reminders, all wrong:

```
Buy tickets for Spiderman for Tuesday   Today, 17:00
Buy tickets for Spiderman               2026-08-04, 12:00   ← he said "at five PM"
It                                      Today, 17:00        ← titled "It"
```

Two earlier diagnoses in this document were guesses and both were wrong. These three were found by
**running the code against his exact sentences**, which should have been the first move:

1. **`hasExplicitClockTime` only understood digits.** Introduced in Phase 3.10. He said *"at five
   PM"*; speech-to-text writes words, not "5". The check returned false, so a request that was
   already complete got escalated as if the time were missing — and the hour that came back was
   invented (noon). Spoken numbers are now first-class: "at five", "five pm", "nine thirty",
   "nine o'clock", "half past four". Guarded against "call the **five** star hotel".
2. **The local path claimed answers to the brain's own questions.** After Phase 3.11 the brain
   asks the clarifying question — but the *answer* still passed through the local broker first,
   and "remind me today at five PM" contains "remind me", so `isReminderCreateIntent` fired and
   built a new reminder from an answer. That is where **"It"** came from, while the brain's real
   question went unanswered. New rule, in `process()`: *never claim an answer to a question this
   broker did not ask* — if there is no local pending draft and ORBIT's last reply was a question,
   the brain asked it, so the reply belongs to the brain.
3. **No sanity check on the extracted title.** "It", "8", "Today, August 2" were all saved as
   tasks. `isTooThinToBeATask` refuses titles that are only pronouns, filler, numbers (digit *or*
   spoken) and date fragments — nothing a person would ever write on a to-do list.

Lesson recorded: this file previously contained two confident root-cause claims derived from
reading code. Both were wrong, and both cost a round trip. The failing sentence was runnable the
whole time.

### Phase 3.13 — DONE (2026-08-02): when ORBIT says goodbye, it goes

Ayush, after a task: *"go away."* ORBIT understood perfectly and replied *"okay, I'm putting this
here for now"* — then the listening orb came straight back.

**ORBIT's words and its behaviour came from two different places.** `willResume` was computed as
`pendingNeedsVoice || continuousVoiceMode || reply.hasSuffix("?")`. With continuous voice mode on,
**every** reply reopened the mic regardless of what it said. Saying goodbye and then continuing to
listen is the clearest possible way to look like a machine that did not understand its own answer.

Three fixes:

1. **A farewell now overrides continuous voice mode.** `isFarewellReply` reads ORBIT's *own*
   reply — "talk soon", "see you later", "good night", "I'm here whenever you need me", "putting
   this here for now", "let me know if something comes up" — and closes the turn, handing the mic
   back to the wake word. Questions are checked first, so "Is there anything else?" still resumes.
   Deliberately excluded: "let me know if you need anything **else**" and similar offers of
   further help, which follow completed tasks mid-conversation; ending on those would cut him off
   rather than let him go.
2. **Dismissals are understood locally.** "go away", "leave me alone", "off you go", "you're
   dismissed", "that'll be all", "shoo" now take the stop branch immediately. Guarded against
   "go away from the folder", "don't go away", "remind me to go away next month".
3. **Typographic apostrophes were breaking every contraction pattern.** `normalize` stripped `’`
   as punctuation, so "I’ll leave you to it" became "i ll leave you to it" and `i'?ll` never
   matched. ORBIT's own parting lines are written with `’`, so this was failing in production, not
   just in the test — found because the corpus used realistic text rather than ASCII.

Corpus now **203 phrases**.

### Phase 3.14 — DONE (2026-08-02): calendar gets the same treatment

Calendar was the same bug class sitting unfixed next door. `parseCalendarComponents` never got
Phase 3.10's fixes, so *"um, could you schedule a meeting with Priya on Thursday"* would have
failed exactly like the Spider-Man reminder: one filler word defeats `cleanCalendarTitle`'s
`hasPrefix` table, and `NSDataDetector` turns a bare "Thursday" into 12:00.

Applied, mirroring reminders:
- **Disfluencies stripped** before parsing.
- **`looksLikeUnextractedEventRequest`** — an event "title" still containing "schedule a",
  "could you", "add to my calendar" means extraction failed; hand it to the brain.
- **`isTooThinToBeATask`** — reused, so "It" can't become a meeting either.
- **A spoken clock time is required** to book locally. Time *ranges* count as explicit
  ("from 2 to 4", "between 3 and 5", "from ten till noon") — the range is the evidence, so
  `hasExplicitClockTime` learned them.
- **Every local `.ask` + `CalendarDraft` removed** from event creation, including the
  informational path ("I have a meeting with Priya Thursday"), which was booking noon silently.

Prompt guidance added for the brain: events need a real start time, and the title is what the
meeting *is*, never the sentence that asked for it.

**Deliberately left alone:** the `informationalNeedsAction` chips flow for genuinely ambiguous
input ("I need to call mom at 6" → calendar or reminder?). That one *presents options* rather than
guessing, which is the behaviour we want — it is not the bug class, and changing it would be a UX
change Ayush did not ask for.

### Phase 3.15 — DONE (2026-08-02): the clarification banner, and editing an event

Two problems from the same field test.

**1. The banner disappeared — a regression I introduced.** Clarifying questions have always been
shown as a **card with the question written out**, deliberately: hearing a question and seeing a
bare listening orb is ambiguous, so the text is on screen. That card was presented only inside the
local `.ask` branch. Phases 3.11 and 3.14 moved clarifications to the brain, whose replies come
back through the API path — which showed a card *only* for non-Latin text. So the question was
spoken, the orb opened, and nothing was written down.

Fixed: a brain reply ending in "?" is a clarification and now presents the same wake voice card,
with the same TTL logic, as the local path did. (Ayush: *"we thought about it, I kept it there"* —
existing behaviour with a reason behind it, restored rather than redesigned.)

**2. ORBIT could not change an event it had just created.** Asked to rename "Call with Kan" to
"Call with Kawan", it had only `create`, `list` and `delete_calendar_event`. So it improvised a
delete-then-recreate, asked to confirm, and on "yes, please" lost its own plan — replying that the
event *"is already scheduled, so there's nothing to update"* and offering to hunt for duplicates.

That is not a prompt problem. A correction is **one** operation and needed **one** tool:
`update_calendar_event` (rename / move / change duration), edited in place via
`CalendarService.updateEvent`. It preserves the existing duration when only the time moves, so
rescheduling cannot silently reset a two-hour block to the default hour. The tool description
tells the brain explicitly not to delete-and-recreate to make a change. Brain tool count 24 → 25.

### Phase 3.16 — DONE (2026-08-03): the 3 PM briefing fix package

Ayush woke ORBIT, said "Um" while thinking — and got a full recital of his morning's plans,
including "you're planning a quick breakfast now" at 3 PM. Then "okay?" got the identical
recital again. Diagnosed from turns 1349-1352 and the real code (no guessing this time);
four independent layers, all fixed:

1. **The ears committed a thinking sound.** Short transcripts got the SHORTEST endpoint
   pause, so a bare "Um" committed fastest of all; the only send-guard was non-empty.
   New `OrbitUtteranceCleanup.isFillerOnly` — filler-only utterances get a 6 s window
   instead, and if nothing follows they never leave the Mac (both wake and panel paths,
   guarded at the one shared controller). 16 new corpus cases.
2. **"Approach B" rewrote his message.** `build_messages` prepended every non-PAST life
   event INTO the user message — "Um" became a context recital request. Deleted. Events
   live in the system prompt with ages and hard usage rules ("context, not content").
   Volunteering is now structural: nudges are offered to the model only when the message
   is a conversational opener (`_is_conversational_opener`), never on substantive turns.
3. **No intra-day staleness — and the #3 temporal bug, same function.** `_temporal_label`
   rewritten: every spoken date word resolves against the day it was SAID ("next-week"
   shared yesterday is no longer PAST), morning "today" plans flip to "EARLIER TODAY —
   LIKELY DONE" after 3 h, ages rendered human ("shared 5 hours ago"). Also fixed a silent
   3-hour skew: DB timestamps are UTC (SQLite CURRENT_TIMESTAMP) but were compared against
   local time.
4. **Nothing prevented repeating.** Structural near-duplicate guard (difflib ≥ 0.85 vs the
   last 3 assistant turns, short replies exempt) with ONE regeneration; and a repeated
   time-of-day greeting is stripped ("Afternoon, Ayush." at most once per stretch).

**Verified:** 115/115 pytest (19 new: temporal matrix, opener/dup/greeting), reminder +
wake corpora green, clean xcodebuild — and the two failing inputs replayed live against
the fixed backend:

```
"Um"                        →  "Yep? Take your time—no rush. What's up?"
"I am going for a bath now" →  "Sounds good. Enjoy your bath—I'll be here when you get back."
```

Backend restarted; **Xcode rebuild (Cmd+R) required** for the ears fix. Protocol unchanged.

### Next phases (in order)
2. **STT replacement research** — Apple STT is the root of the mishear pain; evaluate WhisperKit /
   whisper.cpp (large-v3-turbo) on Apple Silicon for Indian-accent accuracy. This kills the alias
   whack-a-mole at the source.
3. **Companion voice pass** — the reply post-processors in `main.py` (`shorten_reply_when_overlong`,
   `normalize_casual_checkin_reply`) machine-chop personality out of replies; revisit them + evaluate a
   better local conversational model (e.g. Qwen 7B via MLX) for the non-brain path.
4. **Memory upgrade** — replace regex `extract_personal_knowledge` with LLM extraction (background brain
   call); verify real embeddings are active (Ollama embedder vs hash fallback).
5. **Voice pipeline Phase 2 completion** — `ContentView+Chat.swift` still runs on
   `shouldResumeVoiceLoop`/`suppressAutoVoiceResume` booleans while `OrbitWakeVoiceBackstage` is fully on
   the state machine; collapse the panel path onto the backstage to end the two-orchestrator drift.

---

## Previous Session (2026-07-31)

Three bugs were fixed — all changes are in source, **Xcode rebuild is required**:

**1. Voice cutoff on long sentences** (`OrbitSpeechInputController.swift`)
- Root cause: Apple's `SFSpeechRecognizer` fires `isFinal = true` mid-sentence, not only at end of speech. Previous code called `stopListening()` on that, cutting the user off.
- Fix: Added `recycleRecognitionTask()` — keeps the audio engine alive, restarts only the recognition task, and prepends the accumulated transcript so nothing is lost.
- Also fixed: `endpointPauseSeconds` was backwards (reduced pause on long transcripts). Now correctly increases pause for 10+ word sentences.

**2. "Open kachuful in Chrome" not working** (`OrbitMacControlCenter+Browser.swift`)
- Root cause: Apple STT mishears "kachuful" as "a game catch full". That phrase was not in `siteAliases`.
- Fix: Added 5 new phonetic aliases: `"a game catch full"`, `"game catch full"`, `"our game catch full"`, `"a game catch"`, `"catch full"` → all map to `https://kachuful-70077.web.app/`.

**3. "Have a good night!" appended to error messages + orb staying visible** (`OrbitMacControlCenter.swift`)
- Root cause: `inferAppendWakeConversationPrompt()` returned `true` for "App not found" messages. At night this appended the time-based farewell and kept the listening orb visible.
- Fix: Added error-message detection — any reply containing "not found", "couldn't", "failed", "error", "sorry, i", "i can't" now returns `false`, ending the voice session cleanly.

---

## What's Left — Pending Work

(Reordered 2026-08-01 — see "Current Direction" above for the active roadmap. Statuses corrected after full audit.)

### Voice Pipeline Phase 2 — HALF DONE (doc was stale)

`isSendingChat` is deleted. `OrbitWakeVoiceBackstage.swift` (wake path) is **fully driven** by
`OrbitVoiceSession` — 40+ transition() calls, no booleans. But `ContentView+Chat.swift` (panel path)
still runs on `shouldResumeVoiceLoop` / `suppressAutoVoiceResume` / its own `voiceLoopFallbackTask`.
Two parallel orchestrators for the same nine broker branches = ongoing drift (e.g. panel comm-draft
confirmations don't schedule the voice-loop fallback; the backstage does). Remaining work: collapse
the panel path onto the backstage or wire it to the same state machine, then delete the booleans.

### ~~Broken Python Tests~~ — FIXED

`pytest`: 62/62 passing (verified 2026-08-01).

### Guardrails & Privacy Settings — PARTIALLY BUILT

Five toggles exist in the gear menu (screen reading, conversation memory, contacts, email, clipboard).
2026-08-01: fixed absent-key-reads-as-OFF bug, guarded the classifier email bypass, wired the dead
clipboard toggle. Still missing: per-capability controls for smart home, terminal, files, and a gate
on the new brain tools (currently the brain can use any tool whenever the backing handler is allowed).

### ~~Brain Tool-Calling on Streaming Path~~ — RESOLVED (typed path)

Typed local/tooling messages now use the non-streaming brain path so tool calls dispatch. Only cloud
routes stream. `/chat/stream` itself still has no `tools` param — fine while nothing tool-bearing
routes there; revisit if streaming+tools is ever wanted (needs SSE tool-call protocol).

### ~~More Brain Tools~~ — DONE (Phase 1, 2026-08-01)

23 tools total. See "Current Direction" above. Deliberately excluded for now: terminal execution,
message/call sending, delete folder, empty trash — these keep their confirmation ceremonies on the
phrase-match path only.

---

## Full Capabilities — What ORBIT Can Actually Do

Verified by reading the source files directly.

### Voice & Wake
- Wake word detection: "Hey ORBIT", "Wake up ORBIT", "Hi ORBIT" — always listening via `OrbitWakeWordController`
- Push-to-talk mic button in UI
- Auto-speak mode: reads each reply aloud automatically
- Continuous voice mode: automatically re-opens mic after each reply for hands-free back-and-forth
- "Repeat that" / "say that again" / "what did you say" — replays last spoken reply
- Silence-based commit: adjusts how long it waits based on transcript length and last word (connectors like "and", "but" get more time)

### System Controls
- Volume: mute, unmute, volume up/down, set volume to N%
- Battery: status, percentage, charging state
- Wi-Fi: on/off/status
- Bluetooth: on/off/status (requires `blueutil` via Homebrew)
- Screen brightness: up/down/set to N% (requires `brew install brightness`)
- Night Shift: on/off (requires `brew install smudge/smudge/nightlight`)
- Focus/Do Not Disturb: on/off
- Lock screen
- Dark mode: on/off
- System Settings deep links: opens specific panes (Wi-Fi, Bluetooth, Battery, Displays, Notifications, Privacy, Accessibility, etc.)

### Files & Finder
- Open folders: Downloads, Documents, Desktop, Trash, Finder
- Find files by name: multi-word, fuzzy Spotlight search, numbered pick list for multiple results
- Create project folders: with or without subfolders, custom structure, on Desktop or in Documents
- Delete folder: requires voice confirmation ("yes delete it") — moves to Trash, not permanent delete
- Empty Trash: requires voice confirmation ("yes empty trash")
- Open Terminal in a specific folder: "open terminal in Documents", "open terminal in Downloads"

### Browser
- Open site in any browser: "open YouTube in Chrome/Safari/Arc/Firefox"
- Site aliases: 20+ common sites (YouTube, GitHub, Netflix, Gmail, Instagram, etc.) + phonetic mishear variants (kachuful, etc.)
- Search in browser: "search for X in Chrome", "google for X"
- Multi-step: "open Chrome and search for X"

### Calendar & Reminders
- Create calendar events: single/recurring, smart duration (standup=15m, 1:1=30m, etc.), time ranges
- List upcoming events (14-day window)
- Delete calendar events (brain confirms before deleting)
- Create reminders with/without due time
- List upcoming reminders
- Complete reminders by name
- Delete reminders (brain confirms before deleting)
- Proactive pre-alerts: T-30/T-10 before reminder due, T-15/T-5 before calendar event
- Overdue follow-up: asks "did you do X?" with smart cooldown windows
- Morning briefing: calendar + reminders summary at 9AM

### Apple Notes
- Create new note: "take a note" → clarification → content
- Append to recent note: "add X to that note" (2-minute recency window)
- Multi-turn aware: won't echo wake phrase as note content

### Music
- Apple Music and Spotify (auto-detects which is running)
- Play, pause, next, previous, now playing — via AppleScript

### Contacts & Communication
- FaceTime video call: "call Priya on FaceTime", "video call mom" — opens FaceTime, user taps Call
- FaceTime audio call: "audio call dad", "call John" — opens FaceTime audio
- iMessage: "message Priya: I'm on my way" → proposes draft → confirms → sends via Messages AppleScript
- Fuzzy contact lookup via CNContactStore

### Screen & Document Intelligence
- Screen reading: captures primary display via ScreenCaptureKit + Vision OCR, answers "what's this?"
- PDF/document summarization: finds by name or most-recent, reads PDF/DOCX/TXT/RTF/MD, summarizes via LLM
- Email reading: reads 5 most recent from Outlook (Microsoft 365 Graph) or Apple Mail (AppleScript fallback)

### Clipboard Intelligence
- Summarize clipboard
- Rewrite / polish clipboard
- Make professional / casual tone
- Bullet points from clipboard
- Action items / next steps from clipboard
- Draft reply to clipboard
- Translate clipboard (40+ languages, auto-detects target)
- All run on local LLM (not cloud) to keep content private

### Smart Home
- Runs any macOS Shortcut by name: "turn on bedroom lights", "turn off hall lights"
- Fuzzy room + action matching
- Requires: user created Shortcuts on iPhone, they synced to Mac via iCloud

### Terminal
- Run shell commands: "run git status", "execute npm install"
- STT correction for common mishears (gate→git, geet→git)
- Dangerous command blocklist
- Confirmation required before execution
- Runs from `~/`

### ORBIT's Mind (Dashboard)
- Personal knowledge tab: structured profile of what ORBIT knows about Ayush (work, relationships, goals, etc.)
- Life events: recent things shared with ORBIT (plans, feelings, updates)
- Mood trend: 24h emotional signals
- Daily summaries: compressed conversation summaries by day

### Backend Memory (Python)
- SQLite-based conversation turns (recent 8 shown to LLM per request)
- Semantic memory: vector similarity search, auto-extracted from conversations
- Personal knowledge extraction: learned from explicit statements ("I work at...", "my mom...")
- Life event extraction: learned from sharing plans, feelings, updates
- Mood tracking: emotion detection per message
- Daily/weekly summary compression
- Facts API: manually curated facts always injected into system prompt
- Adaptive style: tracks if user prefers concise/detailed/no-followups and adjusts behavior

### LLM Routing
- Voice commands: local 3B model (Llama 3.2 via MLX-LM, port 8080) for instant response
- Contextual/tool tasks: brain LLM (gpt-4o-mini via OpenAI key) with tool-calling
- Long/complex queries: cloud route (gpt-4o-mini or configurable)
- Typed streaming: brain path (streams tokens)

### Microsoft 365 (optional, read-only)
- Sign in with device-code OAuth (public client)
- Read latest emails (subject, sender, preview)
- Read latest Teams chats
- Nothing is sent — read only

---

## What ORBIT Cannot Do (Verified Gaps)

- **Close/quit apps** — disabled, was unstable. Not in working code.
- **Window management** — minimize, maximize, move windows — disabled, not implemented.
- **Send email** — can draft text, cannot send through any email client.
- **Read/reply to Slack or Teams** — drafts text only, cannot read channels or send.
- **Create Shortcuts** — can only run existing ones.
- **Detect available Shortcuts** — no discovery; must guess the name.
- **Location-based automations** — no location detection built.
- **Screen recording** — ScreenCaptureKit captures a single frame for context, not ongoing recording.
- **Cross-app workflows** — e.g., "copy from Safari to Notes" — not built.
- **iOS/iPad/Watch** — Phase 2, not started.
- **Password / Keychain access** — not built.
- **Camera access** — not built.
- **Voice-change keyboard focus** — the UI assist (typing into a focused field) works for injecting text, not focus navigation.

---

## Weaknesses, Loopholes & Known Problems

### Voice Recognition
- **Phrase-dependent intent detection**: Every command requires the user to say something close to a predefined phrase. If phrasing doesn't match any pattern, the request falls to the LLM which responds conversationally but cannot execute system commands. Example: "increase the volume a little" works, but an unusual phrasing may not.
- **Indian accent STT mishears**: Apple STT regularly mishears certain words ("kachuful" → "a game catch full", "YouTube" → "you tube"). Mitigated via `siteAliases` and `contextualStrings` phonetic hints but coverage is incomplete. Any new site/app not in the aliases dict will fail.
- **Wake word false positives**: "Hey ORBIT" can trigger from ambient sound or TV audio. There is a 1.6s cooldown but no noise suppression.
- **Long sentence cutoff**: Fixed this session with `recycleRecognitionTask()`, but this is fragile — Apple's STT framework sends `isFinal` unpredictably. The fix has not been stress-tested.
- **Indian English speech patterns**: ORBIT's silence detection pauses were tuned for shorter utterances. Very long sentences with mid-sentence natural pauses can still commit early.

### Architecture
- **State machine not driving behavior**: `OrbitVoiceSession.swift` tracks state but three boolean flags still drive actual behavior. Until Phase 2 is complete, there are two parallel systems that can drift out of sync.
- **Streaming path drops tool calls**: If the brain LLM wants to call a tool during a typed (streaming) request, that tool call is silently dropped. Tool-calling only works on the non-streaming `/chat` endpoint (voice path).
- **Personal knowledge learning is regex-only**: `extract_personal_knowledge()` in Python uses regex patterns, not an LLM. It only fires for very explicit statements ("I work at...", "my mom..."). Casual conversation, implied preferences, and behavioral patterns are not learned.
- **Weather hardcoded to Halifax, NS**: `OrbitWeatherService.swift` has GPS coordinates for Halifax hardcoded. Will give wrong weather if location changes.
- **No capability controls**: There is no settings panel to disable individual features. ORBIT can attempt to access contacts, screen, files, etc. with no way to restrict scope per-category without changing code.
- **External tool dependencies**: Bluetooth needs `blueutil`, screen brightness needs `brightness`, Night Shift needs `nightlight` — all must be installed via Homebrew. App will report honest error if tools are missing, but the feature simply won't work.

### Memory
- **ORBIT's Mind was blank**: Fixed this session (wrong port 21221→8787 in the Swift API calls). Has been silently failing for an unknown number of sessions.
- **Semantic memory fallback**: If the Ollama embedder is not running, semantic memory falls back to hash-based similarity, which is very low quality. Most memory recall will be poor in this mode.
- **Python test stale fixtures**: 2 failing tests in `test_device_time.py` because mocks are missing. Tests pass partially but not fully.

### Reliability
- **App not found + farewell bug**: Fixed this session. Before the fix, error messages could get a time-based greeting appended, creating confusing messages like "App not found. Have a good night!" The orb also stayed visible after errors.
- **Focus mode unreliable**: `Focus/DND on/off` works on some macOS versions but is blocked on others. ORBIT reports failure honestly when it can't verify.
- **Messages AppleScript dependency**: iMessage sending requires Messages.app to be running and accessible. Will fail if Messages is closed or permission was denied.
- **Calendar permission re-prompt**: Each Xcode debug run uses a different binary if rebuilt, which can re-trigger permission dialogs for calendar/mic/contacts.

---

## Advantages & Strengths

- **Fully local by default**: All voice commands, STT, and most responses run on-device. No data sent to cloud unless query is long or explicitly routed there.
- **No internet required for most features**: System controls, reminders, calendar, files, music, screen reading — all work offline.
- **Hands-free from anywhere on Mac**: Wake word works system-wide, menu bar window doesn't need to be open.
- **Continuous voice mode**: Hands-free back-and-forth conversation without pressing anything.
- **Multi-turn context**: Brain path has full conversation history and personal knowledge in every request.
- **Memory across sessions**: SQLite persists across restarts. ORBIT remembers recent conversations, learned facts, mood, life events.
- **Privacy-first architecture**: Local LLM for sensitive data, PII redaction before any cloud call, all memory stored on-device in SQLite.
- **Personal knowledge profile**: Over time, ORBIT builds a structured understanding of who Ayush is and uses it to give better, more personal responses.
- **Mood awareness**: Tracks emotional signals from conversations and quietly adjusts tone accordingly.
- **Confirmation gates**: Destructive actions (delete, empty trash, send message, run terminal command) require explicit voice confirmation.
- **Honest error messages**: When something fails, ORBIT says it failed and why, rather than claiming success.
- **Multi-step commands**: "Open Chrome and search for X", "mute and turn on focus" — splits on "and"/"then".
- **Brain tool-calling**: The LLM can actually execute calendar, reminder, and note actions with proper tool dispatch — not just describe what to do.

---

## File Reference

| File | What it is |
|---|---|
| `OrbitWakeWordController.swift` | Always-on "Hey ORBIT" detection |
| `OrbitSpeechInputController.swift` | Push-to-talk / voice session STT |
| `OrbitSpeechController.swift` | TTS output (AVSpeechSynthesizer) |
| `OrbitWakeVoiceBackstage.swift` | Full wake→listen→reply pipeline |
| `OrbitVoiceSession.swift` | State machine (shadow tracker, Phase 2 incomplete) |
| `OrbitVoiceIntentHelpers.swift` | Intent detection helpers (isRepeatIntent, etc.) |
| `OrbitMacControlCenter.swift` | Main command dispatch + pending store |
| `OrbitMacControlCenter+Audio.swift` | Volume / mute |
| `OrbitMacControlCenter+Browser.swift` | Browser control + site aliases |
| `OrbitMacControlCenter+Contacts.swift` | FaceTime / iMessage |
| `OrbitMacControlCenter+Display.swift` | Brightness / Night Shift |
| `OrbitMacControlCenter+Documents.swift` | PDF/document summarization |
| `OrbitMacControlCenter+Files.swift` | Finder, file find, create/delete folder |
| `OrbitMacControlCenter+Music.swift` | Apple Music / Spotify |
| `OrbitMacControlCenter+Network.swift` | Wi-Fi / Bluetooth |
| `OrbitMacControlCenter+Notes.swift` | Apple Notes |
| `OrbitMacControlCenter+Queries.swift` | Weather, battery, generic queries |
| `OrbitMacControlCenter+SmartHome.swift` | HomeKit via Shortcuts |
| `OrbitMacControlCenter+System.swift` | Battery, Focus, app launch |
| `OrbitMacControlCenter+Terminal.swift` | Terminal command execution |
| `OrbitMacControlCenter+Utilities.swift` | Multi-step chaining, shared helpers |
| `OrbitMacControlCenter+AppAutomation.swift` | App-specific automation (Terminal folder) |
| `OrbitScreenReader.swift` | ScreenCaptureKit + Vision OCR |
| `OrbitProactiveNotifier.swift` | Pre-alerts, overdue follow-up, morning briefing |
| `OrbitToolDispatcher.swift` | Brain tool-call dispatch (calendar, reminders, notes) |
| `OrbitClarificationBroker.swift` | Multi-turn clarification (reminder/calendar/comm-draft) |
| `OrbitClipboardIntelligence.swift` | Clipboard operations |
| `OrbitCommunicationDrafting.swift` | Email/Slack/Teams draft |
| `CalendarService.swift` | EventKit calendar CRUD |
| `OrbitReminderService.swift` | EventKit reminders CRUD |
| `OrbitWeatherService.swift` | Open-Meteo weather (hardcoded Halifax) |
| `ContentView+OrbitMind.swift` | ORBIT's Mind dashboard UI |
| `OrbitAPI.swift` | HTTP client to Python backend (port 8787) |
| `orbit-core/app/main.py` | FastAPI backend — all endpoints |
| `orbit-core/app/memory.py` | SQLite memory store |
| `orbit-core/app/semantic_memory.py` | Embedding + life event + mood extraction |
| `orbit-core/app/providers/brain.py` | OpenAI tool-calling LLM bridge |
| `orbit-core/app/router.py` | Route classification (local/cloud/tooling/brain) |

---

## Setup Reminder

The `orbit-core/README.md` has full server setup instructions. Short version:

```bash
cd orbit-core && source .venv/bin/activate
scripts/orbit-services.sh start    # backend + MLX model
scripts/orbit-services.sh status   # check ports
scripts/orbit-services.sh stop     # shut down
```

Backend: `http://127.0.0.1:8787`
MLX model: `http://127.0.0.1:8080`

For Bluetooth, brightness, Night Shift:
```bash
brew install blueutil
brew install brightness
brew install smudge/smudge/nightlight
```
