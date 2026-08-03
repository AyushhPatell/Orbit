//
//  OrbitCardPolicy.swift
//  ORBITMac
//
//  When the floating card is worth showing — and, just as importantly, when it isn't.
//
//  Phase 3.15 restored the clarification banner by showing a card for any brain reply ending
//  in "?". That was too blunt: ORBIT asks questions constantly in normal conversation
//  ("How's that?", "Anything else?"), and a card for every one of them turns a helpful signal
//  into visual noise. Ayush's report: *"it feels weird and there is no need."*
//
//  The card is not a decoration for questions. It exists for one reason: **speech is a poor
//  medium for things you must read, remember exactly, or decide on.** So it appears when
//  getting something wrong has a cost, or when the content genuinely cannot be held from
//  hearing it once:
//
//    - a pending CHOICE — a pick list, a confirmation, a spelling; he has to see the options
//    - a CONSEQUENTIAL confirmation — delete, send, run; the thing he's approving must be visible
//    - VERIFYING what was heard — "did you mean Kavan or Krish?"; names and spellings are
//      exactly what voice gets wrong, so showing them is the whole point
//    - a MISSING DETAIL for something being recorded — a reminder's time, an event's title;
//      the record has to be right, and a hearing slip becomes a wrong calendar entry
//    - DATA worth reading — a list of reminders, a weather readout, a briefing, a summary;
//      multi-fact content read aloud once is gone
//
//  And it stays away from ordinary conversation, which is most of what ORBIT says.
//
//  Pure functions, no UI, no state — so the corpus can prove the policy without running the app.
//

import Foundation

enum OrbitCardPolicy {

    /// Why a card is warranted. Also decides how long it should linger.
    enum Reason: String {
        /// A pick list, confirmation or spelling is awaiting his answer.
        case pendingChoice
        /// Approving something with consequences — delete, send, run.
        case confirmAction
        /// Checking a name, spelling, or a word ORBIT may have misheard.
        case verifyHearing
        /// A detail is missing from something being recorded (time, title, day).
        case missingDetail
        /// Multi-fact content that is hard to hold from speech alone.
        case dataToRead
        /// Text that must be read rather than heard (translations, non-Latin).
        case displayOnly
    }

    // MARK: - Signals

    /// Ordinary conversational questions. These are the ones that were cluttering the screen.
    private static let conversationalPatterns = [
        #"\banything else\b"#,
        #"\bwhat else\b"#,
        #"\bhow'?s that\b"#, #"\bhow is that\b"#,
        #"\bhow'?s it (going|looking)\b"#,
        #"\bsound(s)? good\b"#, #"\bsound right\b"#,
        #"\bdoes that (work|help|make sense)\b"#,
        #"\bis that (okay|ok|better|alright|all right|good)\b"#,
        #"\bwant me to\b"#, #"\bwould you like me to\b"#, #"\bdo you want me to\b"#,
        #"\blet me know\b"#,
        #"\bhow are you\b"#, #"\bhow was\b"#, #"\bhow did it go\b"#,
        #"\bwhat'?s on your mind\b"#,
        #"\bneed anything\b"#, #"\banything (on your mind|i can help)\b"#,
        #"\bready to\b"#,
        #"\ball good\b"#, #"\beverything (good|okay|ok)\b"#,
        #"\bcan i help\b"#, #"\bhelp with (anything|something)\b"#,
    ]

    /// Approving something that changes or sends things. He must see what he is agreeing to.
    private static let confirmActionPatterns = [
        #"\b(shall|should) i (delete|remove|erase|empty|send|message|text|email|call|run|execute|overwrite|replace|cancel)\b"#,
        #"\bdo you want me to (delete|remove|empty|send|message|text|email|call|run|execute)\b"#,
        #"\bare you sure\b"#,
        #"\bconfirm\b"#,
        #"\b(delete|remove|empty the trash|send it|send this|run this|run that)\b.{0,40}\?"#,
        #"\bgo ahead (and|with)\b"#,
        #"\bthis (cannot|can'?t) be undone\b"#,
        #"\bpermanently\b"#,
    ]

    /// Checking a name, a spelling, or something that may have been misheard. Voice's weakest
    /// point, and the case where seeing the word is the entire value of the card.
    private static let verifyHearingPatterns = [
        #"\bdid you (say|mean)\b"#,
        #"\bdo you mean\b"#, #"\bdid i hear\b"#, #"\bi heard\b"#,
        #"\bhow do you spell\b"#, #"\bspell(ing)?\b"#,
        #"\bis that spelled\b"#,
        #"\bdid you want\b.{0,30}\bor\b"#,
        #"\bwhich one\b"#, #"\bwhich of (these|them)\b"#,
        #"\bthe right (name|spelling)\b"#,
        // "X or Y?" — an explicit either/or is a disambiguation, not chatter.
        #"\b\w+\s+or\s+\w+\?$"#,
    ]

    /// A detail is missing from something being recorded. Getting it wrong writes a wrong
    /// reminder or a wrong calendar entry, so the question belongs on screen.
    private static let missingDetailPatterns = [
        #"\bwhat time\b"#,
        #"\bwhen (should|would|do) you\b"#, #"\bwhen do you want\b"#,
        #"\bwhat (day|date)\b"#, #"\bwhich day\b"#,
        #"\bhow long\b"#,
        #"\bwhat should (i|the)\b.{0,30}\b(call|title|name|be for)\b"#,
        #"\bwhat'?s the (title|name)\b"#,
        #"\bwhat should the .{0,30} (be|say)\b"#,
        #"\bwhat would you like (it|the .{0,20}) to (say|be)\b"#,
        #"\bwho (should|do you want)\b"#,
        #"\bwhere should\b"#,
        #"\bremind you (about|to) what\b"#,
        #"\bwhat (do you want|would you like) to be reminded\b"#,
    ]

    // MARK: - Policy

    private static func matches(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Multi-fact content: a list, or several numbers, or simply long. Read aloud once, it's gone.
    static func isDataWorthReading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Any genuine list — bullets, numbering, or several lines.
        let lines = trimmed.split(whereSeparator: \.isNewline)
        if lines.count >= 3 { return true }
        if trimmed.range(of: #"(^|\n)\s*(\d+[.)]|[-•*])\s+"#, options: .regularExpression) != nil {
            return true
        }
        // An explicit count is ORBIT announcing a list, even when it reads it as prose:
        // "You have 3 reminders: buy tickets at 5 PM, call the bank tomorrow, …".
        if trimmed.range(
            of: #"\b\d+\s+(reminders?|events?|meetings?|appointments?|items?|files?|results?|messages?|emails?|notes?|tasks?|folders?|matches)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        // A spoken series — three or more things separated by commas — is a list without
        // the punctuation of one. Length-gated so ordinary sentences with asides don't match.
        if trimmed.count >= 70, trimmed.filter({ $0 == "," }).count >= 2 { return true }
        // Data-dense readouts (weather, battery, statuses) carry several figures at once.
        let numberMatches = trimmed.ranges(matching: #"\d+"#).count
        if numberMatches >= 3 { return true }
        // A long informational reply is past what anyone holds from one hearing.
        if trimmed.count >= 260 { return true }
        return false
    }

    /// The decision. `pendingChoice` comes from the caller because a pick list or confirmation
    /// lives in app state, not in the words.
    static func reason(
        for reply: String,
        pendingChoice: Bool = false,
        isDisplayOnly: Bool = false
    ) -> Reason? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isDisplayOnly { return .displayOnly }
        // He has to answer with a number or yes/no — the options must be visible.
        if pendingChoice { return .pendingChoice }

        let isQuestion = trimmed.hasSuffix("?")

        // Order matters: a consequential confirmation often reads like a casual offer
        // ("Should I delete it?" contains "should I"), so the costly cases are tested first.
        if matches(trimmed, confirmActionPatterns) { return .confirmAction }
        if matches(trimmed, verifyHearingPatterns) { return .verifyHearing }
        if isQuestion, matches(trimmed, missingDetailPatterns) { return .missingDetail }

        // Plain conversation, including most of ORBIT's questions, gets no card.
        if matches(trimmed, conversationalPatterns) { return nil }

        if isDataWorthReading(trimmed) { return .dataToRead }

        // A question with no other signal is just conversation.
        return nil
    }

    static func shouldShowCard(
        for reply: String,
        pendingChoice: Bool = false,
        isDisplayOnly: Bool = false
    ) -> Bool {
        reason(for: reply, pendingChoice: pendingChoice, isDisplayOnly: isDisplayOnly) != nil
    }

    /// How long the card stays. Anything he must act on outlives anything he only reads.
    static func ttlSeconds(for reason: Reason, replyLength: Int = 0) -> Double {
        switch reason {
        case .pendingChoice, .confirmAction:
            return 180          // he has to decide; don't snatch it away
        case .verifyHearing, .missingDetail:
            return 120          // matches the clarification TTL that was already tuned
        case .dataToRead:
            return replyLength >= 260 ? 90 : 45
        case .displayOnly:
            return 30
        }
    }
}

private extension String {
    func ranges(matching pattern: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start = startIndex
        while let found = range(of: pattern, options: .regularExpression, range: start..<endIndex) {
            out.append(found)
            start = found.upperBound
            if start >= endIndex { break }
        }
        return out
    }
}
