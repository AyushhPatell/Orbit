//
//  OrbitUtteranceCleanup.swift
//  ORBITMac
//
//  Pure text helpers for turning a spoken sentence into a usable reminder/event.
//
//  Written after this reminder was created from "Um, would you please remind me to buy tickets
//  for Spiderman, um, on for today":
//
//      title: "Um, would you please remind me to buy tickets for Spiderman, um, on for   today"
//      due:   Tuesday 12:00   ← a time the user never said
//
//  Three independent failures, all of which this file addresses:
//
//  1. **One filler word defeated the whole parser.** `cleanAsTitle` strips request framing with
//     `hasPrefix`, anchored at position 0. The utterance began "Um, ", so none of its ~90
//     prefixes matched and the entire raw sentence became the title. Speech is full of "um" —
//     an extractor anchored at character zero cannot survive contact with a real voice.
//
//  2. **The safety net was too literal.** The broker already bails out to the brain when "title
//     equals the whole input" — but it compares exact strings, and a single stripped date word
//     was enough for that test to pass while extraction had plainly failed. What matters is not
//     whether the string changed, but whether it still reads like a *request* rather than a task.
//
//  3. **Noon was invented.** "Tuesday" has no clock time; `NSDataDetector` fills one in (12:00)
//     and the broker could not tell that apart from a time the user actually spoke. Ayush's
//     point: don't assume, ask. A reminder at a guessed hour is worse than one short question.
//
//  These are pure functions with no dependencies so they can be tested without the app —
//  see Tests/wake-corpus.swift.
//

import Foundation

enum OrbitUtteranceCleanup {

    /// Removes speech disfluencies so downstream prefix matching sees the actual sentence.
    ///
    /// Only removes them where they are unambiguously filler — bounded by word boundaries and
    /// followed/preceded by a break. "Um" and "uh" are never English content words, but "like"
    /// and "so" are, so they are left alone: mangling "remind me to like the post" to fix a
    /// filler would trade one wrong title for another.
    static func stripDisfluencies(_ text: String) -> String {
        var s = text
        let fillers = ["um", "umm", "uhm", "uh", "uhh", "er", "erm", "hmm", "mmm", "eh"]
        for filler in fillers {
            // Leading: "Um, would you…" / "Um would you…"
            s = s.replacingOccurrences(
                of: #"^\s*"# + filler + #"\b[\s,.!?-]*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            // Mid-sentence, comma-delimited: "…Spiderman, um, on for today"
            s = s.replacingOccurrences(
                of: #"[,]\s*"# + filler + #"\s*[,]"#,
                with: ",",
                options: [.regularExpression, .caseInsensitive]
            )
            // Mid-sentence, space-delimited.
            s = s.replacingOccurrences(
                of: #"\s+"# + filler + #"\b(?=\s)"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return s
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a supposedly-extracted title still reads like the request that produced it.
    ///
    /// This is the honest version of "did extraction actually work?". A real title is the *task*
    /// ("buy tickets for Spider-Man"); if the words that asked for the reminder are still in
    /// there, the parser did not understand the sentence and must not pretend it did.
    static func looksLikeUnextractedRequest(_ title: String) -> Bool {
        let t = title.lowercased()
        let framing = [
            #"\bremind\s+me\b"#,
            #"\bremind\s+us\b"#,
            #"\bset\s+(a|an|up\s+a)?\s*reminder\b"#,
            #"\bcreate\s+(a|an)?\s*reminder\b"#,
            #"\badd\s+(a|an)?\s*reminder\b"#,
            #"\bmake\s+(a|an)?\s*(reminder|note)\b"#,
            #"\b(would|could|can|will)\s+you\b"#,
            #"\bi\s+(want|need)\s+you\s+to\b"#,
            #"\bdon'?t\s+let\s+me\s+forget\b"#,
            #"\bnote\s+to\s+self\b"#,
            #"\bschedule\s+a\s+reminder\b"#,
        ]
        return framing.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// The calendar equivalent: an "event title" that still contains the words that asked for it.
    ///
    /// `cleanCalendarTitle` strips its prefixes with `hasPrefix` too, so it has exactly the same
    /// blind spot — one filler word and the whole raw sentence becomes the event name.
    static func looksLikeUnextractedEventRequest(_ title: String) -> Bool {
        let t = title.lowercased()
        let framing = [
            #"\b(schedule|book|arrange|set\s+up)\s+(a|an|the)\b"#,
            #"\b(add|put)\s+.{0,12}\b(to|on|in)\s+(my|the)\s+calendar\b"#,
            #"\bcreate\s+(a|an)?\s*(calendar\s+)?(event|entry|meeting|appointment)\b"#,
            #"\b(would|could|can|will)\s+you\b"#,
            #"\bi\s+(want|need)\s+you\s+to\b"#,
            #"\bblock\s+(out\s+)?(some\s+)?time\b"#,
            #"\bnew\s+(calendar\s+)?event\b"#,
        ]
        return framing.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// True when the user actually spoke a clock time, as opposed to only a day.
    ///
    /// `NSDataDetector` resolves a bare "Tuesday" to Tuesday at 12:00 with no way to tell that
    /// noon was inferred rather than heard. Without this check ORBIT silently invents an hour.
    static func hasExplicitClockTime(_ text: String) -> Bool {
        let t = text.lowercased()
        // Speech gives words, not digits. This helper originally matched only `\d`, so a spoken
        // "remind me today at five PM" was read as "no time given" — ORBIT escalated a request
        // that was already complete, and the hour it eventually used was invented. Spoken
        // numbers are first-class here.
        let hourWord = #"(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
        let minuteWord = #"(?:o'?clock|thirty|fifteen|forty[\s-]?five|ten|twenty|five|oh\s+\w+)"#
        let patterns = [
            #"\b\d{1,2}\s*:\s*\d{2}\b"#,                      // 3:30
            #"\b\d{1,2}\s*(am|pm|a\.m\.|p\.m\.)\b"#,          // 3pm
            #"\bat\s+\d{1,2}\b"#,                              // at 3
            #"\b"# + hourWord + #"\s*(am|pm|a\.m\.|p\.m\.)\b"#,   // five pm
            #"\bat\s+"# + hourWord + #"\b"#,                       // at five
            #"\b"# + hourWord + #"\s+"# + minuteWord + #"\b"#,     // five thirty, nine o'clock
            #"\b\d{1,2}\s+"# + minuteWord + #"\b"#,                // 9 thirty
            #"\bat\s+(noon|midnight|midday)\b"#,
            #"\b(noon|midnight|midday)\b"#,
            #"\b(morning|afternoon|evening|night|tonight|lunchtime|breakfast|dinner)\b"#,
            #"\bin\s+\d+\s*(minute|min|hour|hr)s?\b"#,
            #"\bin\s+(a|an|half)\s+(an\s+)?(hour|minute)\b"#,
            #"\bo'?clock\b"#,
            #"\bhalf\s+past\b"#,
            #"\bquarter\s+(past|to)\b"#,
            #"\bfirst\s+thing\b"#,
            #"\bend\s+of\s+(the\s+)?day\b"#,
            // Ranges: "from 2 to 4", "from ten till noon" — the range itself is an explicit time
            // even though neither end carries am/pm.
            #"\bfrom\s+(\d{1,2}|"# + hourWord + #")\b.{0,12}\b(to|till|until)\s+(\d{1,2}|"# + hourWord + #")\b"#,
            #"\bbetween\s+(\d{1,2}|"# + hourWord + #")\b.{0,12}\band\s+(\d{1,2}|"# + hourWord + #")\b"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// True when an extracted title is too thin to be a real task.
    ///
    /// Real reminders came out titled **"It"** and **"Today, August 2"** — the leftovers of a
    /// sentence after the date was cut out, saved as if they were the task. A title that is a
    /// bare pronoun, a number, or a date fragment means extraction failed; it is not something a
    /// person would ever write on a to-do list, and saving it is worse than asking.
    static func isTooThinToBeATask(_ title: String) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if t.isEmpty { return true }
        let words = t.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)

        // Pure pronouns / filler / bare numbers, alone or in pairs.
        let hollow: Set<String> = [
            "it", "that", "this", "them", "these", "those", "there", "here",
            "me", "my", "mine", "one", "some", "any", "thing", "things", "stuff",
            "please", "now", "then", "ok", "okay", "yes", "no", "reminder", "remind",
            "am", "pm", "at", "on", "for", "to", "of", "and", "a", "an", "the",
        ]
        let dayWords: Set<String> = [
            "today", "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday",
            "friday", "saturday", "sunday", "january", "february", "march", "april", "may",
            "june", "july", "august", "september", "october", "november", "december",
        ]
        // Spoken numbers count as numbers — "for eight" is as empty a title as "for 8".
        let numberWords: Set<String> = [
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "twenty", "thirty",
            "forty", "fifty", "noon", "midnight", "oclock", "o'clock", "half", "quarter",
        ]
        // Every word is hollow, a day name, or a number → nothing of substance survived.
        let substantive = words.filter { word in
            !hollow.contains(word) && !dayWords.contains(word)
                && !numberWords.contains(word) && Int(word) == nil
        }
        return substantive.isEmpty
    }

    /// True when the text names a specific day, as opposed to only a time of day.
    ///
    /// Used when answering "what time on Tuesday?": a bare "3pm" must be grafted onto the
    /// Tuesday already established, but "actually Wednesday at 3" should move the day.
    static func mentionsExplicitDay(_ text: String) -> Bool {
        let t = text.lowercased()
        let patterns = [
            #"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            #"\b(today|tomorrow|tonight|overmorrow)\b"#,
            #"\b(next|this|coming)\s+(week|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            #"\bin\s+\d+\s*(day|week|month)s?\b"#,
            #"\b\d{1,2}(st|nd|rd|th)\b"#,
            #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"#,
            #"\b\d{1,2}\s*/\s*\d{1,2}\b"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }
}
