//
//  OrbitVoiceIntentHelpers.swift
//  ORBITMac
//
//  Shared “stop / bye / later” detection for menu + wake voice paths.
//

import Foundation

enum OrbitVoiceIntentHelpers {
    static func isSessionStopCommand(_ text: String) -> Bool {
        // "sleep" and "rest" mean the same thing as "go to sleep". Checked first so the answer
        // does not depend on which synonym was used or how many words came with it.
        if isRestIntent(text) { return true }
        let normalized = normalize(text)
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        if words.count > 14 {
            return false
        }
        let questionHints = Set(["how", "why", "what", "when", "where", "which", "explain"])
        let stopLexicon = Set(["stop", "pause", "cancel", "halt", "quit", "bye", "goodbye", "later", "done", "enough"])
        let hasStopWord = !Set(words).intersection(stopLexicon).isEmpty
        if !Set(words).intersection(questionHints).isEmpty, !hasStopWord {
            return false
        }
        return isVoiceStopIntent(normalized)
    }

    /// True when the user is telling ORBIT itself to go and rest.
    ///
    /// Exists because of an ordering bug: `performIfCommand` runs before the stop-intent check,
    /// so a bare "sleep" was claimed by the command matcher and answered with "Opening sleep."
    /// while "go to sleep" fell through and correctly put ORBIT to rest. Same meaning, opposite
    /// behaviour. `performIfCommand` now declines these up front so they reach the stop path.
    ///
    /// Deliberately narrow. Sleep is also a legitimate *object* of commands — the display, a
    /// Focus mode, a timer, a memory about bedtime — and every one of those must still work,
    /// so anything naming a target is rejected before the rest-phrase list is even consulted.
    static func isRestIntent(_ text: String) -> Bool {
        let t = normalize(text)
        guard !t.isEmpty else { return false }
        let words = t.split(separator: " ").map(String.init)
        // A rest instruction is short. "i couldn't sleep last night because…" is not one.
        guard words.count <= 5 else { return false }

        // Anything with a target is a command about sleep, not an instruction to ORBIT:
        // "sleep my screen", "turn on sleep focus", "set a sleep timer", "remind me to sleep".
        let targets: Set<String> = [
            "screen", "display", "monitor", "mac", "computer", "laptop", "machine",
            "focus", "mode", "timer", "alarm", "remind", "reminder", "set", "turn",
            "schedule", "when", "what", "why", "how", "much", "did", "do", "does",
            "cant", "cannot", "couldnt", "night", "hours", "tonight", "music", "song",
        ]
        guard Set(words).isDisjoint(with: targets) else { return false }

        // Negations: "don't sleep", "no need to sleep".
        if t.range(of: #"\b(dont|do not|never|no)\b"#, options: .regularExpression) != nil { return false }

        let patterns = [
            #"^(orbit[, ]+)?sleep( now| please)?$"#,
            #"^sleep( orbit)?$"#,
            #"^(orbit[, ]+)?go to sleep( now| please)?$"#,
            #"^go to sleep,? orbit$"#,
            #"^(orbit[, ]+)?go back to sleep$"#,
            #"^(orbit[, ]+)?(take a |go and |go )?rest( now| please)?$"#,
            #"^(you can |please )?(go to sleep|sleep|rest)( now)?$"#,
            #"^(orbit[, ]+)?time to sleep$"#,
            #"^(orbit[, ]+)?(back to sleep|off to sleep)$"#,
            #"^(orbit[, ]+)?sleep tight$"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// True when ORBIT's **own reply** was a goodbye, so the mic must not reopen after it.
    ///
    /// Ayush said "go away"; ORBIT understood perfectly and answered *"okay, I'm putting this
    /// here for now"* — and then the listening orb came straight back. The words and the
    /// behaviour came from two different places: `willResume` was computed as
    /// `continuousVoiceMode || …`, so with continuous voice on, **every** reply reopened the mic
    /// regardless of what it said. Saying goodbye and then continuing to listen is the single
    /// clearest way to look like a machine that did not understand.
    ///
    /// A question is never a farewell — ORBIT's own "Is there anything else?" must still resume,
    /// which is why that check comes first.
    static func isFarewellReply(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return false }
        let t = normalize(trimmed)

        let patterns = [
            #"\btalk (to you )?(soon|later)\b"#,
            #"\b(see|catch) you (later|around|soon)\b"#,
            #"\buntil next time\b"#,
            #"\bgood ?night\b"#,
            #"\b(rest|sleep) well\b"#,
            #"\btake care\b"#,
            #"\bsigning off\b"#,
            #"\bgoing (quiet|to sleep)\b"#,
            #"\b(i'?ll|i will) (be around|leave you to it|let you get on|be quiet)\b"#,
            #"\bi'?ll be here when you need me\b"#,
            #"\bi'?m here whenever you need me\b"#,
            #"\bhere whenever you need\b"#,
            #"\b(putting|leaving) (this|it) here for now\b"#,
            #"\bletting this go for now\b"#,
            #"\blet me know if (something|anything) comes up\b"#,
            #"\bjust say the word\b"#,
            #"\bgive me a shout\b"#,
            #"\bgood ?bye\b"#,
            #"\bbye for now\b"#,
            // Deliberately NOT included: "let me know if you need anything else" and similar
            // offers of further help. Those follow completed tasks mid-conversation, and ending
            // the turn on them would cut Ayush off rather than let him go.
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    static func isVoiceStopIntent(_ text: String) -> Bool {
        let t = normalize(text)
        guard !t.isEmpty else { return false }
        if t.count > 240 { return false }

        // Respect negations before short-circuit stop keywords.
        if t.range(of: #"\b(don'?t|do not|never)\s+(\w+\s+){0,8}\b(stop|pause|quit|cancel)\b"#, options: .regularExpression) != nil {
            return false
        }

        let phrasePatterns = [
            #"let'?s stop"#,
            #"let us stop"#,
            #"we should stop"#,
            #"can we stop"#,
            #"need to stop"#,
            #"time to stop"#,
            #"stop (it )?(here|now|please|for today|for now)"#,
            #"stop (talking|here)"#,
            #"stop listening"#,
            #"stop hearing"#,
            #"that'?s (it|enough|all|good)"#,
            #"that is (it|enough)"#,
            #"we'?re done"#,
            #"we are done"#,
            #"i'?m done"#,
            #"i am done"#,
            #"all done"#,
            #"no more( for now| today)?"#,
            #"enough for (now|today)"#,
            #"call it (a day|quits)"#,
            #"talk (again )?later"#,
            #"catch you later"#,
            #"see you later"#,
            #"good[- ]?bye"#,
            #"bye for now"#,
            #"go to sleep( now)?$"#,
            #"go to sleep orbit( now)?$"#,
            #"orbit go to sleep( now)?$"#,
            #"thank(s| you)?[, ]+bye"#,
            #"thank(s| you)?[, ]+(good[- ]?bye|bye for now)"#,
            #"thanks[, ]+talk (to you )?later"#,
            #"thank(s| you)?[, ]+that'?s (it|all)"#,
            #"no thanks"#,
            #"no thank you"#,
            #"nothing else"#,
            #"nothing for now"#,
            #"that'?s all for now"#,
            #"that will be all"#,
            #"we'?re good"#,
            #"we are good"#,
            #"you can (stop|go|rest|leave)( now)?"#,
            // Dismissals. "go away" reached the brain, which said goodbye correctly — but the
            // local path never recognised it, so the turn never took the stop branch.
            #"^(orbit[, ]+)?go away( now| please)?$"#,
            #"^(please )?(go|get) (away|out)( now)?$"#,
            #"^leave me (alone|be)( now| for now)?$"#,
            #"^(orbit[, ]+)?(shoo|scram|dismissed)$"#,
            #"^(you'?re|you are) dismissed$"#,
            #"^off you go$"#,
            #"^(that'?ll|that will) be all( for now)?$"#,
            #"^(orbit[, ]+)?leave it$"#,
            #"stop listening"#,
            #"go quiet"#,
            #"stand down"#,
            #"sleep now"#,
            #"go to sleep now"#,
            #"stop it"#,
            #"stop please"#,
            #"pause (here|now|please)"#,
            #"we can pause"#,
            #"let'?s pause"#,
            #"talk to you later"#,
            #"i('?m| am) heading out"#,
            #"gotta go"#,
            #"got to go"#,
            #"i (need|have) to go"#,
            #"i'?m (leaving|out)"#,
            #"good night( orbit)?"#,
            #"orbit good night"#,
            #"orbit (stop|pause|sleep|goodbye|bye)"#,
            #"(stop|goodbye|bye) orbit"#,
            #"(okay|ok|alright|right)[, ]+(bye|goodbye|later|stop|see you)"#,
            #"(thanks|thank you)[, ]+(that'?s all|that is all|i'?m good|we'?re good)"#,
            #"i'?m good( for now| thanks)?"#,
            #"i'?ll let you (go|rest)"#,
            #"(take care|have a good (one|day|night))"#,
            #"you'?re (dismissed|free)"#,
        ]
        for p in phrasePatterns {
            if t.range(of: p, options: .regularExpression) != nil {
                return true
            }
        }

        let words = t.split(separator: " ").map(String.init)
        let wordSet = Set(words)

        // Task words mean this is a command, not a stop — guard all loose matching below.
        let taskIndicators = Set([
            "remind", "reminder", "reminders", "calendar", "schedule", "event",
            "create", "add", "open", "search", "find", "note", "message", "email",
            "alarm", "timer", "set", "book", "plan",
        ])
        if !wordSet.isDisjoint(with: taskIndicators) { return false }

        let stopWords: Set<String> = [
            "stop", "pause", "cancel", "halt", "quit", "bye", "later", "enough", "thanks", "thank", "sleep",
        ]
        if words.count <= 5, !wordSet.intersection(stopWords).isEmpty {
            return true
        }

        // Exact stop-token check only — fuzzy (Levenshtein) matching removed because common
        // words like "water" (distance 1 from "later") or "by" caused false positives.
        let stopCueTokens = ["stop", "pause", "cancel", "halt", "quit", "bye", "later"]
        for i in words.indices where stopCueTokens.contains(words[i]) {
            if words[i] == "stop", i > 0, words[i - 1] == "bus" { continue }
            return true
        }
        // "by" removed — too many false positives ("remind me by 5pm", "stand by", etc.)
        if t.range(of: #"\b(bye|goodbye)\b"#, options: .regularExpression) != nil {
            return true
        }
        if t.contains("talk"), t.range(of: #"\b(later)\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        text
            // Typographic apostrophes must become straight ones BEFORE punctuation is stripped.
            // Otherwise "I’ll leave you to it" normalises to "i ll leave you to it" and every
            // `i'?ll` pattern misses — and ORBIT's own spoken replies are written with ’.
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9\\s']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Returns true when the user is asking ORBIT to look at/read the screen.
    static func isScreenContextQuery(_ text: String) -> Bool {
        let t = normalize(text)
        let patterns: [String] = [
            #"what'?s (on|this on) (my )?screen"#,
            #"what (is|are) (on|this on) (my |the )?screen"#,
            #"what is showing on (my |the )?screen"#,
            #"what'?s showing on (my |the )?screen"#,
            #"what am i (looking at|seeing)"#,
            #"what are you seeing"#,
            #"describe (my |the )?screen"#,
            #"summarize (what'?s on|my|the) screen"#,
            #"read (my |the )?screen"#,
            #"what (do i|can you) see (on screen|on my screen|here)?"#,
            #"what'?s in front of me"#,
            #"what does (my |the )?screen say"#,
            #"what'?s (happening|going on) on (my )?screen"#,
            #"explain (what'?s on|my) screen"#,
            #"tell me (what'?s on|about) (my )?screen"#,
            #"can you see (my |the )?screen"#,
            #"look at (my |the )?screen"#,
            #"what is there on (my |the )?screen"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// Returns true when the user's message is a gratitude/closing with no follow-up task.
    /// Matches "thank you so much", "thank you, I appreciate it", etc. without task keywords.
    static func isGratitudeClose(_ text: String, lastReplyWasQuestion: Bool = false) -> Bool {
        let lower = normalize(text)
        let words = lower.split(separator: " ").map(String.init)
        guard words.count >= 1, words.count <= 12 else { return false }

        // If the message contains any task / command words, it's not a closing.
        let taskIndicators = Set([
            "open", "find", "create", "add", "set", "schedule", "remind", "lock",
            "wifi", "volume", "battery", "dark", "mute", "unmute", "search",
            "calendar", "reminder", "folder", "file", "delete", "trash", "empty",
            "weather", "note", "play", "summarize", "translate", "run", "check",
            "read", "call", "message", "email", "turn",
        ])
        if !Set(words).isDisjoint(with: taskIndicators) { return false }

        // Gratitude: "thank you", "thanks so much" — always a closing regardless of context
        let hasThankYou = lower.contains("thank") || lower.contains("appreciate")
        if hasThankYou { return true }

        // CLEAR multi-word closings — always end the session, even after a question
        let strongClosings: Set<String> = [
            "that's it", "that is it", "that's all", "that is all",
            "all good", "all done", "we're good", "we are good",
            "i'm good", "i am good", "i'm fine", "i am fine",
            "i'm all set", "i am all set", "all set",
            "no that's it", "no that is it", "no that's all",
            "no thanks", "no thank you", "nope nothing",
            "nothing else", "nothing more", "that was all",
            "forget it", "forget about it", "never mind", "nevermind",
            "it was cool", "that was cool", "that was great",
            "not right now", "not now", "maybe later",
        ]
        if words.count <= 6, strongClosings.contains(lower) { return true }
        let strongStarters = ["that's all", "that's it", "that is all", "that is it",
                                "all good", "all done", "i'm good", "i'm fine",
                                "i'm all set", "nothing else", "nothing more",
                                "no thanks", "no thank you", "forget",
                                "never mind", "not right now", "not now"]
        if words.count <= 6, strongStarters.contains(where: { lower.hasPrefix($0) }) { return true }

        // Ambiguous single words: "nope", "no", "okay", "nothing", "cool"
        // These are ONLY closings when ORBIT's last reply was NOT a question.
        // If ORBIT just asked something, these are answers, not closings.
        if !lastReplyWasQuestion, words.count <= 3 {
            let softClosings: Set<String> = [
                "nothing", "nope", "no", "nah",
                "okay", "ok", "got it", "sounds good", "cool",
                "perfect", "great", "awesome", "nice",
            ]
            if softClosings.contains(lower) { return true }
            let softStarters = ["nothing", "nope", "okay", "ok ", "cool",
                                "perfect", "great", "awesome"]
            if softStarters.contains(where: { lower.hasPrefix($0) }) { return true }
        }

        return false
    }

    static func isRepeatIntent(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = [
            "repeat that", "say that again", "what was that", "what did you say",
            "can you repeat", "please repeat", "say it again", "repeat please",
            "i didn't catch that", "i didn't hear that", "i didn't get that",
            "didn't catch that", "didn't hear that", "didn't get that",
            "could you repeat", "come again", "pardon", "one more time",
            "what did you just say", "what was that again",
        ]
        return phrases.contains { lower.contains($0) }
    }

}
