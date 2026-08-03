//
//  OrbitClarificationBroker.swift
//  ORBITMac
//
//  Multi-turn clarification engine — reminder and calendar intent detection.
//  Design: pure logic, no async. Returns what action to take; caller performs it.
//

import Foundation

// MARK: - Public outcome (ContentView+Chat.swift depends on this exact shape)

enum OrbitClarificationOutcome {
    case none
    case ask(String)
    case askWithChips(question: String, chips: [(label: String, reply: String)])
    case createReminder(title: String, dueDate: Date?)
    case listReminders
    case completeReminder(query: String)
    case deleteReminder(query: String)
    case createCalendarEvent(title: String, start: Date, end: Date)
    case createBoth(calendarTitle: String, start: Date, end: Date, reminderTitle: String, reminderDue: Date)
}

// MARK: - Pending state

private struct ReminderDraft {
    var title: String?
    var dueDate: Date?
}

private struct CalendarDraft {
    var title: String?
    var start: Date?
    var durationMinutes: Int = 60
}

private enum PendingIntent {
    case reminderNeedsTitle(draft: ReminderDraft)
    case reminderNeedsTime(draft: ReminderDraft)
    case reminderNeedsBoth
    case calendarNeedsTitle(draft: CalendarDraft)
    case calendarNeedsTime(draft: CalendarDraft)
    case calendarNeedsBoth
    case informationalNeedsAction(title: String?, start: Date?, durationMinutes: Int)
    case needsDestination(title: String, start: Date, end: Date)
}

// MARK: - Broker

@MainActor
final class OrbitClarificationBroker {
    static let shared = OrbitClarificationBroker()
    private init() {}

    private var pending: PendingIntent? {
        didSet { pendingTimestamp = pending != nil ? Date() : nil }
    }
    private var pendingTimestamp: Date?
    private let pendingTTL: TimeInterval = 2 * 60    // 2 min — tighter window to prevent stale confusion
    private let staleTTL: TimeInterval = 90           // after 90s, ask before assuming the user is still on this topic

    private enum PendingState {
        case active(PendingIntent)
        case stale(PendingIntent)
        case expired
    }

    private var pendingState: PendingState {
        guard let p = pending, let ts = pendingTimestamp else { return .expired }
        let elapsed = Date().timeIntervalSince(ts)
        if elapsed > pendingTTL { pending = nil; return .expired }
        if elapsed > staleTTL { return .stale(p) }
        return .active(p)
    }

    /// The last few decisions this broker made, shown in the debug panel.
    ///
    /// Added because a three-turn reminder conversation went wrong twice and the code could not
    /// be read backwards to a single cause: several mechanisms could each produce the observed
    /// behaviour, and guessing between them wasted Ayush's time. This records what actually
    /// happened — the utterance, the pending state at the time, and the outcome — so one
    /// reproduction settles it instead of another theory.
    private(set) static var decisionTrace: [String] = []

    private static func trace(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        decisionTrace.append("\(stamp)  \(line)")
        if decisionTrace.count > 10 {
            decisionTrace.removeFirst(decisionTrace.count - 10)
        }
    }

    static func clearDecisionTrace() { decisionTrace = [] }

    func process(_ text: String) -> OrbitClarificationOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let lower = trimmed.lowercased()

        // Read once: `pendingState` clears `pending` when it finds it expired, so evaluating it
        // twice would report a state the switch below never actually saw.
        let state = pendingState
        let stateLabel: String
        switch state {
        case .active(let p): stateLabel = "pending=active(\(p))"
        case .stale(let p): stateLabel = "pending=STALE(\(p))"
        case .expired: stateLabel = "pending=none/expired"
        }
        Self.trace("in: \u{201C}\(trimmed.prefix(60))\u{201D}  \(stateLabel)")

        switch state {
        case .active(let p):
            let outcome = resolvePending(p, with: trimmed, lower: lower)
            Self.trace("   → resolved pending → \(outcome)")
            return outcome

        case .stale(let p):
            // Pending state is old (90s+). If the user is clearly continuing the
            // conversation (cancel, time, affirmative), resolve it. Otherwise clear
            // and ask if they still want to finish.
            let isContinuation = isCancelOrResolveAttempt(lower, for: p)
            if isContinuation {
                return resolvePending(p, with: trimmed, lower: lower)
            }
            let description = pendingDescription(for: p)
            pending = nil
            return .ask("It\u{2019}s been a moment \u{2014} did you still want to \(description)? Say yes to continue, or just tell me something new.")

        case .expired:
            break
        }

        // Note: listReminders is intentionally NOT handled here — "show my reminders" goes to the
        // brain via the API so the reply is saved to memory and follow-up phrases like
        // "delete that one" can be resolved with conversation context.

        // Delete/remove must be checked BEFORE complete and create — "delete my reminder about X"
        // contains "reminder about" which would otherwise fire isReminderCreateIntent.
        // Never claim an answer to a question this broker did not ask.
        //
        // Reaching here means there is no local pending draft — so if ORBIT's previous turn was a
        // question, the **brain** asked it, and this utterance is the reply. Creating something
        // new from it destroys the conversation: the brain asked "what time on Tuesday?", Ayush
        // answered "remind me today at five PM", the word "remind me" fired the create intent
        // here, and a reminder titled "It" was saved while the brain's actual question went
        // unanswered. An answer belongs to whoever asked.
        if OrbitVoiceSession.shared.lastReplyWasQuestion {
            Self.trace("   → deferring to brain: answering ORBIT's own question")
            return .none
        }

        let outcome: OrbitClarificationOutcome
        if isReminderDeleteIntent(lower)              { outcome = .deleteReminder(query: extractDeleteReminderQuery(from: trimmed)) }
        else if isReminderCompleteIntent(lower)       { outcome = .completeReminder(query: extractCompleteQuery(from: trimmed)) }
        else if isReminderCreateIntent(lower)         { outcome = handleReminderCreate(trimmed, lower: lower) }
        else if isCalendarCreateIntent(lower)         { outcome = handleCalendarCreate(trimmed, lower: lower) }
        else if isCalendarInformationalIntent(lower)  { outcome = handleCalendarInformational(trimmed, lower: lower) }
        else                                          { outcome = .none }
        Self.trace("   → fresh intent → \(outcome)")
        return outcome
    }

    func clearPending() {
        if pending != nil { Self.trace("   ⚠︎ pending CLEARED by \(#function) caller") }
        pending = nil
    }

    private func isCancelOrResolveAttempt(_ lower: String, for state: PendingIntent) -> Bool {
        let cancels = ["cancel", "no", "nope", "skip", "stop", "nevermind", "never mind"]
        if cancels.contains(where: { lower == $0 || lower.hasPrefix($0) }) { return true }
        // Time expressions suggest the user is answering "when?"
        if lower.range(of: #"\b\d{1,2}\s*(am|pm)\b"#, options: .regularExpression) != nil { return true }
        if lower.contains("tomorrow") || lower.contains("today") || lower.contains("tonight")
            || lower.contains("morning") || lower.contains("afternoon") || lower.contains("evening") { return true }
        // Affirmative responses
        if ["yes", "yeah", "yep", "sure", "ok", "okay",
            "yes please", "sure thing", "please do", "please", "go ahead"].contains(lower) { return true }
        // Number picks for constellation
        if lower.range(of: #"^\d$"#, options: .regularExpression) != nil { return true }
        if lower.hasPrefix("open ") { return true }
        // Calendar/reminder keywords match the pending context
        if lower.contains("calendar") || lower.contains("reminder") { return true }
        return false
    }

    private func pendingDescription(for state: PendingIntent) -> String {
        switch state {
        case .reminderNeedsBoth: return "set that reminder"
        case .reminderNeedsTime(let d): return "set a reminder\(d.title.map { " about \u{201C}\($0)\u{201D}" } ?? "")"
        case .reminderNeedsTitle: return "finish setting up that reminder"
        case .calendarNeedsBoth: return "schedule that event"
        case .calendarNeedsTime(let d): return "schedule \(d.title.map { "\u{201C}\($0)\u{201D}" } ?? "that event")"
        case .calendarNeedsTitle: return "set up that calendar event"
        case .informationalNeedsAction: return "add that to your calendar or reminders"
        case .needsDestination: return "save that event"
        }
    }

    // MARK: - Intent detection

    private func isReminderCreateIntent(_ lower: String) -> Bool {
        // Negative guard: delete/remove/cancel before a reminder keyword → not a create intent.
        if lower.range(of: #"\b(delete|remove|cancel|clear|get rid of)\b.{0,20}\breminder\b"#,
                       options: .regularExpression) != nil { return false }
        let triggers = [
            "remind me",
            "reminder to", "reminder for", "reminder about",
            "set a reminder", "set me a reminder", "set up a reminder",
            "create a reminder", "add a reminder", "schedule a reminder",
            "put a reminder", "new reminder", "add reminder",
            "don't forget", "dont forget",
            "don't let me forget", "dont let me forget",
            "can you remind", "could you remind", "please remind me",
            "remember to", "remember that", "i need to remember", "i should remember",
            // Note: "take a note", "note to self", "jot down", "write down" are routed to Apple Notes,
            // not reminders — handled by isNotesCreateIntent in performIfCommand (runs first).
        ]
        return triggers.contains { lower.contains($0) }
    }

    private func isReminderDeleteIntent(_ lower: String) -> Bool {
        let triggers = [
            "delete my reminder", "delete reminder",
            "remove my reminder", "remove reminder",
            "cancel my reminder", "cancel reminder",
            "clear my reminder", "clear reminder",
            "get rid of my reminder", "get rid of reminder",
        ]
        let patternMatch = triggers.contains(where: { lower.contains($0) })
            || lower.range(of: #"\b(delete|remove|cancel|clear)\b.{0,20}\breminder\b"#,
                           options: .regularExpression) != nil
        guard patternMatch else { return false }
        // Only handle when we can extract a meaningful title — not when the user said
        // something like "can you please delete that reminder" where the extraction
        // yields back the whole sentence. Those contextual cases go to the brain.
        let extracted = extractDeleteReminderQuery(from: lower)
        return extracted.lowercased() != lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractDeleteReminderQuery(from text: String) -> String {
        var s = text.lowercased()
        let prefixes = [
            "delete my reminder about", "delete my reminder for", "delete my reminder to", "delete my reminder",
            "remove my reminder about", "remove my reminder for", "remove my reminder to", "remove my reminder",
            "cancel my reminder about", "cancel my reminder for", "cancel my reminder to", "cancel my reminder",
            "delete reminder about", "delete reminder for", "delete reminder to", "delete reminder",
            "remove reminder about", "remove reminder for", "remove reminder to", "remove reminder",
            "cancel reminder about", "cancel reminder for", "cancel reminder to", "cancel reminder",
            "clear my reminder about", "clear my reminder", "get rid of my reminder about", "get rid of my reminder",
        ].sorted { $0.count > $1.count }
        for prefix in prefixes where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        guard let first = s.first, !s.isEmpty else { return text }
        return first.uppercased() + s.dropFirst()
    }

    private func isCalendarListIntent(_ lower: String) -> Bool {
        // Use specific multi-word phrases only — "my calendar" alone is too broad
        // (would fire on "add to my calendar" in response to a pending create).
        let triggers = [
            "my calendar events", "my events", "my upcoming",
            "what's on", "what is on", "upcoming events", "calendar events",
        ]
        return triggers.contains(where: { lower.contains($0) })
    }

    private func isReminderListIntent(_ lower: String) -> Bool {
        let triggers = [
            "my reminders", "list reminders", "show reminders", "view reminders",
            "what reminders", "any reminders", "pending reminders", "check reminders",
            "all reminders", "show me reminders", "see my reminders",
        ]
        if triggers.contains(where: { lower.contains($0) }) { return true }
        return lower.range(of: #"\b(show|list|what are|see|check|view)\b.{0,15}\breminders?\b"#,
                           options: .regularExpression) != nil
    }

    private func isReminderCompleteIntent(_ lower: String) -> Bool {
        let triggers = [
            "mark reminder", "complete reminder", "finish reminder",
            "done with reminder", "mark as done", "mark as complete", "mark as finished",
            "mark done", "mark down", "marked done",           // "mark down" = STT mishear of "mark done"
            "mark off reminder", "check off reminder",
            "tick off reminder", "mark it as done", "mark it done",
        ]
        let patternMatch = triggers.contains(where: { lower.contains($0) })
            || lower.range(of: #"\b(mark|complete|finish|done with)\b.{0,25}\breminder\b"#,
                           options: .regularExpression) != nil
        guard patternMatch else { return false }
        // Must be able to extract a title OR a pronoun (pronoun resolution happens in completeReminder).
        let extracted = extractCompleteQuery(from: lower)
        return extracted.lowercased() != lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCalendarCreateIntent(_ lower: String) -> Bool {
        // Vague person references → let brain ask "who are you meeting with?"
        let vagueRefs = ["with someone", "with somebody", "with a friend", "with a person", "with some friend"]
        if vagueRefs.contains(where: { lower.contains($0) }) { return false }

        // Negative guard: question/list phrases → user is querying events, not creating one.
        let listStarters = [
            "what are my", "what's on my", "what is on my", "show me my",
            "list my", "do i have any", "do i have", "show my", "view my",
            "see my", "check my", "any upcoming", "what do i have",
        ]
        if listStarters.contains(where: { lower.hasPrefix($0) }) { return false }

        let triggers = [
            "add to my calendar", "add to the calendar", "add to calendar",
            "put on my calendar", "put on the calendar", "put on calendar",
            "schedule a meeting", "schedule a call", "schedule an event", "schedule an appointment",
            "book a meeting", "book a call", "book an appointment",
            "create a meeting", "create an event", "create a calendar event",
            "add a meeting", "add an event", "add a calendar event",
            "set up a meeting", "set up a call",
            "calendar event", "calendar entry", "block time",
        ]
        if triggers.contains(where: { lower.contains($0) }) { return true }
        return lower.range(of:
            #"\b(schedule|book|add|create|set up)\b.{0,20}\b(meeting|event|appointment|call|standup|sync|interview|session|presentation|demo)\b"#,
            options: .regularExpression) != nil
    }

    private func isCalendarInformationalIntent(_ lower: String) -> Bool {
        // Vague person references mean the title is too uncertain to act on.
        // Let the brain ask naturally ("Who are you meeting with?").
        let vagueRefs = ["with someone", "with somebody", "with a friend", "with a person", "with some friend"]
        if vagueRefs.contains(where: { lower.contains($0) }) { return false }

        let triggers = [
            "i have a meeting", "i have a call", "i have an appointment",
            "i have a standup", "i have a sync", "i have an interview",
            "i'm meeting", "i am meeting",
            "i'm having a meeting", "i am having a meeting",
            "we have a meeting", "we have a call",
            // Natural task expressions: "I need to call mom at 6", "I have to meet John at 3"
            "i need to call", "i need to meet", "i need to talk to", "i need to speak to",
            "i have to call", "i have to meet", "i want to call", "i want to meet",
            // Natural variants without "I have"
            "i've got a meeting", "i got a meeting", "got a meeting",
            "i've got a call", "got a call",
            "phone call with", "video call with",
            "catch up with", "catch-up with",
        ]
        if triggers.contains(where: { lower.contains($0) }) { return true }
        // Direct event-type expressions: "meeting with X", "standup with the team", etc.
        // No verb required — the event-type word itself is sufficient signal.
        if lower.range(of: #"\b(meeting|standup|stand-up|interview|demo|session|appointment|sync|presentation|call)\s+with\b"#,
                       options: .regularExpression) != nil { return true }
        // Social/work events with a person: "lunch with Priya", "coffee with John at 3"
        if lower.range(of: #"\b(lunch|coffee|dinner|breakfast|drinks|brunch|catch up|catch-up|catchup)\s+with\b"#,
                       options: .regularExpression) != nil { return true }
        // Bare "meeting at/tomorrow/tonight/..." without "I have" preamble
        if lower.range(of: #"\b(meeting|standup|interview|presentation|demo|appointment|sync)\s+(at|on|tomorrow|today|tonight|this|next|in)\b"#,
                       options: .regularExpression) != nil { return true }
        // "I need/have to [action] at [time]" — generic task-at-time pattern
        return lower.range(of: #"\bi (need|have|want) to\b.{2,30}\bat\b"#, options: .regularExpression) != nil
    }

    // MARK: - Handlers

    private func handleReminderCreate(_ text: String, lower: String) -> OrbitClarificationOutcome {
        let (title, date) = parseReminderComponents(from: text)

        // If nothing was extracted — title equals the whole input — the user said something like
        // "I want you to set a reminder" with no topic. Let the brain ask naturally.
        if let t = title, t.lowercased() == lower.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .none
        }

        // The exact-equality test above is too literal to be a real safety net: removing one date
        // word is enough to pass it while extraction has plainly failed. If the "title" still
        // contains the words that *asked* for the reminder, this parser did not understand the
        // sentence — hand it to the brain rather than saving the request as if it were the task.
        if let t = title, OrbitUtteranceCleanup.looksLikeUnextractedRequest(t) {
            pending = nil
            return .none
        }

        // "It", "8", "Today, August 2" — all real titles ORBIT saved. Whatever survived the date
        // removal was not a task, so this parser has nothing worth acting on.
        if let t = title, OrbitUtteranceCleanup.isTooThinToBeATask(t) {
            Self.trace("   → title \u{201C}\(t)\u{201D} is not a task; deferring to brain")
            pending = nil
            return .none
        }

        // ── The fast lane: simple, complete, unambiguous. Handled locally and instantly. ──
        //
        // A bare day ("Tuesday") carries no clock time, but NSDataDetector fills in 12:00 with no
        // way to tell an inferred noon from a spoken one — so an explicit time is required here,
        // not just any parsed date.
        if let t = title, !t.isEmpty, let d = date, OrbitUtteranceCleanup.hasExplicitClockTime(text) {
            let adjusted = isPast(d) ? (Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d) : d
            pending = nil
            return .createReminder(title: t, dueDate: adjusted)
        }

        // ── Anything else goes to the brain. ──
        //
        // This used to start a local clarification state machine, and that is what broke the
        // "buy tickets for Spider-Man" conversation twice. The draft lived in a 2-minute
        // `pendingTTL`; Ayush took longer than that to answer, the draft expired, and his reply
        // ("remind me today at five PM") was re-parsed as a brand-new reminder — which is why
        // ORBIT then asked what the reminder should be *for* and lost the title entirely.
        //
        // Widening the timeout would only move the cliff. The real problem is that a regex state
        // machine holding a draft in a variable is the wrong tool for a multi-turn conversation:
        // the brain already keeps the whole exchange, so a follow-up answer resolves naturally
        // with no timer to expire and no draft to lose.
        //
        // So: local handles what is simple and complete; the moment a question is needed, the
        // brain owns the whole interaction. (Agreed with Ayush 2026-08-02.)
        pending = nil
        return .none
    }

    private func handleCalendarCreate(_ text: String, lower: String) -> OrbitClarificationOutcome {
        let (rawTitle, start) = parseCalendarComponents(from: text)
        let dur = inferDuration(from: lower)

        // If nothing was extracted — title equals the whole input — the user said something like
        // "I want to add a new event in calendar" with no topic. Let the brain handle it.
        if let t = rawTitle, t.lowercased() == lower.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .none
        }

        // Preserve "Meeting with X" when the user said "schedule a meeting with Priya"
        // but cleanCalendarTitle stripped the "meeting with" prefix.
        let title = preserveWithPerson(rawTitle: rawTitle, originalLower: lower)

        // Time range: "meeting from 2 to 4" → explicit start and end
        if let range = extractTimeRange(from: text), let t = title, !t.isEmpty {
            pending = nil
            return .createCalendarEvent(title: t, start: range.start, end: range.end)
        }

        // Extraction failed if the "title" is still the request, or is not a thing at all.
        if let t = title, OrbitUtteranceCleanup.looksLikeUnextractedEventRequest(t) {
            Self.trace("   → event title \u{201C}\(t)\u{201D} is still the request; deferring to brain")
            pending = nil
            return .none
        }
        if let t = title, OrbitUtteranceCleanup.isTooThinToBeATask(t) {
            Self.trace("   → event title \u{201C}\(t)\u{201D} is not an event; deferring to brain")
            pending = nil
            return .none
        }

        // ── Fast lane: a real title and a time the user actually spoke. ──
        // An event with a guessed hour is worse than a question, and NSDataDetector turns a bare
        // "Thursday" into 12:00 with no way to tell that noon was inferred.
        if let t = title, !t.isEmpty, let s = start, OrbitUtteranceCleanup.hasExplicitClockTime(text) {
            let adj = isPast(s) ? (Calendar.current.date(byAdding: .day, value: 1, to: s) ?? s) : s
            pending = nil
            return .createCalendarEvent(title: t, start: adj, end: adj.addingTimeInterval(Double(dur) * 60))
        }

        // ── Everything else to the brain. ──
        // The local `.ask` branches used to live here and held a CalendarDraft across turns, which
        // is the same design that lost the reminder title mid-conversation. The brain keeps the
        // whole exchange, so its follow-up question actually resolves. (Phase 3.11 rule.)
        pending = nil
        return .none
    }

    private func handleCalendarInformational(_ text: String, lower: String) -> OrbitClarificationOutcome {
        let dur = inferDuration(from: lower)

        // Strong calendar keywords (meeting, standup, interview…) — these are unambiguously
        // calendar events, so create the event directly instead of asking Calendar/Reminder.
        if isClearCalendarOnlyIntent(lower) {
            let titleRaw = cleanCalendarTitleFromInformational(text)
            let title = titleRaw.isEmpty ? "Meeting" : titleRaw
            let start = extractDate(from: text)
            // Time range: "meeting from 2 to 4" → explicit start and end
            if let range = extractTimeRange(from: text) {
                pending = nil
                return .createCalendarEvent(title: title, start: range.start, end: range.end)
            }
            // A spoken clock time is required here too. "Meeting with Priya on Thursday" has no
            // hour in it; NSDataDetector supplies noon, and an event booked at a guessed time is
            // worse than a question.
            if let s = start, OrbitUtteranceCleanup.hasExplicitClockTime(text) {
                let adj = isPast(s) ? (Calendar.current.date(byAdding: .day, value: 1, to: s) ?? s) : s
                let endDate = adj.addingTimeInterval(Double(dur) * 60)
                pending = nil
                return .createCalendarEvent(title: title, start: adj, end: endDate)
            }
            Self.trace("   → event has no spoken time; deferring to brain")
            pending = nil
            return .none
        }

        // Ambiguous intent (e.g. "I need to call mom at 6") → show chips
        let (title, start) = parseCalendarComponents(from: text)
        pending = .informationalNeedsAction(title: title, start: start, durationMinutes: dur)
        let what: String
        if let t = title, let s = start { what = "\u{201C}\(t)\u{201D} at \(Self.formatEventStart(s))" }
        else if let t = title            { what = "\u{201C}\(t)\u{201D}" }
        else if let s = start            { what = "the event at \(Self.formatEventStart(s))" }
        else                             { what = "that" }
        return .askWithChips(
            question: "Got it \u{2014} \(what). What would you like to do?",
            chips: [
                (label: "Calendar Event", reply: "add to calendar"),
                (label: "Reminder",       reply: "set a reminder"),
                (label: "Skip",           reply: "skip"),
            ]
        )
    }

    // MARK: - Resolve pending

    private func resolvePending(_ state: PendingIntent, with text: String, lower: String) -> OrbitClarificationOutcome {
        // User started a new intent — clear and re-process fresh
        if isReminderListIntent(lower) || isReminderCompleteIntent(lower)
            || isReminderCreateIntent(lower) || isCalendarCreateIntent(lower)
            || isCalendarInformationalIntent(lower) || isCalendarListIntent(lower)
        {
            pending = nil
            return process(text)
        }

        // System-action verb at the start → this is a new system command, not a pending response.
        // Clear pending and return .none so performIfCommand (called before the broker) can handle it.
        // Without this guard, "close calendar" with an active pending would fire wantsCalendar=true
        // and accidentally create a calendar event instead of quitting the Calendar app.
        let systemVerbPrefixes = ["close ", "quit ", "open ", "launch ", "start ", "exit ", "kill "]
        if systemVerbPrefixes.contains(where: { lower.hasPrefix($0) }) {
            pending = nil
            return .none
        }

        // Explicit cancel (exact words only — don't swallow "no, at 3pm instead")
        let exactCancels: Set<String> = ["cancel", "no", "nope", "nothing", "skip", "stop", "nevermind"]
        let prefixCancels = ["never mind", "forget it", "no thanks", "cancel that", "skip that"]
        if exactCancels.contains(lower)
            || prefixCancels.contains(where: { lower.hasPrefix($0) })
        {
            pending = nil
            return .ask("No problem.")
        }

        switch state {

        // MARK: Reminder resolution

        case .reminderNeedsBoth:
            let (title, date) = parseReminderComponents(from: text)
            if let t = title, !t.isEmpty, let d = date {
                let adjusted = isPast(d) ? (Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d) : d
                pending = nil
                return .createReminder(title: t, dueDate: adjusted)
            }
            if let t = title, !t.isEmpty {
                pending = .reminderNeedsTime(draft: ReminderDraft(title: t, dueDate: nil))
                return .ask("When should I remind you about \u{201C}\(t)\u{201D}?")
            }
            if let d = date {
                pending = .reminderNeedsTitle(draft: ReminderDraft(title: nil, dueDate: d))
                return .ask("What should the reminder be for?")
            }
            return .ask("What would you like to be reminded about, and when?")

        case .reminderNeedsTime(let draft):
            if let date = extractDate(from: text) {
                var resolved = date
                // When the day is already settled ("Tuesday") and the answer only supplies a
                // clock time, graft that time onto the known day — otherwise a bare "3 PM"
                // silently means *today* and the reminder lands on the wrong date.
                if let knownDay = draft.dueDate, !OrbitUtteranceCleanup.mentionsExplicitDay(text) {
                    let cal = Calendar.current
                    let time = cal.dateComponents([.hour, .minute], from: date)
                    if let combined = cal.date(
                        bySettingHour: time.hour ?? 9,
                        minute: time.minute ?? 0,
                        second: 0,
                        of: knownDay
                    ) {
                        resolved = combined
                    }
                }
                let adjusted = isPast(resolved) ? (Calendar.current.date(byAdding: .day, value: 1, to: resolved) ?? resolved) : resolved
                pending = nil
                return .createReminder(title: draft.title ?? "Reminder", dueDate: adjusted)
            }
            return .ask("I didn\u{2019}t catch a time. When should I remind you? (e.g. \u{201C}tomorrow at 3 PM\u{201D})")

        case .reminderNeedsTitle(let draft):
            let title = cleanAsTitle(text)
            pending = nil
            return .createReminder(title: title.isEmpty ? "Reminder" : title, dueDate: draft.dueDate)

        // MARK: Calendar resolution

        case .calendarNeedsBoth:
            let (title, start) = parseCalendarComponents(from: text)
            let dur = extractDurationMinutes(from: lower) ?? 60
            if let t = title, !t.isEmpty, let s = start {
                pending = nil
                return .createCalendarEvent(title: t, start: s, end: s.addingTimeInterval(Double(dur) * 60))
            }
            if let t = title, !t.isEmpty {
                pending = .calendarNeedsTime(draft: CalendarDraft(title: t, start: nil, durationMinutes: dur))
                return .ask("When should I schedule \u{201C}\(t)\u{201D}?")
            }
            if let s = start {
                pending = .calendarNeedsTitle(draft: CalendarDraft(title: nil, start: s, durationMinutes: dur))
                return .ask("What should I call the event?")
            }
            return .ask("What would you like to schedule, and when?")

        case .calendarNeedsTime(let draft):
            if let start = extractDate(from: text) {
                pending = nil
                let dur = extractDurationMinutes(from: lower) ?? draft.durationMinutes
                return .createCalendarEvent(
                    title: draft.title ?? "Event",
                    start: start,
                    end: start.addingTimeInterval(Double(dur) * 60)
                )
            }
            return .ask("I didn\u{2019}t catch a time. When should I schedule it? (e.g. \u{201C}tomorrow at 2 PM\u{201D})")

        case .calendarNeedsTitle(let draft):
            let title = cleanCalendarTitle(text)
            pending = nil
            let s = draft.start ?? Date().addingTimeInterval(3600)
            return .createCalendarEvent(
                title: title.isEmpty ? "Event" : title,
                start: s,
                end: s.addingTimeInterval(Double(draft.durationMinutes) * 60)
            )

        // MARK: Informational ("I have a meeting at 3") resolution

        case .informationalNeedsAction(let title, let start, let dur):
            let effectiveStart = start ?? extractDate(from: text)
            let chosenTitle = title ?? "Event"

            // Constellation number picks: "1" → calendar, "2" → reminder, "3" → skip
            let pickNum: Int? = {
                if lower == "1" || lower == "open 1" { return 1 }
                if lower == "2" || lower == "open 2" { return 2 }
                if lower == "3" || lower == "open 3" { return 3 }
                return nil
            }()
            if let pick = pickNum {
                switch pick {
                case 1:
                    if let s = effectiveStart {
                        pending = nil
                        let adj = isPast(s) ? (Calendar.current.date(byAdding: .day, value: 1, to: s) ?? s) : s
                        return .createCalendarEvent(title: chosenTitle, start: adj, end: adj.addingTimeInterval(Double(dur) * 60))
                    }
                    pending = .calendarNeedsTime(draft: CalendarDraft(title: title, start: nil, durationMinutes: dur))
                    return .ask("When should I schedule \u{201C}\(chosenTitle)\u{201D}?")
                case 2:
                    pending = nil
                    return .createReminder(title: title ?? "Reminder", dueDate: effectiveStart)
                default:
                    pending = nil
                    return .ask("Got it, I won\u{2019}t add anything.")
                }
            }

            let noWords = ["no", "nope", "skip", "nothing", "neither", "cancel", "never mind", "nevermind", "no thanks"]
            if noWords.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
                pending = nil
                return .ask("Got it, I won\u{2019}t add anything.")
            }
            let hasSystemVerb = ["close", "quit", "open", "launch", "exit", "kill"]
                .contains { lower.hasPrefix($0 + " ") }
            let wantsCalendar = !hasSystemVerb && (lower.contains("calendar") || lower.contains("event")
                || lower.contains("schedule") || lower.contains("add"))
            let wantsReminder = lower.contains("reminder") || lower.contains("remind")
            let affirmative = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay",
                               "go ahead", "add it", "do it", "great", "sounds good", "please"]
            let isAffirmative = affirmative.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") })

            if wantsReminder && !wantsCalendar {
                pending = nil
                return .createReminder(title: title ?? "Reminder", dueDate: effectiveStart)
            }
            if wantsCalendar || isAffirmative {
                pending = nil
                if let s = effectiveStart {
                    let adjusted = isPast(s) ? (Calendar.current.date(byAdding: .day, value: 1, to: s) ?? s) : s
                    return .createCalendarEvent(
                        title: chosenTitle,
                        start: adjusted,
                        end: adjusted.addingTimeInterval(Double(dur) * 60)
                    )
                }
                pending = .calendarNeedsTime(draft: CalendarDraft(title: chosenTitle, start: nil, durationMinutes: dur))
                return .ask("When should I schedule \u{201C}\(chosenTitle)\u{201D}?")
            }
            let tStr = title.map { "\u{201C}\($0)\u{201D}" } ?? "it"
            return .ask("For \(tStr) \u{2014} add a calendar event, set a reminder, or skip?")

        // MARK: Calendar-vs-Reminder destination

        case .needsDestination(let title, let start, let end):
            let noWords: Set<String> = ["no", "nope", "skip", "nothing", "neither", "cancel", "never mind", "nevermind"]
            if noWords.contains(lower) || lower == "4" { pending = nil; return .ask("Got it, I won\u{2019}t add anything.") }

            let wantsBoth    = lower.contains("both") || lower == "3"
            let wantsRemind  = (lower.contains("reminder") || lower.contains("remind")) && !lower.contains("calendar")
            let wantsCal     = lower.contains("calendar") || lower.contains("event") || lower.contains("schedule") || lower == "1"
            let wantsReminderOnly = lower == "2" || (lower.contains("reminder") && !wantsBoth)

            if wantsBoth {
                pending = nil
                return .createBoth(calendarTitle: title, start: start, end: end, reminderTitle: title, reminderDue: start)
            }
            if wantsReminderOnly || (wantsRemind && !wantsCal) {
                pending = nil
                return .createReminder(title: title, dueDate: start)
            }
            if wantsCal {
                pending = nil
                return .createCalendarEvent(title: title, start: start, end: end)
            }
            return .ask("Add \u{201C}\(title)\u{201D} to Calendar, Reminders, both, or skip?")
        }
    }

    // MARK: - Complete query extraction

    private func extractCompleteQuery(from text: String) -> String {
        let lower = text.lowercased()

        // Strip verbal preambles so patterns match regardless of politeness prefix.
        var core = lower
        let preambles = [
            "can you please ", "could you please ", "please can you ", "please could you ",
            "would you please ", "please ", "can you ", "could you ",
        ]
        for pre in preambles where core.hasPrefix(pre) {
            core = String(core.dropFirst(pre.count))
            break
        }

        // "mark [title] as done/complete/finished" — e.g. "mark it as done", "mark email disa as complete"
        if let match = core.range(of: #"mark\s+(.+?)\s+as\s+(done|complete|finished)"#, options: .regularExpression) {
            let inner = core[match]
            if let s = inner.range(of: "mark "), let e = inner.range(of: " as ") {
                return String(inner[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // "mark [title] done" (no "as") — e.g. "mark it done", "mark email disa done"
        // This extracts the title/pronoun cleanly so "mark it done" → "it" (not "it done").
        if core.hasPrefix("mark "), core.hasSuffix(" done") {
            let inner = core.dropFirst("mark ".count).dropLast(" done".count)
            let extracted = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty { return extracted }
        }

        // "mark done/down/dunn [the/my] [reminder] [title]"
        // "mark down" and "mark dunn" are common STT mishearings of "mark done".
        for variant in ["mark done ", "mark down ", "mark dunn ", "mark off ", "marked done "] where core.hasPrefix(variant) {
            var rest = String(core.dropFirst(variant.count))
            for noise in ["the reminder ", "my reminder ", "reminder ", "the ", "my "] where rest.hasPrefix(noise) {
                rest = String(rest.dropFirst(noise.count))
                break
            }
            if !rest.isEmpty { return rest.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        // Original prefix-based extraction (now applied to preamble-stripped core).
        let prefixes = ["mark ", "complete ", "finish ", "done with ", "i've done ", "i have done ", "i've finished "]
        for p in prefixes where core.hasPrefix(p) {
            return String(core.dropFirst(p.count))
                .replacingOccurrences(of: " as done", with: "")
                .replacingOccurrences(of: " as complete", with: "")
                .replacingOccurrences(of: " reminder", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Reminder component parsing

    func parseReminderComponents(from text: String) -> (title: String?, dueDate: Date?) {
        // Disfluencies first: prefix stripping below is anchored at position 0, so a leading
        // "Um, " silently defeated all ~90 request-framing prefixes and left the whole raw
        // sentence as the reminder title.
        let deFilled = OrbitUtteranceCleanup.stripDisfluencies(text)
        let resolved = OrbitMacControlCenter.resolveSpokenNumbers(in: deFilled)
        let date = extractDate(from: resolved)
        var titleText = resolved
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(resolved.startIndex..., in: resolved)
            let matches = detector.matches(in: resolved, range: range)
            for match in matches.sorted(by: { $0.range.length > $1.range.length }) {
                if let r = Range(match.range, in: titleText) {
                    titleText = titleText.replacingCharacters(in: r, with: " ")
                }
            }
        }
        titleText = cleanAsTitle(titleText)
        return (titleText.isEmpty ? nil : titleText, date)
    }

    // MARK: - Calendar component parsing

    private func parseCalendarComponents(from text: String) -> (title: String?, start: Date?) {
        // Same reason as the reminder parser: `cleanCalendarTitle` strips its prefixes with
        // `hasPrefix`, so a leading "Um, " defeats every one of them and the raw sentence becomes
        // the event name.
        let deFilled = OrbitUtteranceCleanup.stripDisfluencies(text)
        let resolved = OrbitMacControlCenter.resolveSpokenNumbers(in: deFilled)
        let start = extractDate(from: resolved)
        var titleText = resolved
        let durationPat = #"\b\d+[\s-]*(hour|hr|minute|min)s?\b|\bhalf[\s-]hour\b|\b(one|two|three|four|five|six|an) (hour|hr|minute|min)s?\b"#
        titleText = titleText.replacingOccurrences(of: durationPat, with: " ", options: .regularExpression)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(resolved.startIndex..., in: resolved)
            let matches = detector.matches(in: resolved, range: range)
            for match in matches.sorted(by: { $0.range.length > $1.range.length }) {
                if let r = Range(match.range, in: titleText) {
                    titleText = titleText.replacingCharacters(in: r, with: " ")
                }
            }
        }
        let title = cleanCalendarTitle(titleText)
        return (title.isEmpty ? nil : title, start)
    }

    // MARK: - Date extraction

    func extractDate(from text: String) -> Date? {
        let lower = text.lowercased()
        let now = Date()
        let cal = Calendar.current

        // Resolve spoken numbers so "at three" is treated identically to "at 3".
        let lowerResolved = OrbitMacControlCenter.resolveSpokenNumbers(in: lower)

        // Pre-process relative/named-time expressions that NSDataDetector misses.
        // Use lowerResolved so "at three" counts as an explicit clock time — preventing
        // "tonight" from overriding the specific hour in "meeting tonight at three".
        let hasClockTime = lowerResolved.range(
            of: #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b|\bat\s+\d{1,2}\b"#,
            options: .regularExpression) != nil

        if !hasClockTime {
            func todayAt(_ h: Int, _ m: Int = 0) -> Date? {
                var c = cal.dateComponents([.year, .month, .day], from: now)
                c.hour = h; c.minute = m; c.second = 0
                return cal.date(from: c)
            }
            func tomorrowAt(_ h: Int, _ m: Int = 0) -> Date? {
                guard let d = cal.date(byAdding: .day, value: 1, to: now) else { return nil }
                var c = cal.dateComponents([.year, .month, .day], from: d)
                c.hour = h; c.minute = m; c.second = 0
                return cal.date(from: c)
            }
            // "in N minutes" / "in N hours"
            if let m = lower.range(of: #"\bin (\d+) minutes?\b"#, options: .regularExpression) {
                if let mins = Int(lower[m].filter { $0.isNumber }), mins > 0 {
                    return now.addingTimeInterval(Double(mins) * 60)
                }
            }
            if lower.range(of: #"\bin half an hour\b"#, options: .regularExpression) != nil {
                return now.addingTimeInterval(30 * 60)
            }
            if lower.range(of: #"\bin an? hour\b"#, options: .regularExpression) != nil {
                return now.addingTimeInterval(3600)
            }
            if let m = lower.range(of: #"\bin (\d+) hours?\b"#, options: .regularExpression) {
                if let hrs = Int(lower[m].filter { $0.isNumber }), hrs > 0 {
                    return now.addingTimeInterval(Double(hrs) * 3600)
                }
            }
            // Named time-of-day slots
            if lower.contains("tonight") || lower.contains("this evening") {
                if let t = todayAt(19), t > now { return t }
                return tomorrowAt(19)
            }
            if lower.contains("lunchtime") || (lower.contains("at lunch") && !lower.contains("after lunch")) {
                if let t = todayAt(12), t > now { return t }
                return tomorrowAt(12)
            }
            if lower.contains("end of day") || lower.contains("end of the day")
                || lower.hasSuffix(" eod") || lower == "eod" {
                if let t = todayAt(17), t > now { return t }
                return tomorrowAt(17)
            }
            if lower.contains("first thing tomorrow") { return tomorrowAt(9) }
            if lower.contains("first thing") {
                if let t = todayAt(9), t > now { return t }
                return tomorrowAt(9)
            }
        }

        // Canonicalise "weekend" phrases before NSDataDetector sees them
        var input = text
        let weekendReplacements: [(String, String)] = [
            (#"\bthis\s+weekend\b"#,   "this Saturday"),
            (#"\bnext\s+weekend\b"#,   "next Saturday"),
            (#"\bon\s+the\s+weekend\b"#, "this Saturday"),
            (#"\bthe\s+weekend\b"#,    "this Saturday"),
        ]
        for (pat, repl) in weekendReplacements {
            input = input.replacingOccurrences(of: pat, with: repl,
                                               options: [.regularExpression, .caseInsensitive])
        }
        let resolved = OrbitMacControlCenter.resolveSpokenNumbers(in: input)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(resolved.startIndex..., in: resolved)
        let hasAmPm = lower.range(of: #"\b(am|pm|a\.m\.|p\.m\.|morning|afternoon|evening|night|noon|midnight)\b"#,
                                   options: .regularExpression) != nil

        if let match = detector.firstMatch(in: resolved, range: range), let date = match.date {
            // AM/PM disambiguation: bare hours 1–6 with no explicit AM/PM marker → assume PM
            if !hasAmPm {
                let hour = cal.component(.hour, from: date)
                if hour >= 1 && hour <= 6 {
                    return cal.date(byAdding: .hour, value: 12, to: date)
                }
            }
            return date
        }

        // NSDataDetector found nothing — regex fallback for bare "at H" or "at H:MM".
        // NSDataDetector needs explicit AM/PM or day context; this covers the rest.
        if let atRange = lowerResolved.range(of: #"\bat\s+(\d{1,2})(?::(\d{2}))?\b"#, options: .regularExpression) {
            let sub = String(lowerResolved[atRange])
                .replacingOccurrences(of: #"^at\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let parts = sub.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if let hour = Int(parts[0]), hour >= 0, hour <= 23 {
                let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                var c = cal.dateComponents([.year, .month, .day], from: now)
                let finalHour = (!hasAmPm && hour >= 1 && hour <= 6) ? hour + 12 : hour
                c.hour = finalHour; c.minute = minute; c.second = 0
                if let d = cal.date(from: c) { return d }
            }
        }
        return nil
    }

    func isPast(_ date: Date) -> Bool { date.timeIntervalSinceNow < -60 }

    // MARK: - Duration extraction

    func extractDurationMinutes(from text: String) -> Int? {
        let lower = text.lowercased()
        if lower.range(of: #"\bhalf[\s-]hour\b"#, options: .regularExpression) != nil { return 30 }
        if lower.range(of: #"\ban\s+hours?\b"#, options: .regularExpression) != nil { return 60 }
        if let m = lower.range(of: #"(\d+)[\s-]*(hours?|hrs?)"#, options: .regularExpression) {
            let token = lower[m]
            if let n = Int(token.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { return n * 60 }
        }
        let wordHours = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
        for (word, n) in wordHours where lower.range(of: "\(word)[- ]hours?", options: .regularExpression) != nil { return n * 60 }
        if let m = lower.range(of: #"(\d+)[\s-]*(minutes?|mins?)"#, options: .regularExpression) {
            let token = lower[m]
            if let n = Int(token.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { return n }
        }
        return nil
    }

    // MARK: - Title cleanup

    /// "today" / "tomorrow" / "Tuesday" — so the clarifying question repeats the day back and
    /// the user can hear that ORBIT understood it, instead of being asked a bare "what time?".
    static func dayPhrase(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        // Within a week a weekday name is unambiguous and natural; beyond that it is not.
        if let weekAway = calendar.date(byAdding: .day, value: 7, to: now), date < weekAway {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "EEEE d MMMM"
        }
        return formatter.string(from: date)
    }

    private func cleanAsTitle(_ raw: String) -> String {
        var s = stripAffirmationPrefix(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let prefixes = [
            // Delegation phrases: "I want you to set a reminder" → strip preamble → empty title → ask what+when
            "i want you to set a reminder for", "i want you to set a reminder about",
            "i want you to set a reminder to", "i want you to set a reminder",
            "i want you to remind me about", "i want you to remind me to", "i want you to remind me",
            "i need you to set a reminder", "i'd like you to set a reminder",
            "can you please set a reminder for", "can you please set a reminder about",
            "can you please set a reminder to", "can you please set a reminder",
            "could you please set a reminder for", "could you please set a reminder about",
            "could you please set a reminder to", "could you please set a reminder",
            "please set a reminder for", "please set a reminder to",
            "please set a reminder about", "please set a reminder",
            "can you set a reminder for", "can you set a reminder to",
            "can you set a reminder about", "can you set a reminder",
            "could you set a reminder for", "could you set a reminder to",
            "could you set a reminder about", "could you set a reminder",
            "i want a reminder for", "i want a reminder about", "i want a reminder",
            "i need a reminder for", "i need a reminder about", "i need a reminder",
            "i'd like a reminder for", "i'd like a reminder about", "i'd like a reminder",
            // Original patterns
            "remind me to", "remind me about", "remind me that", "remind me",
            "set a reminder to", "set a reminder for", "set a reminder about", "set a reminder",
            "create a reminder to", "create a reminder for", "create a reminder about", "create a reminder",
            "add a reminder to", "add a reminder for", "add a reminder",
            "schedule a reminder to", "schedule a reminder for", "schedule a reminder about", "schedule a reminder",
            "put a reminder to", "put a reminder for", "put a reminder about", "put a reminder",
            "set me a reminder to", "set me a reminder for", "set me a reminder",
            "set up a reminder to", "set up a reminder for", "set up a reminder",
            "please remind me to", "please remind me about", "please remind me",
            "can you remind me to", "can you remind me about", "can you remind me",
            "could you remind me to", "could you remind me about", "could you remind me",
            "new reminder to", "new reminder for", "new reminder",
            "reminder to", "reminder for", "reminder about", "reminder:",
            "don't let me forget to", "don't let me forget about", "don't let me forget",
            "dont let me forget to", "dont let me forget about", "dont let me forget",
            "don't forget to", "don't forget about", "don't forget",
            "dont forget to", "dont forget about", "dont forget",
            "remember to", "remember that", "i need to remember", "i should remember",
            "make a note to", "make a note about", "make a note that", "make a note of", "make a note",
            "add a note to", "add a note about", "add a note that", "add a note",
            "take a note to", "take a note about", "take a note that", "take a note",
            "note to self:", "note to self",
            "jot this down that", "jot this down about", "jot this down",
            "jot it down that", "jot it down about", "jot it down",
            "jot down that", "jot down about", "jot down",
            "write this down that", "write this down about", "write this down",
            "write it down that", "write it down about", "write it down",
            "write down that", "write down about", "write down",
        ].sorted { $0.count > $1.count }
        let lower = s.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        // Strip trailing prepositions left after date removal.
        //
        // Repeated, not one-shot: removing a date can leave several stranded words at once.
        // "remind me to buy tickets for Spiderman on for today" loses "today" and ends
        // "…Spiderman, on for" — a single pass took the "for" and left the title as
        // "Buy tickets for Spiderman, on".
        let trailingPreps = [" at", " for", " on", " in", " by", " to", " about", " a", " an", " the", " with"]
            .sorted { $0.count > $1.count }
        var strippedSomething = true
        while strippedSomething, !s.isEmpty {
            strippedSomething = false
            s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            for prep in trailingPreps where s.lowercased().hasSuffix(prep) {
                s = String(s.dropLast(prep.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                strippedSomething = true
                break
            }
        }
        // Strip leading prepositions left after prefix removal
        let leadingPreps = ["to ", "about ", "for ", "that "]
        for prep in leadingPreps where s.lowercased().hasPrefix(prep) {
            s = String(s.dropFirst(prep.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let strayAlone: Set<String> = ["at", "for", "about", "on", "to", "in", "with", "by", "a", "an", "the", "me"]
        if strayAlone.contains(s.lowercased()) { return "" }
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private func cleanCalendarTitle(_ raw: String) -> String {
        var s = stripAffirmationPrefix(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let prefixes = [
            "schedule a meeting for", "schedule a meeting with", "schedule a meeting",
            "schedule an appointment", "schedule a call", "schedule a", "schedule",
            "book a meeting with", "book a meeting", "book a call", "book a", "book",
            "create a calendar event for", "create a calendar event", "create a calendar entry",
            "create an event for", "create an event called", "create an event",
            "add an event", "add a meeting", "add a call",
            "set up a meeting", "set up a call", "set up a", "set up",
            "put on my calendar", "put on the calendar",
            "add to my calendar", "add to the calendar",
            "calendar event for", "calendar event",
            "block time for", "block time",
            "i'm having a meeting with", "i'm having a meeting",
            "i am having a meeting with", "i am having a meeting",
            "i have a meeting with", "i have a meeting at", "i have a meeting",
            "i have an appointment with", "i have an appointment",
            "i have a call with", "i have a call",
            "i'm meeting with", "i'm meeting",
            "i am meeting with", "i am meeting",
            "there's a meeting with", "there's a meeting",
            "there is a meeting with", "there is a meeting",
            "we have a meeting with", "we have a meeting",
            "we have a call with", "we have a call",
            "we're meeting", "we are meeting",
            "meeting with",
        ].sorted { $0.count > $1.count }
        let lower = s.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let durationPat = #"\b\d+[\s-]*(hour|hr|minute|min)s?\b|\bhalf[\s-]hour\b|\b(one|two|three|four|five|six|an)\s+(hour|hr|minute|min)s?\b"#
        s = s.replacingOccurrences(of: durationPat, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let trailingPreps = [" at", " for", " on", " in", " by", " to", " about", " a", " an", " the", " with"]
        for prep in trailingPreps.sorted(by: { $0.count > $1.count }) where s.lowercased().hasSuffix(prep) {
            s = String(s.dropLast(prep.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // Returns true when the input is unambiguously a calendar block.
    // If we're inside handleCalendarInformational, reminder intents have already been
    // filtered out by isReminderCreateIntent, so bare "meeting" is safe to treat as calendar.
    private func isClearCalendarOnlyIntent(_ lower: String) -> Bool {
        if lower.contains("meeting with") { return true }
        // Social events with a person are always calendar, never just a reminder
        if lower.range(of: #"\b(lunch|coffee|dinner|breakfast|drinks|brunch|catch up|catch-up|catchup)\s+with\b"#,
                       options: .regularExpression) != nil { return true }
        let clearWords = [
            "standup", "stand-up", "stand up",
            "interview", "presentation", "demo", "appointment",
            "sync", "workshop", "lecture", "seminar", "exam",
            "conference", "webinar", "debrief", "kickoff",
            "retrospective", "sprint review", "one on one", "1:1",
        ]
        if clearWords.contains(where: { lower.contains($0) }) { return true }
        // Bare "meeting" only when it's clearly the event itself, not a modifier
        // ("meeting organizer", "meeting agenda" would not match this pattern).
        return lower.range(of: #"\bmeeting\s+(at|on|tomorrow|today|tonight|this|next|in)\b"#,
                           options: .regularExpression) != nil
    }

    // Title extraction for informational intents — preserves "Meeting with X", "Standup", etc.
    // Unlike cleanCalendarTitle, does NOT strip the event-type word; only strips personal preamble.
    private func cleanCalendarTitleFromInformational(_ raw: String) -> String {
        var s = stripAffirmationPrefix(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let leadingPersonal = [
            "i'm having a", "i am having a",
            "i have a", "i have an",
            "i've got a", "i've got an", "i got a", "i got an",
            "we're having a", "we are having a",
            "we have a", "we have an",
            "there's a", "there is a",
            "i need to have a", "i want to have a",
            "i need to", "i have to", "i want to",
            "i'm going for", "i am going for",
            "i'm going to have", "i am going to have",
            "going for", "going to have",
            "i'm", "i am", "we're", "we are",
        ].sorted { $0.count > $1.count }
        let sLower = s.lowercased()
        for prefix in leadingPersonal where sLower.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        // Strip relative time phrases ("in 30 minutes", "in an hour")
        for pat in [#"\bin \d+ minutes?\b"#, #"\bin half an hour\b"#,
                    #"\bin an? hour\b"#,      #"\bin \d+ hours?\b"#] {
            s = s.replacingOccurrences(of: pat, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Strip duration expressions
        let durPat = #"\b\d+[\s-]*(hour|hr|minute|min)s?\b|\bhalf[\s-]hour\b|\b(one|two|three|four|five|six|an)\s+(hour|hr|minute|min)s?\b"#
        s = s.replacingOccurrences(of: durPat, with: " ", options: .regularExpression)
        // Strip date/time via NSDataDetector; resolve spoken numbers first so "at three" → "at 3"
        // and NSDataDetector can detect it as a time expression.
        var sForDates = OrbitMacControlCenter.resolveSpokenNumbers(in: s)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let r = NSRange(sForDates.startIndex..., in: sForDates)
            for match in detector.matches(in: sForDates, range: r).sorted(by: { $0.range.length > $1.range.length }) {
                if let rng = Range(match.range, in: sForDates) { sForDates = sForDates.replacingCharacters(in: rng, with: " ") }
            }
        }
        s = sForDates
        // Regex fallback: strip bare "at H" or "at H:MM" that NSDataDetector may have missed
        s = s.replacingOccurrences(
            of: #"\bat\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?\b"#,
            with: " ", options: [.regularExpression, .caseInsensitive]
        )
        // Strip named time-of-day words that NSDataDetector may not catch
        for word in ["tonight", "this evening", "this afternoon", "this morning", "lunchtime",
                     "end of the day", "end of day", "first thing tomorrow", "first thing",
                     "eod", "tomorrow", "today"] {
            s = s.replacingOccurrences(of: word, with: " ", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let trailingPreps = [" at", " for", " on", " in", " by", " to", " about", " a", " an", " the"]
        for prep in trailingPreps.sorted(by: { $0.count > $1.count }) where s.lowercased().hasSuffix(prep) {
            s = String(s.dropLast(prep.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let stray: Set<String> = ["at", "for", "about", "on", "to", "in", "with", "by", "a", "an", "the"]
        if stray.contains(s.lowercased()) { return "" }
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: - Affirmation prefix stripping

    private func stripAffirmationPrefix(_ text: String) -> String {
        let lower = text.lowercased()
        let prefixes = [
            "yes please ", "yeah sure ", "yes sure ",
            "yes ", "yeah ", "sure ", "ok ", "okay ", "yep ", "yup ",
            "can you please ", "could you please ",
            "can you ", "could you ", "would you ", "will you ",
            "i want you to ", "i want to ", "i'd like to ", "i would like to ",
            "please ",
        ]
        for p in prefixes where lower.hasPrefix(p) {
            return String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Smart duration inference

    private func inferDuration(from lower: String) -> Int {
        if let explicit = extractDurationMinutes(from: lower) { return explicit }
        if lower.contains("standup") || lower.contains("stand-up") || lower.contains("stand up") { return 15 }
        if lower.contains("1:1") || lower.contains("one on one") || lower.contains("check-in") || lower.contains("check in") { return 30 }
        if lower.contains("quick") || lower.contains("brief") || lower.contains("short") { return 30 }
        if lower.contains("presentation") || lower.contains("demo") { return 45 }
        if lower.contains("lunch") || lower.contains("dinner") || lower.contains("brunch") { return 60 }
        if lower.contains("workshop") || lower.contains("training") { return 90 }
        return 60
    }

    // MARK: - Title "with person" preservation

    private func preserveWithPerson(rawTitle: String?, originalLower: String) -> String? {
        guard let title = rawTitle, !title.isEmpty else { return rawTitle }
        let titleLower = title.lowercased()
        let eventWords = ["meeting", "call", "lunch", "coffee", "dinner", "breakfast",
                          "drinks", "brunch", "catch up", "catchup", "catch-up", "sync"]
        let alreadyHasEventWord = eventWords.contains { titleLower.contains($0) }
        if alreadyHasEventWord { return title }
        let hadWith = originalLower.range(of: #"\b(meeting|call|lunch|coffee|dinner|sync|catch up)\s+with\b"#,
                                          options: .regularExpression) != nil
        if hadWith && !titleLower.contains("with") {
            return "Meeting with \(title)"
        }
        return title
    }

    // MARK: - Time range extraction ("from 2 to 4", "2 to 4 pm", "2pm-4pm")

    private func extractTimeRange(from text: String) -> (start: Date, end: Date)? {
        let lower = OrbitMacControlCenter.resolveSpokenNumbers(in: text.lowercased())
        let cal = Calendar.current
        let now = Date()

        let patterns = [
            #"\bfrom\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:to|until|till|-)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#,
            #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*(?:to|until|till|-)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  match.numberOfRanges >= 5
            else { continue }

            func group(_ i: Int) -> String? {
                guard i < match.numberOfRanges, let r = Range(match.range(at: i), in: lower) else { return nil }
                return String(lower[r])
            }

            guard let startHStr = group(1), var startH = Int(startHStr),
                  let endHStr = group(4), var endH = Int(endHStr)
            else { continue }
            let startM = group(2).flatMap(Int.init) ?? 0
            let endM = group(5).flatMap(Int.init) ?? 0
            let startAmPm = group(3)?.lowercased()
            let endAmPm = group(6)?.lowercased()

            if startAmPm == "pm" && startH < 12 { startH += 12 }
            if startAmPm == "am" && startH == 12 { startH = 0 }
            if endAmPm == "pm" && endH < 12 { endH += 12 }
            if endAmPm == "am" && endH == 12 { endH = 0 }
            // No AM/PM: if both hours are 1-6, assume PM
            if startAmPm == nil && endAmPm == nil {
                if startH >= 1 && startH <= 6 { startH += 12 }
                if endH >= 1 && endH <= 6 { endH += 12 }
            }
            // If only end has AM/PM, infer start's period
            if startAmPm == nil, let ep = endAmPm {
                if ep == "pm" && startH < 12 && startH <= endH - 12 { startH += 12 }
            }

            var sc = cal.dateComponents([.year, .month, .day], from: now)
            sc.hour = startH; sc.minute = startM; sc.second = 0
            var ec = sc
            ec.hour = endH; ec.minute = endM
            guard let startDate = cal.date(from: sc), let endDate = cal.date(from: ec),
                  endDate > startDate else { continue }
            return (startDate, endDate)
        }
        return nil
    }

    // MARK: - Format helpers (static — referenced by ContentView+Chat.swift)

    static func formatEventStart(_ date: Date) -> String {
        let cal = Calendar.current
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        if cal.isDateInToday(date)    { return "today at \(tf.string(from: date))" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(tf.string(from: date))" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                       to: cal.startOfDay(for: date)).day ?? 0
        if days > 0, days <= 6 {
            let df = DateFormatter(); df.dateFormat = "EEEE"
            return "on \(df.string(from: date)) at \(tf.string(from: date))"
        }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        return df.string(from: date)
    }
}
