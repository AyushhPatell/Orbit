//
//  OrbitBargeIn.swift
//  ORBITMac
//
//  Deciding whether the microphone just heard Ayush — or ORBIT's own voice coming back.
//
//  Barge-in means listening WHILE speaking, which means the mic hears the speaker.
//
//  **Hardware echo cancellation is not available here, and that is settled.** The first
//  attempt (Phase 3.27) enabled macOS voice processing on the capture engine and broke audio
//  input completely — see `ensureVoiceProcessingDisabled` for the console evidence. VPIO is a
//  duplex unit that cancels against the audio the *same engine plays*; this engine only
//  captures, and TTS goes out through AVSpeechSynthesizer on a separate path, so there was
//  never a reference signal for it to use. Input-only engines cannot use VPIO.
//
//  So echo rejection is **entirely content-based**: whatever the mic returns is compared
//  against what ORBIT is currently saying, and a match is discarded. That is weaker than
//  hardware cancellation and it is the honest ceiling of this approach — which is why the
//  whole feature stays behind a default-off toggle until it proves itself in real use.
//
//  Pure functions, so the corpus can prove the rules without an audio device.
//

import Foundation

enum OrbitBargeIn {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "orbitMac.allowBargeIn")
    }

    // MARK: - Loop breaker
    //
    // A false interrupt is survivable; a false interrupt that CASCADES is not. In the field
    // trace ORBIT cut itself off, the open mic captured its own continuing speech as a
    // message, the brain answered, ORBIT spoke again, and it interrupted itself again —
    // three times in seventeen seconds. Narrowing the trigger makes that unlikely; this makes
    // it impossible. Whatever else changes, barge-in can never fire twice in quick succession.

    private static var lastInterruptAt: Date?
    private static let cooldownSeconds: TimeInterval = 12

    static var isInCooldown: Bool {
        guard let last = lastInterruptAt else { return false }
        return Date().timeIntervalSince(last) < cooldownSeconds
    }

    static func noteInterrupt() {
        lastInterruptAt = Date()
    }

    /// Test seam — the cooldown is process state, so it has to be resettable.
    static func resetCooldown() {
        lastInterruptAt = nil
    }

    // MARK: - Diagnostics
    //
    // The first field test failed completely — saying "stop" over and over did nothing — and
    // there were two equally plausible causes: the mic never opened, or it opened and heard
    // only ORBIT. Reading the code cannot separate those. This records what actually
    // happened so the next test produces facts instead of another theory.

    private static let logKey = "orbitMac.bargeInLog"

    static func log(_ line: String) {
        var entries = UserDefaults.standard.stringArray(forKey: logKey) ?? []
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(8)
        entries.append("\(stamp) \(line)")
        if entries.count > 40 { entries.removeFirst(entries.count - 40) }
        UserDefaults.standard.set(entries, forKey: logKey)
        print("[ORBIT-BARGEIN] \(line)")
    }

    static func report() -> String {
        let entries = UserDefaults.standard.stringArray(forKey: logKey) ?? []
        guard !entries.isEmpty else {
            return "Barge-in: nothing recorded yet. Turn the toggle on, say something while "
                 + "I'm talking, then ask for barge-in diagnostics."
        }
        return "Barge-in log (newest last):\n" + entries.suffix(20).joined(separator: "\n")
    }

    static func clearLog() {
        UserDefaults.standard.removeObject(forKey: logKey)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when the transcript is ORBIT hearing itself.
    ///
    /// Compared against the tail of what is being spoken as well as the whole, because the
    /// mic picks up whichever part is playing when it opens — not the sentence from the start.
    static func isEcho(transcript: String, spokenText: String) -> Bool {
        let heard = normalized(transcript)
        let said = normalized(spokenText)
        guard !heard.isEmpty, !said.isEmpty else { return false }
        if said.contains(heard) { return true }
        // A few words of overlap in sequence is enough — the mic rarely catches a clean span.
        let heardWords = heard.split(separator: " ").map(String.init)
        let saidWords = said.split(separator: " ").map(String.init)
        if heardWords.count >= 2, saidWords.count >= heardWords.count {
            for start in 0...(saidWords.count - heardWords.count) {
                let window = Array(saidWords[start..<(start + heardWords.count)])
                if window == heardWords { return true }
            }
        }
        // Single distinctive word that ORBIT is currently saying: treat as leakage rather
        // than risk cutting itself off. A one-word genuine interruption is handled below.
        if heardWords.count == 1, saidWords.contains(heardWords[0]),
           !stopWords.contains(heardWords[0]) {
            return true
        }
        return false
    }

    /// Short, unambiguous interruptions that must ALWAYS cut ORBIT off, even if the same word
    /// appears in what it is saying. "Stop" is the one thing that can never be ignored.
    /// Words that essentially never appear inside a normal ORBIT reply.
    ///
    /// "quiet", "enough", "cancel" and "pause" were here and had to come out: the field trace
    /// caught **"The quiet"** and **"Sometimes the quiet"** cutting ORBIT off, because it was
    /// mid-sentence saying "…the quiet moments…". A stop word that ORBIT uses conversationally
    /// is not a stop word. "be quiet" survives — the two-word form is an instruction, the bare
    /// adjective is not.
    static let stopWords: Set<String> = [
        "stop", "wait", "shut up", "shush", "hush", "hold on", "hang on",
        "be quiet", "stop it", "stop talking", "never mind", "nevermind",
    ]

    static func isStopCommand(_ transcript: String) -> Bool {
        let t = normalized(transcript)
        guard !t.isEmpty else { return false }
        if stopWords.contains(t) { return true }
        // At most two words. "Sometimes the quiet" is three and was interrupting ORBIT
        // mid-reply; a real interruption is one or two words shouted over the top.
        let words = t.split(separator: " ").map(String.init)
        guard words.count <= 2 else { return false }
        return words.contains { stopWords.contains($0) }
    }

    /// Should this transcript interrupt ORBIT mid-sentence?
    ///
    /// **Only an explicit stop word. Nothing else.** This was once "any two words that
    /// aren't echo", and the field trace shows precisely why that could never work:
    ///
    ///     ignored   "Just thinking this is a good time to unwind…"   ← echo caught
    ///     INTERRUPT ← heard "Sometimes the quiet"                    ← ORBIT's NEXT sentence
    ///     armed …
    ///     INTERRUPT ← heard "The nud"
    ///     INTERRUPT ← heard "The quiet"
    ///
    /// Every one of those is ORBIT interrupting itself. The echo filter caught the long
    /// matching phrases, but the *opening words of each new sentence* arrived before
    /// `lastSpokenText` had caught up — and content matching can never win that race, because
    /// the microphone is always slightly ahead of what the app thinks it is saying. Each
    /// false interrupt then opened the mic, ORBIT's continuing speech was captured as a
    /// message, the brain answered again, and it looped.
    ///
    /// With hardware echo cancellation ruled out (Phase 3.29 — VPIO cannot run on an
    /// input-only engine), a stop word is the only signal narrow enough to be safe. Checked
    /// against that entire trace: **zero** of the false triggers were stop words, and every
    /// real interruption Ayush made was one.
    ///
    /// The cost is honest and worth stating: he can stop ORBIT, but he cannot yet talk over
    /// it with an arbitrary sentence. That needs a reference signal this architecture does
    /// not have.
    static func shouldInterrupt(transcript: String, spokenText: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard isStopCommand(trimmed) else { return false }
        // Even a stop word is ignored if ORBIT is the one saying it.
        return !isEcho(transcript: trimmed, spokenText: spokenText)
    }
}
