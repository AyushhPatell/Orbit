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

    func createReminder(title: String, dueDate: Date?, notes: String? = nil) throws -> String {
        guard hasAccess else {
            return "I don't have access to Reminders. Please allow access in System Settings → Privacy & Security → Reminders."
        }
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

        // Resolve pronouns ("it", "that", "this") to a concrete reminder title.
        // First try lastListedTitles (set when ORBIT listed reminders via EventKit).
        // Fall back to the live incomplete list — if there's only 1 pending reminder the
        // reference is unambiguous even if the user got the list from the LLM.
        let pronouns: Set<String> = ["it", "that", "this", "the reminder", "that reminder",
                                      "this reminder", "the one", "that one", "this one"]
        var q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if pronouns.contains(q) {
            if lastListedTitles.count == 1 {
                q = lastListedTitles[0].lowercased()
            } else if lastListedTitles.count > 1 {
                let names = lastListedTitles.prefix(3).joined(separator: ", ")
                return "Which reminder did you mean? You mentioned: \(names). Say the name and I\u{2019}ll mark it done."
            } else if incomplete.count == 1 {
                // Only 1 active reminder — unambiguous even without a prior listing.
                q = (incomplete[0].title ?? "").lowercased()
            } else if incomplete.count > 1 {
                let names = incomplete.prefix(3).map { $0.title ?? "?" }.joined(separator: ", ")
                return "Which reminder did you mean? You have: \(names). Say the name and I\u{2019}ll mark it done."
            } else {
                return "You don\u{2019}t have any pending reminders."
            }
        }

        let match = incomplete.first { ($0.title ?? "").lowercased().contains(q) }
            ?? incomplete.first { Self.levenshtein(($0.title ?? "").lowercased(), q) <= 3 }
        guard let match else {
            return "I couldn\u{2019}t find a reminder matching \u{201C}\(q)\u{201D}. Try saying the reminder name clearly."
        }
        // store.save runs on @MainActor — safe.
        let title = match.title ?? "reminder"
        let isRecurring = match.hasRecurrenceRules
        match.isCompleted = true
        match.completionDate = Date()
        do {
            try store.save(match, commit: true)
            if isRecurring {
                return "Done \u{2014} marked \u{201C}\(title)\u{201D} as complete. It\u{2019}s a recurring reminder, so the next occurrence will still show up."
            }
            return "Done \u{2014} marked \u{201C}\(title)\u{201D} as complete."
        } catch {
            return "Couldn\u{2019}t mark it complete: \(error.localizedDescription)"
        }
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
