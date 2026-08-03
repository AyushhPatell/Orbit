//
//  OrbitWakePhraseMatcher.swift
//  ORBITMac
//
//  The wake-phrase decision, extracted from OrbitWakeWordController so it is engine-agnostic.
//
//  This is the most heavily tuned code in ORBIT — more than a month of real-world listening went
//  into these patterns, thresholds and accent spellings. It was lifted out **verbatim** so that
//  swapping the speech engine underneath (SFSpeechRecognizer → SpeechAnalyzer/en_IN) cannot
//  disturb it, and so it can be tested against a corpus without a microphone.
//
//  Everything here is a pure function of text plus per-token confidence. It never touches audio,
//  permissions or the mic, which is what makes both engines able to share it.
//
//  Rules for changing this file:
//    • Patterns may be ADDED. Recall only goes up; the risk to manage is false wakes.
//    • Existing patterns and thresholds are not edited without a corpus run proving no regression.
//    • `Tests/wake-corpus.swift` must pass before and after.
//

import Foundation

/// One word as the recogniser heard it, with how sure it was.
struct OrbitWakeToken {
    let text: String
    let confidence: Double
}

/// A single transcript observation, from whichever engine produced it.
struct OrbitWakeSample {
    let text: String
    /// `true` once the engine has committed the text and will not revise it.
    let isFinal: Bool
    let tokens: [OrbitWakeToken]
}

enum OrbitWakePhraseMatcher {

    struct Decision {
        let acceptedByPattern: Bool
        let isCandidate: Bool
        let avgConfidence: Double?
        let rejectedForLowConfidence: Bool
        let nameOnlyCandidate: Bool
        let directedNameCandidate: Bool
        let strictCandidate: Bool
        /// The wake phrase was also a question — "are you there ORBIT?", "are you awake?".
        /// Opening a listening orb answers the summons but ignores the question, which is what
        /// made ORBIT feel like a machine here. These deserve a spoken reply before listening.
        var isPresenceQuestion: Bool = false

        static let noMatch = Decision(
            acceptedByPattern: false,
            isCandidate: false,
            avgConfidence: nil,
            rejectedForLowConfidence: false,
            nameOnlyCandidate: false,
            directedNameCandidate: false,
            strictCandidate: false
        )
    }

    /// True when a wake phrase asked ORBIT something rather than just summoning it.
    static func isPresenceQuestion(_ rawText: String) -> Bool {
        let text = normalize(rawText)
        return presenceQuestionPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static let presenceQuestionPatterns: [String] = {
        let orbit = orbitFragment
        let state = #"(?:there|awake|up|around|listening|ready|alive|online|here|sleeping|asleep|with\s+me)"#
        return [
            // "are you there orbit", "r u awake orbit", and the pronoun-swallowed "you there orbit"
            #"\b(?:are|r)\s+(?:you|u)\s+"# + state + #"\b"#,
            #"\b(?:you|u)\s+"# + state + #"\s+"# + orbit + #"\b"#,
            // "orbit are you there", "orbit you up", bare "orbit are you"
            #"\b"# + orbit + #"\s+(?:are\s+)?(?:you|u)\s+"# + state + #"\b"#,
            #"\b"# + orbit + #"\s+are\s+(?:you|u)\b"#,
            // Measured mishearing of "orbit are you there".
            #"\b(?:what|watt)\s+bit\s+(?:are\s+)?(?:you|u)\s+"# + state + #"\b"#,
        ]
    }()

    /// Normalises a raw transcript the way every matcher below expects it:
    /// diacritics folded, lowercased, punctuation reduced to spaces, runs of space collapsed.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let cleaned = folded.replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
        return cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Wake detection tuned for higher recall while keeping false triggers manageable.
    static func evaluate(_ sample: OrbitWakeSample) -> Decision {
        let collapsed = normalize(sample.text)
        let strictCandidate = hasStrictWakePhrase(collapsed)
        let approxCandidate = hasApproxWakePhrase(collapsed) || hasLooseGreetingOrbitPhrase(collapsed)
        let nameOnlyCandidate = hasNameOnlyWakePhrase(collapsed)
        let directedNameCandidate = hasDirectedNameWakePhrase(collapsed)
        let hasCandidate = strictCandidate || approxCandidate || nameOnlyCandidate || directedNameCandidate
        guard hasCandidate else { return .noMatch }

        var avgConfidence: Double?

        if !sample.isFinal {
            // A long partial transcript may contain a wake phrase from far earlier in the
            // utterance; only the tail counts as an intent to wake.
            let tailLen = 132
            if collapsed.count > tailLen {
                let tail = String(collapsed.suffix(tailLen))
                let matchedInTail = hasStrictWakePhrase(tail)
                    || hasApproxWakePhrase(tail)
                    || hasNameOnlyWakePhrase(tail)
                    || hasDirectedNameWakePhrase(tail)
                guard matchedInTail else {
                    return Decision(
                        acceptedByPattern: false,
                        isCandidate: true,
                        avgConfidence: nil,
                        rejectedForLowConfidence: false,
                        nameOnlyCandidate: nameOnlyCandidate,
                        directedNameCandidate: directedNameCandidate,
                        strictCandidate: strictCandidate
                    )
                }
            }

            let wakeTokens = sample.tokens.filter {
                let token = $0.text
                    .lowercased()
                    .replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
                return greetingTokens.contains(token) || isOrbitLike(token)
            }
            if !wakeTokens.isEmpty {
                let avg = wakeTokens.reduce(0.0) { $0 + $1.confidence } / Double(wakeTokens.count)
                avgConfidence = avg

                func reject() -> Decision {
                    Decision(
                        acceptedByPattern: false,
                        isCandidate: true,
                        avgConfidence: avg,
                        rejectedForLowConfidence: true,
                        nameOnlyCandidate: nameOnlyCandidate,
                        directedNameCandidate: directedNameCandidate,
                        strictCandidate: strictCandidate
                    )
                }

                // Confidence is only a guard for fuzzy wake candidates.
                // For strict phrase matches ("hey/hi ... orbit"), accept even if confidence is low.
                if nameOnlyCandidate, avg < 0.30 { return reject() }
                // "Orbit, <command...>" should be highly reliable in practice.
                if directedNameCandidate, avg < 0.26 { return reject() }
                if !strictCandidate, !nameOnlyCandidate, !directedNameCandidate, avg < 0.11 { return reject() }
            }
        }

        return Decision(
            acceptedByPattern: true,
            isCandidate: true,
            avgConfidence: avgConfidence,
            rejectedForLowConfidence: false,
            nameOnlyCandidate: nameOnlyCandidate,
            directedNameCandidate: directedNameCandidate,
            strictCandidate: strictCandidate,
            isPresenceQuestion: isPresenceQuestion(collapsed)
        )
    }

    // MARK: - The name

    static let greetingTokens = Set(["hey", "hay", "hi", "hello", "helo"])

    /// Every way the recognisers have been observed to render "orbit", as a regex fragment.
    ///
    /// Written once and composed into the phrase patterns below, so a newly observed mishearing
    /// is added in one place and every wake phrase gains it at once. The split spellings
    /// ("or bit", "are bit") are what an Indian-accented "orbit" becomes on an en_CA model —
    /// the whole reason this table exists.
    static let orbitFragment = #"(?:orbit|orbits|orbitt|orbet|orbid|orvit|orbeat|arbit|"#
        + #"(?:or|our|oar|are|ar)\s+(?:bit|bits|beet|bitt|bert|beat))"#

    // MARK: - Phrase families

    static func hasStrictWakePhrase(_ text: String) -> Bool {
        strictPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Built once — recompiling ~30 regexes on every partial transcript, several times a second,
    /// for as long as the Mac is awake, is not free.
    private static let strictPatterns: [String] = {
        let orbit = orbitFragment
        let greet = #"(?:hey|hay|hi|hello|helo|yo)"#
        // Words that follow "are you ___ orbit" / precede "orbit are you ___".
        let presence = #"(?:there|awake|awake\s+yet|up|around|listening|ready|with\s+me|alive|online|here)"#

        return [
            // ——— Original tuned set. Do not edit; these are what works today. ———
            #"\b"# + greet + #"\s+"# + orbit + #"\b"#,
            #"\b"# + greet + #"\s+"# + orbit + #"\s+please\b"#,
            #"\b(?:hey|hay|hi|hello|helo)\s+\w+\s+"# + orbit + #"\b"#,
            #"\b(?:hey|hay|hi|hello|helo)\s+\w+\s+\w+\s+"# + orbit + #"\b"#,
            #"\bwake\s*up\s+"# + orbit + #"\b"#,
            #"\bwake\s+"# + orbit + #"\b"#,
            #"\bwake\s+a\s+"# + orbit + #"\b"#,
            #"\btime\s+to\s+wake\s+up\s+"# + orbit + #"\b"#,
            #"\bget\s+up\s+"# + orbit + #"\b"#,
            #"\b"# + orbit + #"\s+wake\s+up\b"#,
            #"\b"# + orbit + #"\s+are\s+you\s+awake\b"#,
            #"\bhey\s+wake\s+up\b"#,

            // ——— Added 2026-08-02: natural phrasings Ayush asked for. ———
            // Name-last presence checks: "are you there orbit", "are you awake orbit".
            #"\b(?:are|r)\s+(?:you|u)\s+"# + presence + #"\s+"# + orbit + #"\b"#,
            // Same, with the pronoun swallowed in fast speech: "you there orbit".
            #"\b(?:you|u)\s+"# + presence + #"\s+"# + orbit + #"\b"#,
            // Name-first: "orbit are you there", "orbit you up".
            #"\b"# + orbit + #"\s+(?:are\s+)?(?:you|u)\s+"# + presence + #"\b"#,
            // Bare "orbit are you" — the tail is often cut off before the last word lands.
            #"\b"# + orbit + #"\s+are\s+(?:you|u)\b"#,
            // Attention-getters: "listen orbit", "listen up orbit", "wake orbit up".
            #"\blisten(?:\s+up)?\s+"# + orbit + #"\b"#,
            #"\bwake\s+"# + orbit + #"\s+up\b"#,
            #"\b"# + orbit + #"\s+listen(?:\s+up)?\b"#,
            // Time-of-day greetings, which is how a companion actually gets addressed.
            #"\bgood\s+(?:morning|afternoon|evening|night)\s+"# + orbit + #"\b"#,
            #"\b"# + orbit + #"\s+good\s+(?:morning|afternoon|evening|night)\b"#,
            // "orbit hello" / "orbit hey" — name first, greeting second.
            #"\b"# + orbit + #"\s+"# + greet + #"\b"#,
            // Rousing phrasings that don't use "wake".
            #"\b(?:come\s+on|c\s*mon)\s+"# + orbit + #"\b"#,
            #"\b(?:okay|ok|hey)\s+then\s+"# + orbit + #"\b"#,
            #"\bare\s+(?:you|u)\s+(?:sleeping|asleep)\s+"# + orbit + #"\b"#,
            #"\b"# + orbit + #"\s+(?:are\s+)?(?:you|u)\s+(?:sleeping|asleep)\b"#,
            #"\bexcuse\s+me\s+"# + orbit + #"\b"#,

            // ——— Mishearings measured against the en_IN model, 2026-08-02. ———
            // Captured by replaying synthesized Indian-English speech through the real engine
            // (scratchpad harness), not guessed. Each one is anchored by the words around it —
            // "what bit are you there" and "listen now a bit" are not things anyone says by
            // accident — so they cannot fire as a bare name token and cause a false wake.
            #"\bhere\s+"# + orbit + #"\b"#,                                    // "hey orbit"
            #"\b(?:what|watt)\s+bit\s+(?:are\s+)?(?:you|u)\s+"# + presence + #"\b"#,  // "orbit are you there"
            // End-anchored: "listen now a bit" is only a wake phrase when it is the whole
            // utterance. Unanchored it fired inside "listen now a bit later" — a false wake the
            // corpus caught before it ever reached the mic.
            #"\blisten\s+now\s+a\s+bit\s*$"#,                                  // "listen orbit"
        ]
    }()

    static func hasApproxWakePhrase(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return false }
        let heyTokens = Set(["hey", "hay", "hi", "hello", "helo", "yo", "heyy"])
        // "up" is a filler between "wake" and "orbit"; "a" handles swallowed "up" in fast speech
        let fillers = Set(["there", "yo", "okay", "ok", "uh", "um", "up", "a"])

        for i in words.indices where heyTokens.contains(words[i]) {
            if i + 1 < words.count, orbitTokenAt(words, i + 1) { return true }
            if i + 2 < words.count, words[i + 1] == "or", isOrbitLike("or" + words[i + 2]) { return true }
            if i + 2 < words.count, fillers.contains(words[i + 1]), orbitTokenAt(words, i + 2) { return true }
            // "hey [filler] or bit" (orbit split by STT)
            if i + 3 < words.count, fillers.contains(words[i + 1]),
               words[i + 2] == "or", isOrbitLike("or" + words[i + 3]) { return true }
        }

        // Handle "wake [up] orbit" and "wake [up] or bit"
        for i in words.indices where words[i] == "wake" {
            // "wake orbit"
            if i + 1 < words.count, orbitTokenAt(words, i + 1) { return true }
            // "wake up orbit"
            if i + 2 < words.count, fillers.contains(words[i + 1]), orbitTokenAt(words, i + 2) { return true }
            // "wake up or bit" (STT split)
            if i + 3 < words.count, fillers.contains(words[i + 1]),
               words[i + 2] == "or", isOrbitLike("or" + words[i + 3]) { return true }
            // "wake or bit" (no "up", STT split)
            if i + 2 < words.count, words[i + 1] == "or", isOrbitLike("or" + words[i + 2]) { return true }
        }

        return false
    }

    static func hasLooseGreetingOrbitPhrase(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return false }
        let greetings = Set(["hey", "hay", "hi", "hello", "helo", "yo", "heyy"])
        for i in words.indices where greetings.contains(words[i]) {
            let end = min(words.count, i + 4)
            if i + 1 < end {
                for j in (i + 1) ..< end {
                    let token = words[j]
                    if isOrbitLike(token) || levenshtein(token, "orbit") <= 2 {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func hasNameOnlyWakePhrase(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }
        if words.count == 1 {
            return isOrbitLike(words[0])
        }
        if words.count == 2 {
            let first = words[0]
            let second = words[1]
            return (orbitTokenAt(words, 0) && ["please", "now"].contains(second))
                || (["hey", "hi"].contains(first) && orbitTokenAt(words, 1))
        }
        if words.count == 3 || words.count == 4 {
            guard orbitTokenAt(words, 0) else { return false }
            let remainder = words.dropFirst()
            let commonAddress = Set(["please", "now", "hey", "hi", "hello"])
            return remainder.allSatisfy { commonAddress.contains($0) }
        }
        return false
    }

    static func hasDirectedNameWakePhrase(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2, words.count <= 11 else { return false }
        guard orbitTokenAt(words, 0) else { return false }

        let second = words[1]
        if ["and", "or", "but", "the", "a", "an"].contains(second) {
            return false
        }

        let commandStarters = Set([
            "please", "can", "could", "would", "will", "tell", "open", "start", "show", "give", "help", "set",
            "what", "when", "where", "why", "how", "remind", "check", "play", "find",
        ])
        if commandStarters.contains(second) {
            return true
        }

        // Accept "orbit i need..." and similar natural starts.
        if ["i", "we", "let", "lets", "need", "want", "can", "could", "would", "do"].contains(second) {
            return true
        }

        return false
    }

    static func orbitTokenAt(_ words: [String], _ index: Int) -> Bool {
        guard index >= 0, index < words.count else { return false }
        if isOrbitLike(words[index]) {
            return true
        }
        if index + 1 < words.count {
            let first = words[index]
            let second = words[index + 1]
            // "are bit" covers Indian accent STT output for "orbit"
            if ["or", "our", "oar", "are"].contains(first), ["bit", "beet", "bitt", "bert"].contains(second) {
                return true
            }
        }
        return false
    }

    static func isOrbitLike(_ raw: String) -> Bool {
        let token = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z]", with: "", options: .regularExpression)
        guard !token.isEmpty else { return false }
        if token == "orbit" { return true }
        if ["orvit", "orbet", "orbid", "orbitt"].contains(token) { return true }
        if abs(token.count - 5) > 2 { return false }
        return levenshtein(token, "orbit") <= 1
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var dist = Array(0 ... bChars.count)
        for i in 1 ... aChars.count {
            var prev = dist[0]
            dist[0] = i
            for j in 1 ... bChars.count {
                let tmp = dist[j]
                if aChars[i - 1] == bChars[j - 1] {
                    dist[j] = prev
                } else {
                    dist[j] = min(prev, dist[j - 1], dist[j]) + 1
                }
                prev = tmp
            }
        }
        return dist[bChars.count]
    }
}
