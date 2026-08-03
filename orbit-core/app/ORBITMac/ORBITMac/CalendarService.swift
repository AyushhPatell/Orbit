//
//  CalendarService.swift
//  ORBITMac
//
//  Day 3 — EventKit: read today's events (macOS).
//

import EventKit
import Foundation

enum CalendarServiceError: Error, LocalizedError {
    case accessDenied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access was denied. Turn it on in System Settings → Privacy & Security → Calendars → ORBITMac."
        case .failed(let message):
            return message
        }
    }
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private let store = EKEventStore()
    /// Coalesces concurrent `requestFullAccessToEvents` / `requestAccess` calls so two code paths don't double-prompt.
    private var pendingAccessTask: Task<Void, Error>?

    /// Ensures the app can read events. Shows the system prompt the first time.
    func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            return
        case .notDetermined:
            if let existing = pendingAccessTask {
                try await existing.value
                return
            }
            let task = Task { @MainActor in
                if #available(macOS 14.0, *) {
                    let granted = try await self.store.requestFullAccessToEvents()
                    if !granted { throw CalendarServiceError.accessDenied }
                } else {
                    let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                        self.store.requestAccess(to: .event) { ok, error in
                            if let error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: ok)
                            }
                        }
                    }
                    if !granted { throw CalendarServiceError.accessDenied }
                }
            }
            pendingAccessTask = task
            defer { pendingAccessTask = nil }
            try await task.value
        case .writeOnly:
            if #available(macOS 14.0, *) {
                if let existing = pendingAccessTask {
                    try await existing.value
                    return
                }
                let task = Task { @MainActor in
                    let granted = try await self.store.requestFullAccessToEvents()
                    if !granted { throw CalendarServiceError.accessDenied }
                }
                pendingAccessTask = task
                defer { pendingAccessTask = nil }
                try await task.value
                let upgraded = EKEventStore.authorizationStatus(for: .event)
                if upgraded != .fullAccess, upgraded != .authorized {
                    throw CalendarServiceError.accessDenied
                }
            } else {
                throw CalendarServiceError.accessDenied
            }
        case .denied, .restricted:
            throw CalendarServiceError.accessDenied
        @unknown default:
            throw CalendarServiceError.accessDenied
        }
    }

    /// Human-readable list of today's events (local timezone, start of day → midnight).
    func todayEventsText() throws -> String {
        try upcomingEventsText(days: 1)
    }

    /// Events from now through the next `days` days, sorted by start time.
    /// Past events (already ended) are excluded. All-day events are always included for their full day.
    func upcomingEventsText(days: Int = 14) throws -> String {
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: days, to: start) else {
            throw CalendarServiceError.failed("Could not compute the calendar date range.")
        }
        // Exclude subscribed calendars (holidays, provincial days, sports schedules, birthdays —
        // anything the user didn't personally create). Only personal calendars count as "events".
        let personalCalendars = store.calendars(for: .event).filter {
            $0.type != .subscription && $0.type != .birthday
        }
        let calendarList: [EKCalendar]? = personalCalendars.isEmpty ? nil : personalCalendars
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendarList)
        // Exclude timed events whose end time has already passed. Keep all-day events for the whole day.
        let events = store.events(matching: predicate)
            .filter { $0.isAllDay || $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }

        if events.isEmpty {
            let label = days <= 1 ? "today" : "the next \(days) days"
            return "No upcoming calendar events for \(label)."
        }

        let header = events.count == 1
            ? "You have 1 upcoming event:"
            : "You have \(events.count) upcoming events:"

        let lines: [String] = events.map { event in
            let title = event.title?.isEmpty == false ? event.title! : "(Untitled)"
            if event.isAllDay {
                let d = DateFormatter.localizedString(from: event.startDate, dateStyle: .medium, timeStyle: .none)
                return "All day (\(d)) — \(title)"
            }
            let when = DateFormatter.localizedString(from: event.startDate, dateStyle: .medium, timeStyle: .short)
            return "\(when) — \(title)"
        }
        return "\(header)\n" + lines.joined(separator: "\n")
    }

    /// Deletes the first upcoming personal calendar event whose title contains `query` (case-insensitive).
    /// Edits an existing event in place: rename it, move it, or change how long it runs.
    ///
    /// Added because ORBIT had no way to change an event it had just made. Asked to rename
    /// "Call with Kan" to "Call with Kawan", the brain had only create/list/delete, so it
    /// improvised a delete-then-recreate, asked for confirmation, and then lost track of its own
    /// plan — answering that the event "is already scheduled, so there's nothing to update".
    /// A correction is one operation, and it should be one tool.
    func updateEvent(
        matching query: String,
        newTitle: String? = nil,
        newStart: Date? = nil,
        newDurationMinutes: Double? = nil
    ) async throws -> String {
        try await ensureAccess()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Error: no event title provided." }
        guard newTitle != nil || newStart != nil || newDurationMinutes != nil else {
            return "Error: nothing to change — give a new title, start time, or duration."
        }

        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
        guard let end = cal.date(byAdding: .day, value: 365, to: now) else {
            return "Error: could not compute search range."
        }
        let personalCalendars = store.calendars(for: .event).filter {
            $0.type != .subscription && $0.type != .birthday
        }
        let calendarList: [EKCalendar]? = personalCalendars.isEmpty ? nil : personalCalendars
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendarList)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        guard let match = events.first(where: {
            ($0.title ?? "").lowercased().contains(trimmed.lowercased())
        }) else {
            return "No calendar event matching '\(trimmed)' was found. Nothing was changed."
        }

        let oldTitle = match.title ?? "(Untitled)"
        let oldStart = match.startDate ?? now
        // Preserve the existing length unless the caller is explicitly changing it, so moving an
        // event does not silently reset it to a default duration.
        let existingDuration = (match.endDate ?? oldStart.addingTimeInterval(3600))
            .timeIntervalSince(oldStart)

        if let newTitle, !newTitle.isEmpty { match.title = newTitle }
        if let newStart {
            match.startDate = newStart
            match.endDate = newStart.addingTimeInterval((newDurationMinutes.map { $0 * 60 }) ?? existingDuration)
        } else if let newDurationMinutes {
            match.endDate = oldStart.addingTimeInterval(newDurationMinutes * 60)
        }

        do {
            try store.save(match, span: .thisEvent, commit: true)
        } catch {
            return "Could not update '\(oldTitle)': \(error.localizedDescription)"
        }

        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var changes: [String] = []
        if let newTitle, !newTitle.isEmpty, newTitle != oldTitle {
            changes.append("renamed to '\(newTitle)'")
        }
        if let newStart { changes.append("moved to \(df.string(from: newStart))") }
        else if newDurationMinutes != nil { changes.append("duration changed") }
        let summary = changes.isEmpty ? "updated" : changes.joined(separator: " and ")
        return "Updated calendar event '\(oldTitle)' — \(summary)."
    }

    func deleteEvent(matching query: String) async throws -> String {
        try await ensureAccess()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Error: no event title provided."
        }

        let cal = Calendar.current
        let now = Date()
        // Search from yesterday through 1 year out so we catch events that already started.
        let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? now
        guard let end = cal.date(byAdding: .day, value: 365, to: now) else {
            return "Error: could not compute search range."
        }

        let personalCalendars = store.calendars(for: .event).filter {
            $0.type != .subscription && $0.type != .birthday
        }
        let calendarList: [EKCalendar]? = personalCalendars.isEmpty ? nil : personalCalendars
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendarList)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        guard let match = events.first(where: {
            ($0.title ?? "").lowercased().contains(trimmed.lowercased())
        }) else {
            return "No calendar event matching '\(trimmed)' was found. Nothing was deleted."
        }

        let title = match.title ?? "(Untitled)"
        do {
            try store.remove(match, span: .thisEvent)
            return "Deleted calendar event '\(title)'."
        } catch {
            return "Failed to delete '\(title)': \(error.localizedDescription)"
        }
    }

    /// Creates a timed event after calendar access is granted. Returns the name of the calendar it was saved to.
    @discardableResult
    func addTimedEvent(
        title: String,
        start: Date,
        end: Date,
        notes: String? = nil,
        recurrence: String? = nil
    ) async throws -> String {
        try await ensureAccess()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CalendarServiceError.failed("Event title is empty.")
        }
        guard end > start else {
            throw CalendarServiceError.failed("End time must be after start time.")
        }

        let event = EKEvent(eventStore: store)
        event.title = trimmedTitle
        event.startDate = start
        event.endDate = end
        if let notes {
            let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { event.notes = n }
        }

        if let recurrence {
            let rule: EKRecurrenceRule? = {
                switch recurrence.lowercased() {
                case "daily":    return EKRecurrenceRule(recurrenceWith: .daily,   interval: 1, end: nil)
                case "weekly":   return EKRecurrenceRule(recurrenceWith: .weekly,  interval: 1, end: nil)
                case "biweekly": return EKRecurrenceRule(recurrenceWith: .weekly,  interval: 2, end: nil)
                case "monthly":  return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
                case "yearly":   return EKRecurrenceRule(recurrenceWith: .yearly,  interval: 1, end: nil)
                default: return nil
                }
            }()
            if let rule { event.recurrenceRules = [rule] }
        }

        if let cal = store.defaultCalendarForNewEvents {
            event.calendar = cal
        } else if let writable = store.calendars(for: .event).first(where: { $0.allowsContentModifications }) {
            event.calendar = writable
        } else {
            throw CalendarServiceError.failed("No writable calendar found.")
        }

        let calendarName = event.calendar?.title ?? "Calendar"
        try store.save(event, span: .thisEvent)
        return calendarName
    }
}
