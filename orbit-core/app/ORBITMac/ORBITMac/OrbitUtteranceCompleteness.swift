//
//  OrbitUtteranceCompleteness.swift
//  ORBITMac
//
//  Semantic endpointing: decide when to commit from what was SAID, not from silence alone.
//
//  The failure this exists for is in ORBIT.md's own weakness list — "very long sentences with
//  mid-sentence natural pauses can still commit early" — and it is the same shape as the "Um"
//  bug: ORBIT hears a gap and assumes the thought is over. A person doesn't. A person hears
//  "remind me to…" and waits, because that sentence is obviously unfinished.
//
//  Modern voice stacks pair a silence threshold with a *completeness* signal for exactly this
//  reason. Here that signal is linguistic rather than a model, deliberately:
//
//    - it must run on EVERY partial transcript, so it has to be instant (no I/O, no inference)
//    - it must work with no internet — the offline principle covers the ears too
//    - pure functions are corpus-testable, which is how every voice change in this project has
//      been proven (wake corpus, reminder corpus)
//    - it ports to iOS unchanged
//
//  Precision over recall, on purpose. A false "he's still talking" makes ORBIT feel sluggish on
//  every turn, so only strong evidence — a dangling function word, a trailing comma — extends
//  the window. Everything else keeps exactly the behaviour that was already tuned.
//
//  Known limit, stated rather than hidden: a pause AFTER a grammatically complete clause
//  ("I was thinking about the gym" … "and then swimming") is invisible to text alone. Catching
//  that needs prosody or a trained turn-detector; the length rules below only soften it.
//

import Foundation

enum OrbitUtteranceCompleteness {

    enum Completeness {
        /// Ends on a word that cannot end a sentence — he is mid-thought.
        case openEnded
        /// Terminal punctuation: the recogniser believes the sentence closed.
        case complete
        /// No strong signal either way.
        case neutral
    }

    /// Words that cannot be the last word of a finished utterance.
    ///
    /// All function words. A content word can legitimately end a sentence ("call mum"), so
    /// none appear here — that is what keeps false positives near zero.
    private static let danglingWords: Set<String> = [
        // coordinating + subordinating conjunctions
        "and", "or", "but", "nor", "so", "yet", "because", "since", "although", "though",
        "while", "when", "whenever", "if", "unless", "until", "till", "after", "before",
        "whether", "than", "plus",
        // prepositions
        "to", "for", "with", "without", "of", "at", "on", "in", "into", "onto", "from",
        "by", "about", "over", "under", "through", "between", "among", "around", "near",
        "against", "toward", "towards", "upon", "within", "across", "behind", "beside",
        // determiners that cannot stand without a noun
        //
        // Deliberately NOT here: that / this / these / those / some / any / both / another /
        // each / more / much / his / her. Every one of them ends a real command or sentence
        // — "cancel that", "delete this", "I'll take some", "I want more", "call her" — and
        // the corpus caught "cancel that" being made to wait 2.6 s because "that" was listed.
        "a", "an", "the", "my", "your", "its", "our", "their", "every",
        // auxiliaries + modals
        "is", "are", "was", "were", "am", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "can", "could", "will", "would", "shall", "should",
        "may", "might", "must", "gonna", "wanna", "gotta",
        // intensifiers awaiting an adjective
        "very", "really", "quite",
    ]

    /// A sentence almost never ends on its subject. "can you", "tell him that I" — both
    /// obviously unfinished. Object pronouns (me, him, her, them, it) are excluded: they end
    /// commands constantly — "call her", "do it", "tell them".
    private static let subjectPronouns: Set<String> = ["i", "you", "we", "they", "he", "she"]

    /// Verbs that always take an object, and which ORBIT never accepts on their own.
    ///
    /// Excluded on purpose: play, stop, pause, cancel, repeat, mute, continue — every one of
    /// those IS a complete command here, and delaying them would slow the commonest actions.
    private static let transitiveCommandVerbs: Set<String> = [
        "open", "search", "call", "message", "text", "email", "tell", "ask", "send",
        "remind", "schedule", "find", "launch", "rename", "add", "create", "set",
        "turn", "put", "invite", "google",
    ]

    /// Words carrying no content of their own. An utterance made ENTIRELY of these is a
    /// request frame with nothing requested yet — "could you please", "we should probably".
    private static let contentlessWords: Set<String> = danglingWords
        .union(subjectPronouns)
        .union([
            "me", "him", "her", "them", "it", "us", "this", "that", "these", "those",
            "some", "any", "both", "another", "each", "more", "most", "less", "much",
            "many", "his", "as", "please", "probably", "maybe", "just", "actually",
            "also", "still", "then", "well", "okay", "ok", "like", "kind", "sort",
        ])

    /// Time prepositions: "remind me at" and "meet me at five" are both unfinished, the second
    /// because "five" is routinely the front half of "five thirty" or "five PM".
    private static let timePrepositions: Set<String> = ["at", "by", "around", "before", "after", "till", "until"]

    private static let spokenNumbers: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
    ]

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when the utterance ends on a bare hour that probably has more coming
    /// ("remind me at five" → "…thirty" / "…PM").
    static func endsOnUnfinishedTime(_ text: String) -> Bool {
        let tokens = words(in: text)
        guard let last = tokens.last else { return false }
        let isNumber = spokenNumbers.contains(last) || (Int(last) != nil && last.count <= 2)
        guard isNumber else { return false }
        // Only when a time preposition set it up — "set volume to 50" is finished.
        guard tokens.count >= 2 else { return false }
        return timePrepositions.contains(tokens[tokens.count - 2])
    }

    static func assess(_ transcript: String) -> Completeness {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .neutral }

        if let last = trimmed.last, [".", "!", "?"].contains(last) {
            return .complete
        }
        // A trailing comma, dash or ellipsis is the recogniser hearing a continuing intonation.
        if let last = trimmed.last, [",", ";", ":", "-", "\u{2013}", "\u{2014}"].contains(last) {
            return .openEnded
        }
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("\u{2026}") {
            return .openEnded
        }
        let tokens = words(in: trimmed)
        guard let lastWord = tokens.last else { return .neutral }

        if danglingWords.contains(lastWord) {
            return .openEnded
        }
        // A sentence ending on its subject is unfinished — EXCEPT a wh-question, where that is
        // the normal shape: "how are you" and "what about you" are complete, "can you" is not.
        // Same final word, opposite verdicts; the opening word decides.
        if subjectPronouns.contains(lastWord),
           !["how", "what", "where", "when", "why", "who", "which", "hows", "whats"]
                .contains(tokens.first ?? "") {
            return .openEnded
        }
        // Nothing but function words: the request frame arrived before the request.
        if tokens.allSatisfy({ contentlessWords.contains($0) }) {
            return .openEnded
        }
        // A transitive command verb with nothing to act on — "remind me to call", "search for"
        // (already caught by "for"), "open". Skipped when a determiner in front makes it a noun:
        // "I'll give him a call" ends on the same word and is finished.
        if transitiveCommandVerbs.contains(lastWord) {
            let precededByDeterminer = tokens.count >= 2
                && ["a", "an", "the", "my", "your", "his", "her", "its", "our", "their"]
                    .contains(tokens[tokens.count - 2])
            if !precededByDeterminer {
                return .openEnded
            }
        }
        if endsOnUnfinishedTime(trimmed) {
            return .openEnded
        }
        return .neutral
    }

    /// How long to wait for more speech, given what has been heard so far.
    ///
    /// The whole endpoint decision lives here so it can be exercised by the corpus without an
    /// audio engine, permissions, or a running app.
    static func endpointPause(for transcript: String, base: TimeInterval) -> TimeInterval {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return base }

        // Nothing but "um"/"uh": he is thinking, not talking. Filler is never committed, so a
        // long window here costs nothing and buys him time to find the words.
        if OrbitUtteranceCleanup.isFillerOnly(trimmed) { return 6.0 }

        switch assess(trimmed) {
        case .openEnded:
            // The sentence cannot be over. Wait properly rather than cutting him off.
            return min(3.4, base + 1.35)
        case .complete:
            return max(0.85, base - 0.25)
        case .neutral:
            break
        }

        // No grammatical signal: fall back to the length heuristics that were already tuned.
        // Longer utterances get more room because mid-sentence pauses grow with sentence length.
        let count = words(in: trimmed).count
        if count >= 16 { return min(2.8, base + 0.75) }
        if count >= 10 { return min(2.4, base + 0.35) }
        if count <= 2 { return min(2.0, base + 0.45) }
        return base
    }
}
