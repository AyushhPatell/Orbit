//
//  OrbitBargeIn.swift
//  ORBITMac
//
//  Deciding whether the microphone just heard Ayush — or ORBIT's own voice coming back.
//
//  Barge-in means listening WHILE speaking, which means the mic hears the speaker. macOS
//  echo cancellation (`setVoiceProcessingEnabled`) removes most of that, but "most" is not a
//  guarantee: leakage varies with volume, room, and whether he's on speakers or headphones.
//  If ORBIT interrupts itself mid-sentence the feature is worse than not having it.
//
//  So AEC is the first line and **content** is the second: whatever the mic returns is
//  compared against what ORBIT is currently saying, and a match is discarded. Hardware
//  cancellation can fail quietly; this cannot — the words either match or they don't.
//
//  Pure functions, so the corpus can prove the rules without an audio device.
//

import Foundation

enum OrbitBargeIn {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "orbitMac.allowBargeIn")
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
    static let stopWords: Set<String> = [
        "stop", "wait", "hold on", "hang on", "shut up", "quiet", "enough",
        "no no", "pause", "cancel", "shush", "hush", "nevermind", "never mind",
    ]

    static func isStopCommand(_ transcript: String) -> Bool {
        let t = normalized(transcript)
        guard !t.isEmpty else { return false }
        if stopWords.contains(t) { return true }
        // "stop stop", "okay stop", "no wait" — a stop word inside a very short utterance.
        let words = t.split(separator: " ").map(String.init)
        guard words.count <= 3 else { return false }
        return words.contains { stopWords.contains($0) }
    }

    /// Should this transcript interrupt ORBIT mid-sentence?
    ///
    /// Deliberately conservative. A false interruption chops ORBIT off for a cough or a
    /// stray word from the room, which is far more irritating than having to wait — so
    /// filler is ignored, echo is ignored, and a single vague word is not enough.
    static func shouldInterrupt(transcript: String, spokenText: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // "Stop" always wins, before any echo check.
        if isStopCommand(trimmed) { return true }

        // Thinking sounds are not an interruption — the same rule as committing.
        if OrbitUtteranceCleanup.isFillerOnly(trimmed) { return false }
        if isEcho(transcript: trimmed, spokenText: spokenText) { return false }

        // Two real words or more: he is saying something, not clearing his throat.
        let words = normalized(trimmed).split(separator: " ")
        return words.count >= 2
    }
}
