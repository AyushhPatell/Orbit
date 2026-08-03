//
//  OrbitReminderService.swift
//  ORBITMac
//
//  EventKit-backed reminder CRUD. Works with both voice and typed input via
//  OrbitClarificationBroker, which handles multi-turn clarification when details are missing.
//

import EventKit
import Foundation

@MainActor
final class OrbitReminderService {
    static let shared = OrbitReminderService()
    private let store = EKEventStore()
    private var accessGranted = false
    /// Titles from the most recent listUpcoming() call — used to resolve "mark it as done" pronouns.
    private(set) var lastListedTitles: [String] = []

    private init() {}

    // MARK: - Access

    func requestAccessIfNeeded() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .denied, .restricted:
            accessGranted = false
        case .notDetermined:
            do {
                if #available(macOS 14.0, *) {
                    try await store.requestFullAccessToReminders()
                } else {
                    try await store.requestAccess(to: .reminder)
                }
                accessGranted = true
            } catch {
                // Some OS versions throw even when permission was already granted via System Settings.
                // Re-check the static status before giving up.
                let fallback = EKEventStore.authorizationStatus(for: .reminder)
                switch fallback {
                case .denied, .restricted, .notDetermined: accessGranted = false
                default: accessGranted = true
                }
            }
        default:
            // .authorized, .fullAccess, and any future "access granted" values on newer OS versions
            accessGranted = true
        }
    }

    var hasAccess: Bool {
        // Short-circuit on the cached flag set by requestAccessIfNeeded.
        if accessGranted { return true }
        // Fallback: static check (catches permission granted via System Settings without going
        // through the in-app dialog, or a new OS enum value we haven't whitelisted).
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .denied, .restricted, .notDetermined:
            return false
        default:
            accessGranted = true  // update cache so future calls skip the static check
            return true
        }
    }

    // MARK: - Create

    /// Creates a reminder unless the same task is already on the list.
    ///
    /// Confirming an existing reminder used to make a second one: "yes I am ready" produced a
    /// duplicate of a reminder set twenty minutes earlier, differing only by the word "the".
    /// Nothing checked, so nothing stopped it.
    func createReminder(title: String, dueDate: Date?, notes: String? = nil) async -> String {
        guard hasAccess else {
            return "I don't have access to Reminders. Please allow access in System Settings → Privacy & Security → Reminders."
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        let existing = await fetchRaw(predicate: predicate).filter { !$0.isCompleted }
        if let duplicate = existing.first(where: {
            OrbitReminderMatching.isSameTask($0.title ?? "", cleanTitle)
        }) {
            let existingTitle = duplicate.title ?? cleanTitle
            if let comps = duplicate.dueDateComponents,
               let date = Calendar.current.date(from: comps) {
                return "That one's already on your list — \u{201C}\(existingTitle)\u{201D} \(Self.formatDueDate(date)). Nothing new added."
            }
            return "That one's already on your list — \u{201C}\(existingTitle)\u{201D}. Nothing new added."
        }
        do {
            return try saveNewReminder(title: cleanTitle, dueDate: dueDate, notes: notes)
        } catch {
            return "Couldn't create the reminder: \(error.localizedDescription)"
        }
    }

    private func saveNewReminder(title: String, dueDate: Date?, notes: String? = nil) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()

        if let dueDate {
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
            reminder.dueDateComponents = comps
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }

        try store.save(reminder, commit: true)

        if let dueDate {
            return "Done — reminder set: \"\(title)\" \(Self.formatDueDate(dueDate))."
        }
        return "Done — reminder added: \"\(title)\"."
    }

    // MARK: - List

    func listUpcoming(limit: Int = 6) async -> String {
        guard hasAccess else {
            return "I don't have access to Reminders. Allow it in System Settings → Privacy & Security → Reminders."
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        // Fetch on EventKit's background queue — callback only hands back the raw array.
        // All EKReminder property access happens below, back on @MainActor.
        let raw = await fetchRaw(predicate: predicate)
        let incomplete = raw.filter { !$0.isCompleted }
        guard !incomplete.isEmpty else { return "You have no pending reminders." }
        let sorted = incomplete
            .sorted { a, b in
                let d0 = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                let d1 = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                return d0 < d1
            }
            .prefix(limit)
        let lines = sorted.enumerated().map { i, r -> String in
            let title = r.title ?? "Untitled"
            if let comps = r.dueDateComponents, let date = Calendar.current.date(from: comps) {
                return "\(i + 1). \(title) — \(Self.formatDueDate(date))"
            }
            return "\(i + 1). \(title)"
        }
        lastListedTitles = sorted.map { $0.title ?? "" }.filter { !$0.isEmpty }
        let header = sorted.count == 1 ? "You have 1 reminder:" : "You have \(sorted.count) reminders:"
        return "\(header)\n" + lines.joined(separator: "\n")
    }

    // MARK: - Complete

    func completeReminder(matching query: String) async -> String {
        guard hasAccess else { return "No access to Reminders." }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        // Fetch on EventKit's background queue, then process + save on @MainActor.
        let raw = await fetchRaw(predicate: predicate)
        let incomplete = raw.filter { !$0.isCompleted }
        guard !incomplete.isEmpty else { return "No pending reminders found." }

        let titles = incomplete.map { $0.title ?? "" }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // A reference with no name in it — "it", "one more", "the other one", "mark them all".
        // The old code only understood a handful of bare pronouns, so "there is one more
        // reminder left" matched nothing and failed three times in a row.
        if OrbitReminderMatching.isVagueReference(q) {
            let pool = lastListedTitles.isEmpty ? titles : lastListedTitles
            if OrbitReminderMatching.refersToMultiple(q) {
                return await complete(indices: Array(incomplete.indices), in: incomplete)
            }
            if incomplete.count == 1 {
                return await complete(indices: [0], in: incomplete)
            }
            if OrbitReminderMatching.allSameTask(titles), !titles.isEmpty {
                // Every pending reminder is the same task duplicated — no ambiguity to raise.
                return await complete(indices: Array(incomplete.indices), in: incomplete)
            }
            let names = pool.prefix(3).joined(separator: ", ")
            return "Which reminder did you mean? You have: \(names). Say the name and I\u{2019}ll mark it done."
        }

        var found = OrbitReminderMatching.matches(query: q, titles: titles)
        if found.isEmpty {
            return "I couldn\u{2019}t find a reminder matching \u{201C}\(q)\u{201D}. Try saying the reminder name clearly."
        }
        // "mark those reminders done" must not stop after the first one, and several matches
        // of the same task are one task duplicated — completing all of them is what was meant.
        let matchedTitles = found.map { titles[$0] }
        if found.count > 1,
           !OrbitReminderMatching.refersToMultiple(q),
           !OrbitReminderMatching.allSameTask(matchedTitles) {
            let names = matchedTitles.prefix(3).joined(separator: ", ")
            return "I found a few that match: \(names). Which one should I mark done?"
        }
        if found.count > 1, !OrbitReminderMatching.refersToMultiple(q),
           OrbitReminderMatching.allSameTask(matchedTitles) {
            // Same task twice — complete every copy so none is left behind.
            return await complete(indices: found, in: incomplete)
        }
        if !OrbitReminderMatching.refersToMultiple(q) {
            found = [found[0]]
        }
        return await complete(indices: found, in: incomplete)
    }

    /// Marks each reminder complete and reports honestly on what happened, including any
    /// that failed to save — a partial success must never be reported as a clean one.
    private func complete(indices: [Int], in incomplete: [EKReminder]) async -> String {
        var completed: [String] = []
        var recurring = false
        var failures: [String] = []
        for index in indices where incomplete.indices.contains(index) {
            let reminder = incomplete[index]
            let title = reminder.title ?? "reminder"
            recurring = recurring || reminder.hasRecurrenceRules
            reminder.isCompleted = true
            reminder.completionDate = Date()
            do {
                try store.save(reminder, commit: true)
                completed.append(title)
            } catch {
                failures.append(title)
            }
        }
        if completed.isEmpty {
            return "Couldn\u{2019}t mark it complete\(failures.isEmpty ? "" : ": \(failures.joined(separator: ", "))")."
        }
        var reply: String
        if completed.count == 1 {
            reply = "Done \u{2014} marked \u{201C}\(completed[0])\u{201D} as complete."
        } else {
            reply = "Done \u{2014} marked all \(completed.count) as complete: "
                + completed.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") + "."
        }
        if recurring {
            reply += " One of those recurs, so the next occurrence will still show up."
        }
        if !failures.isEmpty {
            reply += " I couldn\u{2019}t complete \(failures.joined(separator: ", "))."
        }
        return reply
    }

    // MARK: - Delete

    func deleteReminder(matching query: String) async -> String {
        guard hasAccess else { return "No access to Reminders." }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        let raw = await fetchRaw(predicate: predicate)
        let incomplete = raw.filter { !$0.isCompleted }
        guard !incomplete.isEmpty else { return "No pending reminders found." }
        let q = query.lowercased()
        let match = incomplete.first { ($0.title ?? "").lowercased().contains(q) }
            ?? incomplete.first { Self.levenshtein(($0.title ?? "").lowercased(), q) <= 3 }
        guard let match else {
            return "I couldn\u{2019}t find a reminder matching \u{201C}\(query)\u{201D}."
        }
        do {
            try store.remove(match, commit: true)
            return "Deleted \u{2014} removed \u{201C}\(match.title ?? "reminder")\u{201D} from your reminders."
        } catch {
            return "Couldn\u{2019}t delete it: \(error.localizedDescription)"
        }
    }

    // MARK: - Fetch helper

    /// Wraps the EventKit callback API. The completion block only resumes the continuation;
    /// no EKReminder properties are touched on the background thread.
    private func fetchRaw(predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - Helpers

    static func formatDueDate(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) {
            let tf = DateFormatter()
            tf.dateStyle = .none
            tf.timeStyle = .short
            return "today at \(tf.string(from: date))"
        }
        if cal.isDateInTomorrow(date) {
            let tf = DateFormatter()
            tf.dateStyle = .none
            tf.timeStyle = .short
            return "tomorrow at \(tf.string(from: date))"
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days > 0, days <= 6 {
            let df = DateFormatter()
            df.dateFormat = "EEEE"
            let tf = DateFormatter()
            tf.dateStyle = .none
            tf.timeStyle = .short
            return "on \(df.string(from: date)) at \(tf.string(from: date))"
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "on \(f.string(from: date))"
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var dist = Array(0...b.count)
        for i in 1...a.count {
            var prev = dist[0]; dist[0] = i
            for j in 1...b.count {
                let tmp = dist[j]
                dist[j] = a[i-1] == b[j-1] ? prev : min(prev, dist[j-1], dist[j]) + 1
                prev = tmp
            }
        }
        return dist[b.count]
    }
}
