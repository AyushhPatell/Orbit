//
//  OrbitFailureTelemetry.swift
//  ORBITMac
//
//  Opt-in logging of commands that local intent detection missed (fell through to LLM).
//  Stored locally — never sent anywhere. Helps identify common phrasings that need
//  new triggers so ORBIT gets smarter over time.
//
//  View the log in the ORBIT panel's Debug section, or via:
//    defaults read com.orbit.mac orbitMac.missedIntents
//

import Foundation

@MainActor
final class OrbitFailureTelemetry {
    static let shared = OrbitFailureTelemetry()
    private init() {}

    private let defaults = UserDefaults.standard
    private let storageKey = "orbitMac.missedIntents"
    private let maxEntries = 200

    struct MissedIntent: Codable {
        let text: String
        let timestamp: Date
        let route: String
    }

    func logMissedIntent(_ text: String, route: String = "llm-fallback") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return }
        // Skip very short utterances (noise, single-word answers, wake phrases)
        guard trimmed.count >= 8 else { return }
        let lower = trimmed.lowercased()
        let skipPhrases: Set<String> = [
            "hey", "hello", "hi", "hey orbit", "orbit", "thank you",
            "thanks", "bye", "goodbye", "good night", "good morning",
            "wake up", "wake up orbit", "yes", "no", "yeah", "nope",
            "nothing", "okay", "ok", "sure", "cool", "great",
            "got it", "sounds good", "perfect", "awesome", "nice",
        ]
        if skipPhrases.contains(lower) { return }
        // Skip conversational responses that correctly go to the LLM
        // (sharing life events, answering questions, casual chat)
        let conversationalStarts = [
            "no i", "yes i", "yeah i", "nope i", "no but", "yes but",
            "it really", "it went", "it was", "that was", "that is",
            "i told", "i said", "i think", "i guess", "i just",
            "so i", "and i", "but i", "well i",
            "today i", "yesterday i", "tomorrow i",
            "do you remember", "you remember",
            // Greetings and check-ins now go to the brain on purpose — reaching the LLM is the
            // intended path for them, not a missed intent worth logging.
            "how are you", "how're you", "how you doing", "how is it going",
            "how's it going", "hows it going", "how do you do", "how was your",
            "are you okay", "are you there", "you good", "you okay",
            "what's up", "whats up", "good morning", "good evening",
            "good afternoon", "good night",
        ]
        if conversationalStarts.contains(where: { lower.hasPrefix($0) }) { return }

        var entries = loadEntries()
        entries.insert(MissedIntent(text: trimmed, timestamp: Date(), route: route), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        saveEntries(entries)
    }

    func recentMisses(limit: Int = 20) -> [MissedIntent] {
        Array(loadEntries().prefix(limit))
    }

    // MARK: - Voice pipeline state machine (Phase 0/1 shadow)

    private let illegalTransitionKey = "orbitMac.illegalVoiceTransitions"
    private let maxTransitionEntries = 100

    struct IllegalTransition: Codable {
        let from: String
        let to: String
        let timestamp: Date
    }

    /// Records an attempted illegal VoicePipelineState edge. During Phase 0/1 the shadow
    /// state machine runs alongside the real boolean flags; a non-empty log here means a
    /// path mutated a flag in an order the state machine considers impossible — i.e. a race
    /// or a transition we haven't modeled yet.
    func logIllegalVoiceTransition(from: String, to: String) {
        print("[ORBIT-VOICE-FSM] illegal transition \(from) -> \(to)")
        var entries = loadTransitions()
        entries.insert(IllegalTransition(from: from, to: to, timestamp: Date()), at: 0)
        if entries.count > maxTransitionEntries { entries = Array(entries.prefix(maxTransitionEntries)) }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: illegalTransitionKey)
        }
    }

    func recentIllegalVoiceTransitions(limit: Int = 30) -> [IllegalTransition] {
        Array(loadTransitions().prefix(limit))
    }

    private func loadTransitions() -> [IllegalTransition] {
        guard let data = defaults.data(forKey: illegalTransitionKey),
              let entries = try? JSONDecoder().decode([IllegalTransition].self, from: data)
        else { return [] }
        return entries
    }

    func topMissedPhrases(limit: Int = 10) -> [(phrase: String, count: Int)] {
        let entries = loadEntries()
        var freq: [String: Int] = [:]
        for e in entries {
            let key = e.text.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            freq[key, default: 0] += 1
        }
        return freq.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (phrase: $0.key, count: $0.value) }
    }

    func formattedSummary() -> String {
        let entries = loadEntries()
        guard !entries.isEmpty else { return "No missed intents logged yet." }

        let recent = entries.prefix(10)
        let top = topMissedPhrases(limit: 10)
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .none

        var lines: [String] = []
        lines.append("Missed intents: \(entries.count) total")
        lines.append("")
        lines.append("Recent:")
        for e in recent {
            lines.append("  \(tf.string(from: e.timestamp)) \u{2014} \u{201C}\(e.text)\u{201D}")
        }
        if !top.isEmpty {
            lines.append("")
            lines.append("Most frequent:")
            for t in top {
                lines.append("  \(t.count)x \u{2014} \u{201C}\(t.phrase)\u{201D}")
            }
        }
        return lines.joined(separator: "\n")
    }

    func clearLog() {
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Persistence

    private func loadEntries() -> [MissedIntent] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([MissedIntent].self, from: data)
        else { return [] }
        return entries
    }

    private func saveEntries(_ entries: [MissedIntent]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
