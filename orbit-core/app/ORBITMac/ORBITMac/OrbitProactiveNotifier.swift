//
//  OrbitProactiveNotifier.swift
//  ORBITMac
//
//  Background engine that proactively alerts the user about upcoming and overdue
//  reminders/events without needing to be asked. Three jobs per tick:
//    1. Calendar event pre-alerts (15 min, 5 min before start)
//    2. Reminder pre-alerts      (30 min, 10 min before due)
//    3. Overdue follow-up        ("Did you call mom?") — smart windows by importance
//

import EventKit
import Foundation
import UserNotifications

// MARK: - Notification identifiers

private enum NotifCategoryID {
    static let followup = "orbit.proactive.followup"
}

private enum NotifActionID {
    static let done      = "orbit.action.done"
    static let snooze30  = "orbit.action.snooze30"
}

// MARK: - Engine

@MainActor
final class OrbitProactiveNotifier {
    static let shared = OrbitProactiveNotifier()
    private init() {}

    // MARK: - Config

    // Calendar pre-alerts: fire at T-15 and T-5 before event start
    private static let eventWindows: [(before: Int, tolerance: Int, label: String)] = [
        (15, 1, "15min"),
        (5,  1, "5min"),
    ]

    // Reminder pre-alerts: fire at T-30 and T-10 before reminder due time
    private static let reminderWindows: [(before: Int, tolerance: Int, label: String)] = [
        (30, 2, "30min"),
        (10, 1, "10min"),
    ]

    private static let pollInterval: TimeInterval   = 60         // sweep every 60 s
    private static let eventLookAhead: TimeInterval = 20 * 60    // scan next 20 min for events
    private static let reminderLookAhead: TimeInterval = 35 * 60 // scan next 35 min for reminders

    // Overdue follow-up windows
    private static let regularFollowupHours: Double  = 2.0  // ask once within 2 h for regular items
    private static let importantFollowupHours: Double = 72.0 // ask for up to 72 h for deadlines
    private static let importantRepeatHours: Double   = 6.0  // repeat every 6 h for important items

    // Voice announce cooldown
    private static let voiceCooldown: TimeInterval = 300  // at most one proactive voice per 5 min

    // MARK: - State

    private let store = EKEventStore()
    private var pollingTask: Task<Void, Never>?
    private var sessionFired = Set<String>()
    private let defaults = UserDefaults.standard
    private var lastVoiceAt: Date?

    // MARK: - Bootstrap

    func bootstrap() {
        registerNotificationCategories()
        requestNotificationPermission()
        loadPersistedFiredKeys()
        Task {
            await requestEventAccess()
            await requestReminderAccess()
            startPolling()
        }
    }

    private func registerNotificationCategories() {
        let doneAction = UNNotificationAction(
            identifier: NotifActionID.done,
            title: "Done \u{2713}",
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: NotifActionID.snooze30,
            title: "Remind me in 30 min",
            options: []
        )
        let followupCategory = UNNotificationCategory(
            identifier: NotifCategoryID.followup,
            actions: [doneAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([followupCategory])
    }

    private func requestNotificationPermission() {
        Task {
            try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    private func requestEventAccess() async {
        do {
            if #available(macOS 14.0, *) {
                try await store.requestFullAccessToEvents()
            } else {
                try await store.requestAccess(to: .event)
            }
        } catch {}
    }

    private func requestReminderAccess() async {
        do {
            if #available(macOS 14.0, *) {
                try await store.requestFullAccessToReminders()
            } else {
                try await store.requestAccess(to: .reminder)
            }
        } catch {}
    }

    // MARK: - Polling loop

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Per-tick sweep

    private var briefingJustFired = false

    private func tick() async {
        let now = Date()
        let dayKey = Self.dayKey(for: now)

        // Morning briefing — independent of proactive notifications toggle
        if defaults.bool(forKey: "orbitMac.morningBriefingEnabled") {
            let firedBriefing = await checkMorningBriefing(now: now, dayKey: dayKey)
            if firedBriefing {
                briefingJustFired = true
                // Give the briefing 2 minutes to finish speaking before other notifications fire
                return
            }
        }
        // After a briefing, wait one tick before firing other alerts
        if briefingJustFired { briefingJustFired = false; return }

        guard defaults.bool(forKey: "orbitMac.proactiveNotifications") else { return }

        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)

        // 1. Calendar event pre-alerts (synchronous EventKit)
        if calendarAccessGranted {
            sweepCalendarEvents(now: now, dayKey: dayKey)
            checkBackToBackMeetings(now: now, dayKey: dayKey, hour: hour)
        }

        // 2. Reminder pre-alerts + overdue follow-up (async EventKit)
        if reminderAccessGranted {
            let upcomingReminders = await fetchReminders(
                from: now,
                to: now.addingTimeInterval(Self.reminderLookAhead)
            )
            sweepReminderPreAlerts(reminders: upcomingReminders, now: now, dayKey: dayKey)

            // Overdue: look back 72 h to catch important deadlines missed days ago
            let overdueReminders = await fetchReminders(
                from: now.addingTimeInterval(-Self.importantFollowupHours * 3600),
                to: now
            )
            sweepOverdueFollowup(reminders: overdueReminders, now: now, dayKey: dayKey)
        }

        // 3. Context-aware nudges
        checkBreakReminder(now: now, dayKey: dayKey, hour: hour)
        if calendarAccessGranted || reminderAccessGranted {
            await checkEndOfDayWrapUp(now: now, dayKey: dayKey, hour: hour)
        }
    }

    // MARK: - Morning briefing

    @discardableResult
    private func checkMorningBriefing(now: Date, dayKey: String) async -> Bool {
        let cal = Calendar.current
        let hour   = cal.component(.hour,   from: now)
        let minute = cal.component(.minute, from: now)
        let targetHour = defaults.integer(forKey: "orbitMac.morningBriefingHour")
        // Fire at the scheduled time, or catch up if the app started late (until 2 PM).
        let isOnTime  = hour == targetHour && minute < 2
        let isCatchUp = hour > targetHour && hour < 14
        guard isOnTime || isCatchUp else { return false }
        let key = "briefing_\(dayKey)"
        guard !sessionFired.contains(key) else { return false }
        sessionFired.insert(key)
        persistFiredKey(key, day: dayKey)
        await fireMorningBriefing(now: now)
        return true
    }

    private func fireMorningBriefing(now: Date) async {
        let cal = Calendar.current
        let greeting = greetingForHour(cal.component(.hour, from: now))

        // Kick off weather fetch concurrently with EventKit queries.
        async let weatherFetch = OrbitWeatherService.fetchHalifax()

        var eventLines: [String] = []
        var reminderLines: [String] = []

        // Today's remaining calendar events
        if calendarAccessGranted {
            let todayStart = cal.startOfDay(for: now)
            let todayEnd   = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now
            let predicate  = store.predicateForEvents(withStart: todayStart, end: todayEnd, calendars: nil)
            let events = store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.endDate > now }
                .sorted { $0.startDate < $1.startDate }
            eventLines = events.map { e in
                let time = DateFormatter.localizedString(from: e.startDate, dateStyle: .none, timeStyle: .short)
                return "\(time) \u{2014} \(e.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Event")"
            }
        }

        // Reminders due today or tomorrow
        if reminderAccessGranted {
            let todayStart   = cal.startOfDay(for: now)
            let tomorrowEnd  = cal.date(byAdding: .day, value: 2, to: todayStart) ?? now
            let reminders    = await fetchReminders(from: todayStart, to: tomorrowEnd)
            reminderLines = reminders.compactMap { r -> String? in
                guard !r.isCompleted, let title = r.title else { return nil }
                if let comps = r.dueDateComponents, let date = cal.date(from: comps) {
                    return "\(title) (\(OrbitReminderService.formatDueDate(date)))"
                }
                return title
            }
        }

        let weather = await weatherFetch

        // Build notification sections (weather first, with tip inline)
        var sections: [String] = []
        if let w = weather {
            let tipLine = OrbitWeatherService.tip(for: w.spoken).map { "\n\($0)" } ?? ""
            sections.append("\(w.display)\(tipLine)")
        }
        if !eventLines.isEmpty {
            sections.append("Today\u{2019}s events:\n" + eventLines.joined(separator: "\n"))
        }
        if !reminderLines.isEmpty {
            sections.append("Reminders:\n" + reminderLines.joined(separator: "\n"))
        }

        let hasSchedule = !eventLines.isEmpty || !reminderLines.isEmpty
        let notifBody: String
        let spokenText: String
        if !hasSchedule {
            let weatherLine: String
            let weatherSpoken: String
            if let w = weather {
                let tip = OrbitWeatherService.tip(for: w.spoken)
                weatherLine  = tip.map { "\(w.display)\n\($0)\n\n" } ?? "\(w.display)\n\n"
                weatherSpoken = tip.map { "Weather: \(w.spoken). \($0) " } ?? "Weather: \(w.spoken). "
            } else {
                weatherLine = ""
                weatherSpoken = ""
            }
            notifBody  = "\(greeting) \(weatherLine)Clear schedule \u{2014} no events or reminders today."
            spokenText = "\(greeting) \(weatherSpoken)You have a clear schedule today, nothing on the calendar or in reminders."
        } else {
            notifBody  = "\(greeting) Here\u{2019}s your day:\n\n" + sections.joined(separator: "\n\n")
            spokenText = buildSpokenBriefing(greeting: greeting, eventLines: eventLines, reminderLines: reminderLines, weather: weather)
        }

        // Notification
        let content = UNMutableNotificationContent()
        content.title = "Morning Briefing"
        content.body  = notifBody
        content.sound = .default
        deliver(content: content, id: "orbit.briefing.\(Self.dayKey(for: now))")

        // Briefing card: full-card layout with title, auto-dismisses after speech ends.
        OrbitListeningPresence.shared.presentWakeVoiceCard(from: notifBody, title: "Morning Briefing", ttlSeconds: 20)

        // Voice announce (uses the proactive voice setting)
        speakProactively(spokenText)
    }

    private func buildSpokenBriefing(
        greeting: String,
        eventLines: [String],
        reminderLines: [String],
        weather: (display: String, spoken: String)? = nil
    ) -> String {
        var parts = [greeting]
        if let w = weather {
            let tip = OrbitWeatherService.tip(for: w.spoken)
            let weatherLine = "Weather: \(w.spoken)."
            parts.append(tip.map { "\(weatherLine) \($0)" } ?? weatherLine)
        }
        if !eventLines.isEmpty {
            let count = eventLines.count
            parts.append("You have \(count) event\(count == 1 ? "" : "s") today: \(eventLines.joined(separator: "; ")).")
        }
        if !reminderLines.isEmpty {
            let count = reminderLines.count
            parts.append("\(count == 1 ? "One reminder" : "\(count) reminders") due: \(reminderLines.joined(separator: "; ")).")
        }
        return parts.joined(separator: " ")
    }

    private func greetingForHour(_ hour: Int) -> String {
        switch hour {
        case 5 ..< 12: return "Good morning!"
        case 12 ..< 17: return "Good afternoon!"
        default: return "Good evening!"
        }
    }

    // MARK: - Calendar event alerts

    private func sweepCalendarEvents(now: Date, dayKey: String) {
        let horizon = now.addingTimeInterval(Self.eventLookAhead)
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            guard !event.isAllDay else { continue }
            let minutesUntil = event.startDate.timeIntervalSince(now) / 60.0

            for window in Self.eventWindows {
                guard abs(minutesUntil - Double(window.before)) <= Double(window.tolerance) else { continue }
                let rawID = event.eventIdentifier ?? (event.title ?? UUID().uuidString)
                let key = "\(rawID)_event_\(window.label)_\(dayKey)"
                guard !sessionFired.contains(key) else { continue }
                sessionFired.insert(key)
                persistFiredKey(key, day: dayKey)
                sendEventPreAlert(event: event, minutesBefore: window.before)
            }
        }
    }

    // MARK: - Reminder pre-alerts

    private func sweepReminderPreAlerts(reminders: [EKReminder], now: Date, dayKey: String) {
        for reminder in reminders {
            guard !reminder.isCompleted,
                  let comps = reminder.dueDateComponents,
                  let dueDate = Calendar.current.date(from: comps)
            else { continue }

            let minutesUntil = dueDate.timeIntervalSince(now) / 60.0
            guard minutesUntil > 0 else { continue }

            for window in Self.reminderWindows {
                guard abs(minutesUntil - Double(window.before)) <= Double(window.tolerance) else { continue }
                let id = reminder.calendarItemExternalIdentifier ?? (reminder.title ?? UUID().uuidString)
                let key = "\(id)_reminder_\(window.label)_\(dayKey)"
                guard !sessionFired.contains(key) else { continue }
                sessionFired.insert(key)
                persistFiredKey(key, day: dayKey)
                sendReminderPreAlert(reminder: reminder, minutesBefore: window.before)
            }
        }
    }

    // MARK: - Overdue follow-up

    private func sweepOverdueFollowup(reminders: [EKReminder], now: Date, dayKey: String) {
        for reminder in reminders {
            guard !reminder.isCompleted,
                  let comps = reminder.dueDateComponents,
                  let dueDate = Calendar.current.date(from: comps),
                  dueDate < now
            else { continue }

            let elapsed = now.timeIntervalSince(dueDate)
            let id = reminder.calendarItemExternalIdentifier ?? (reminder.title ?? UUID().uuidString)
            let title = reminder.title ?? "reminder"
            let important = Self.isImportantReminder(title)

            // Already confirmed done by user — skip
            if isConfirmedDone(id) { continue }

            // Snooze: user asked to be reminded later — respect the snooze window
            if let until = snoozedUntil(id), now < until { continue }

            if important {
                // Repeat every 6 hours up to 72 hours after the due date
                guard elapsed <= Self.importantFollowupHours * 3600 else { continue }
                let slotKey = Self.sixHourSlotKey(for: now)
                let key = "\(id)_followup_important_\(slotKey)"
                guard !sessionFired.contains(key) else { continue }
                sessionFired.insert(key)
                persistFiredKey(key, day: dayKey)
            } else {
                // Ask once, within 2 hours of due time, same calendar day
                guard elapsed <= Self.regularFollowupHours * 3600 else { continue }
                guard Calendar.current.isDateInToday(dueDate) else { continue }
                let key = "\(id)_followup_\(dayKey)"
                guard !sessionFired.contains(key) else { continue }
                sessionFired.insert(key)
                persistFiredKey(key, day: dayKey)
            }

            sendFollowup(reminderID: id, title: title, dueDate: dueDate, important: important)
        }
    }

    // MARK: - Context-aware nudges

    private func checkBackToBackMeetings(now: Date, dayKey: String, hour: Int) {
        guard hour >= 7, hour <= 20 else { return }
        let cal = Calendar.current
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: todayEnd, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
        guard events.count >= 2 else { return }

        // Find chains of events with < 15 min gap between them
        var chain: [EKEvent] = [events[0]]
        for i in 1..<events.count {
            let gap = events[i].startDate.timeIntervalSince(chain.last!.endDate)
            if gap < 15 * 60 {
                chain.append(events[i])
            } else if chain.count < 3 {
                chain = [events[i]]
            } else {
                break
            }
        }
        guard chain.count >= 3 else { return }

        // Only fire 15–25 min before the first event in the chain
        let minUntilFirst = chain[0].startDate.timeIntervalSince(now) / 60
        guard minUntilFirst >= 15, minUntilFirst <= 25 else { return }

        let key = "b2b_\(dayKey)_\(chain[0].eventIdentifier ?? "x")"
        guard !sessionFired.contains(key) else { return }
        sessionFired.insert(key)
        persistFiredKey(key, day: dayKey)

        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        let firstTime = tf.string(from: chain[0].startDate)
        let lastEnd = tf.string(from: chain.last!.endDate)
        let body = "Heads up — you have \(chain.count) events back-to-back starting at \(firstTime). You won\u{2019}t be free until \(lastEnd)."

        let content = UNMutableNotificationContent()
        content.title = "Busy stretch ahead"
        content.body = body
        content.sound = .default
        deliver(content: content, id: "orbit.nudge.b2b.\(dayKey)")
        speakProactively(body)
    }

    private func checkBreakReminder(now: Date, dayKey: String, hour: Int) {
        guard hour >= 10, hour <= 18 else { return }
        // Fire at 2-hour slots: 10, 12, 14, 16, 18
        let slot = hour / 2
        guard hour % 2 == 0 else { return }
        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        guard minute < 2 else { return }
        // Skip weekends
        let weekday = cal.component(.weekday, from: now)
        guard weekday >= 2, weekday <= 6 else { return }

        let key = "break_\(dayKey)_\(slot)"
        guard !sessionFired.contains(key) else { return }
        sessionFired.insert(key)
        persistFiredKey(key, day: dayKey)

        let messages = [
            "You\u{2019}ve been at it for a while. Maybe take a quick stretch or grab some water?",
            "Time for a short break! Step away for a couple of minutes \u{2014} your focus will thank you.",
            "Quick nudge: hydrate and stretch. Even 2 minutes helps.",
            "You\u{2019}re doing great! Consider a brief pause to rest your eyes.",
        ]
        let body = messages[slot % messages.count]

        let content = UNMutableNotificationContent()
        content.title = "Break reminder"
        content.body = body
        content.sound = .default
        deliver(content: content, id: "orbit.nudge.break.\(dayKey).\(slot)")
        speakProactively(body)
    }

    private func checkEndOfDayWrapUp(now: Date, dayKey: String, hour: Int) async {
        let wrapHour = defaults.integer(forKey: "orbitMac.endOfDayHour")
        let targetHour = wrapHour > 0 ? wrapHour : 17
        let minute = Calendar.current.component(.minute, from: now)
        guard hour == targetHour, minute < 2 else { return }

        let key = "eodwrap_\(dayKey)"
        guard !sessionFired.contains(key) else { return }
        sessionFired.insert(key)
        persistFiredKey(key, day: dayKey)

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now

        // Count today's events
        var eventCount = 0
        if calendarAccessGranted {
            let pred = store.predicateForEvents(withStart: todayStart, end: todayEnd, calendars: nil)
            eventCount = store.events(matching: pred).filter { !$0.isAllDay && $0.endDate <= now }.count
        }

        // Count completed vs pending reminders
        var completed = 0
        var pending = 0
        if reminderAccessGranted {
            let allReminders = await fetchReminders(from: todayStart, to: todayEnd)
            for r in allReminders {
                if r.isCompleted { completed += 1 } else { pending += 1 }
            }
            // Also count reminders completed today that had no due date
            let completedToday = await fetchCompletedRemindersToday(start: todayStart, end: todayEnd)
            completed += completedToday
        }

        var parts: [String] = []
        if eventCount > 0 { parts.append("\(eventCount) event\(eventCount == 1 ? "" : "s") today") }
        if completed > 0 { parts.append("\(completed) reminder\(completed == 1 ? "" : "s") completed") }
        if pending > 0 { parts.append("\(pending) still pending") }

        let body: String
        if parts.isEmpty {
            body = "Quiet day \u{2014} no events or reminders. Nice and relaxed!"
        } else {
            body = "Day wrap-up: \(parts.joined(separator: ", ")).\(pending > 0 ? " Don\u{2019}t forget the pending ones!" : " Well done!")"
        }

        let content = UNMutableNotificationContent()
        content.title = "End of Day"
        content.body = body
        content.sound = .default
        deliver(content: content, id: "orbit.nudge.eod.\(dayKey)")
        speakProactively(body)
    }

    private func fetchCompletedRemindersToday(start: Date, end: Date) async -> Int {
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: start, ending: end, calendars: nil
        )
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { results in
                continuation.resume(returning: results?.count ?? 0)
            }
        }
    }

    // MARK: - Notification dispatch

    private func sendEventPreAlert(event: EKEvent, minutesBefore: Int) {
        let heading = minutesBefore <= 1 ? "Starting now" : "In \(minutesBefore) min"
        let body = event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Upcoming event"

        let content = UNMutableNotificationContent()
        content.title = heading
        content.body = body
        content.sound = .default

        let notifID = "orbit.event.\(event.eventIdentifier ?? UUID().uuidString).\(minutesBefore)min"
        deliver(content: content, id: notifID)
        speakProactively("\(heading): \(body)")
    }

    private func sendReminderPreAlert(reminder: EKReminder, minutesBefore: Int) {
        let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Reminder"
        let heading = minutesBefore <= 10 ? "Coming up in \(minutesBefore) min" : "In \(minutesBefore) min"

        let content = UNMutableNotificationContent()
        content.title = heading
        content.body = title
        content.sound = .default

        let id = reminder.calendarItemExternalIdentifier ?? UUID().uuidString
        let notifID = "orbit.reminder.prealert.\(id).\(minutesBefore)min"
        deliver(content: content, id: notifID)
        speakProactively("\(heading): \(title)")
    }

    private func sendFollowup(reminderID: String, title: String, dueDate: Date, important: Bool) {
        let dueStr = OrbitReminderService.formatDueDate(dueDate)
        let notifTitle = important ? "Deadline check-in" : "Quick check-in"
        let body: String
        if important {
            body = "Your deadline \"\(title)\" was due \(dueStr). Have you completed it?"
        } else {
            body = "\"\(title)\" was due \(dueStr). Did you get to it?"
        }

        let content = UNMutableNotificationContent()
        content.title = notifTitle
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NotifCategoryID.followup
        content.userInfo = ["reminderID": reminderID, "reminderTitle": title]

        let notifID = "orbit.reminder.followup.\(reminderID).\(Int(dueDate.timeIntervalSince1970))"
        deliver(content: content, id: notifID)

        // Show a compact wake card so the user can respond via voice
        let cardText = "\(body) Say \u{201C}yes, done\u{201D} or \u{201C}not yet\u{201D}."
        OrbitListeningPresence.shared.presentWakeVoiceCard(from: cardText, ttlSeconds: 180)
        OrbitLocalActionPendingStore.shared.setFollowupPending(id: reminderID, title: title)

        speakProactively(body)

        // If voice announce is on, ORBIT just spoke the question — open the mic to hear the answer.
        // This lets the user respond immediately without needing to say "Hey ORBIT" first.
        if defaults.bool(forKey: "orbitMac.proactiveVoiceAnnounce") {
            scheduleFollowupListening()
        }
    }

    private func scheduleFollowupListening() {
        let speech = OrbitVoiceKit.shared.speech
        let speechInput = OrbitVoiceKit.shared.speechInput
        Task { @MainActor in
            // Wait for the proactive speech to finish
            for _ in 0..<90 {
                if !speech.isSpeaking { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !speechInput.isListening,
                  OrbitLocalActionPendingStore.shared.followupPendingInfo != nil else { return }
            await OrbitWakeVoiceBackstage.shared.startListeningForFollowupResponse()
        }
    }

    private func deliver(content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Proactive voice announce

    private func speakProactively(_ message: String) {
        guard defaults.bool(forKey: "orbitMac.proactiveVoiceAnnounce") else { return }
        let speech = OrbitVoiceKit.shared.speech
        let speechInput = OrbitVoiceKit.shared.speechInput
        guard !speech.isSpeaking, !speechInput.isListening else { return }
        if let last = lastVoiceAt, Date().timeIntervalSince(last) < Self.voiceCooldown { return }
        lastVoiceAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            speech.speak(message)
        }
    }

    // MARK: - Notification action response (called from AppDelegate)

    func handleNotificationResponse(actionID: String, userInfo: [AnyHashable: Any]) {
        guard let reminderID = userInfo["reminderID"] as? String,
              let reminderTitle = userInfo["reminderTitle"] as? String
        else { return }

        switch actionID {
        case NotifActionID.done:
            markConfirmedDone(reminderID)
            OrbitLocalActionPendingStore.shared.clearFollowup()
            Task {
                await OrbitReminderService.shared.requestAccessIfNeeded()
                _ = await OrbitReminderService.shared.completeReminder(matching: reminderTitle)
            }
        case NotifActionID.snooze30:
            snooze(reminderID: reminderID, minutes: 30)
            OrbitLocalActionPendingStore.shared.clearFollowup()
        default:
            break
        }
    }

    // MARK: - Confirmed done / snooze (public — called from voice response handler too)

    func markConfirmedDone(_ reminderID: String) {
        defaults.set(Date(), forKey: "orbit.proactive.confirmed.\(reminderID)")
    }

    func snooze(reminderID: String, minutes: Int) {
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        defaults.set(until, forKey: "orbit.proactive.snooze.\(reminderID)")
    }

    /// Removes the in-session and persisted fired keys for a reminder's followup so the
    /// proactive notifier can re-fire after the snooze expires. Call this when the user
    /// says "not yet" or "tried but couldn't reach" — we snooze AND allow a re-check.
    func clearFollowupFiredKey(for reminderID: String) {
        let dayKey = Self.dayKey(for: Date())
        let regularKey = "\(reminderID)_followup_\(dayKey)"
        let slotKey = Self.sixHourSlotKey(for: Date())
        let importantKey = "\(reminderID)_followup_important_\(slotKey)"
        sessionFired.remove(regularKey)
        sessionFired.remove(importantKey)
        // Mirror removal in UserDefaults so the key is also gone after an app restart.
        let udK = udKey(for: dayKey)
        if var arr = defaults.stringArray(forKey: udK) {
            arr.removeAll { $0.hasPrefix("\(reminderID)_followup") }
            defaults.set(arr, forKey: udK)
        }
    }

    // MARK: - Access helpers

    private var calendarAccessGranted: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        switch s {
        case .denied, .restricted, .notDetermined: return false
        default: return true
        }
    }

    private var reminderAccessGranted: Bool {
        let s = EKEventStore.authorizationStatus(for: .reminder)
        switch s {
        case .denied, .restricted, .notDetermined: return false
        default: return true
        }
    }

    // MARK: - EventKit fetch helper

    private func fetchReminders(from start: Date, to end: Date) async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: start, ending: end, calendars: nil
        )
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { results in
                continuation.resume(returning: results ?? [])
            }
        }
    }

    // MARK: - Importance detection

    static func isImportantReminder(_ title: String) -> Bool {
        let lower = title.lowercased()
        let keywords = [
            "deadline", "submit", "submission", "due", "project",
            "exam", "test", "interview", "presentation", "report",
            "launch", "ship", "release", "deliverable", "assignment",
            "final", "urgent", "asap", "critical",
        ]
        return keywords.contains { lower.contains($0) }
    }

    // MARK: - Private helpers

    private func isConfirmedDone(_ reminderID: String) -> Bool {
        guard let confirmedAt = defaults.object(forKey: "orbit.proactive.confirmed.\(reminderID)") as? Date
        else { return false }
        return Date().timeIntervalSince(confirmedAt) < 7 * 24 * 3600  // forget after 7 days
    }

    private func snoozedUntil(_ reminderID: String) -> Date? {
        defaults.object(forKey: "orbit.proactive.snooze.\(reminderID)") as? Date
    }

    private static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func sixHourSlotKey(for date: Date) -> String {
        let slot = Calendar.current.component(.hour, from: date) / 6
        return "\(dayKey(for: date))-s\(slot)"
    }

    // MARK: - Fired-key persistence (survives app restarts)

    private func udKey(for day: String) -> String { "orbit.proactive.fired.\(day)" }

    private func loadPersistedFiredKeys() {
        let day = Self.dayKey(for: Date())
        if let saved = defaults.stringArray(forKey: udKey(for: day)) {
            sessionFired.formUnion(saved)
        }
        pruneOldPersistedKeys()
    }

    private func persistFiredKey(_ key: String, day: String) {
        let k = udKey(for: day)
        var arr = defaults.stringArray(forKey: k) ?? []
        guard !arr.contains(key) else { return }
        arr.append(key)
        defaults.set(arr, forKey: k)
    }

    private func pruneOldPersistedKeys() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("orbit.proactive.fired.") {
            let dateStr = String(k.dropFirst("orbit.proactive.fired.".count))
            guard let d = f.date(from: dateStr),
                  let diff = cal.dateComponents([.day], from: d, to: today).day,
                  diff >= 3
            else { continue }
            defaults.removeObject(forKey: k)
        }
    }
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
