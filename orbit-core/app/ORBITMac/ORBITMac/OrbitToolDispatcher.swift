//
//  OrbitToolDispatcher.swift
//  ORBITMac
//
//  Routes tool_call names from the brain LLM to Swift functions
//  (EventKit, etc.) and returns a result string the server can use
//  as the tool result in the second conversation turn.
//

import CoreWLAN
import Foundation

@MainActor
enum OrbitToolDispatcher {
    static func dispatch(_ toolCall: ToolCallInfo) async -> String {
        // Capability gate — the one place every brain tool must pass through. A switched-off
        // capability is not a prompt rule the model might ignore: the tool never runs. And a
        // refusal is NOT a failure, so it is deliberately not logged as missed-intent
        // telemetry; nothing broke, he simply decided ORBIT shouldn't do this.
        guard OrbitCapabilities.isAllowed(tool: toolCall.tool) else {
            return OrbitCapabilities.refusal(for: toolCall.tool)
        }
        let result = await run(toolCall)
        // Self-reporting: failed tool calls land in the missed-intent telemetry so
        // "show missed intents" surfaces real-world breakage without the user having
        // to remember and re-describe it.
        let lower = result.lowercased()
        if lower.hasPrefix("error") || lower.contains("failed") || lower.contains("couldn't")
            || lower.contains("couldn\u{2019}t") || lower.contains("not found") || lower.contains("unreachable") {
            OrbitFailureTelemetry.shared.logMissedIntent(
                String("[tool:\(toolCall.tool)] \(result)".prefix(190)),
                route: "tool-failure"
            )
        }
        return result
    }

    /// Runs every tool the brain asked for, in order, and returns results ready to send back.
    /// Sequential on purpose: "dim the screen and turn on sleep mode" should not race.
    static func dispatchAll(_ toolCalls: [ToolCallInfo]) async -> [ToolResultItem] {
        var results: [ToolResultItem] = []
        for call in toolCalls {
            let output = await dispatch(call)
            results.append(ToolResultItem(
                tool: call.tool,
                tool_call_id: call.id,
                params: call.params,
                result: output
            ))
        }
        return results
    }

    private static func run(_ toolCall: ToolCallInfo) async -> String {
        let svc = OrbitReminderService.shared
        switch toolCall.tool {
        case "create_reminder", "delete_reminder", "complete_reminder", "list_reminders":
            await svc.requestAccessIfNeeded()
        default:
            break
        }

        switch toolCall.tool {

        case "create_calendar_event":
            guard let title = toolCall.params["title"]?.stringValue, !title.isEmpty else {
                return "Error: missing title for create_calendar_event."
            }
            guard let startStr = toolCall.params["start"]?.stringValue,
                  let start = parseISO8601(startStr) else {
                return "Error: missing or invalid start time for create_calendar_event."
            }
            let durationMins: Double
            if case .number(let n) = toolCall.params["duration_minutes"] { durationMins = n } else { durationMins = 60 }
            let end = start.addingTimeInterval(durationMins * 60)
            let notes = toolCall.params["notes"]?.stringValue
            let recurrence = toolCall.params["recurrence"]?.stringValue
            do {
                let calName = try await CalendarService.shared.addTimedEvent(
                    title: title, start: start, end: end, notes: notes, recurrence: recurrence
                )
                let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
                let recurSuffix = recurrence.map { " (repeats \($0))" } ?? ""
                return "Created calendar event '\(title)' on \(df.string(from: start)) in '\(calName)'\(recurSuffix)."
            } catch {
                return "Failed to create calendar event: \(error.localizedDescription)"
            }

        case "list_calendar_events":
            do {
                let calSvc = CalendarService.shared
                try await calSvc.ensureAccess()
                return try calSvc.upcomingEventsText(days: 14)
            } catch {
                return "Calendar access error: \(error.localizedDescription)"
            }

        case "list_reminders":
            return await svc.listUpcoming(limit: 6)

        case "create_reminder":
            guard let title = toolCall.params["title"]?.stringValue, !title.isEmpty else {
                return "Error: missing title for create_reminder."
            }
            var dueDate: Date? = nil
            if let isoStr = toolCall.params["due_date"]?.stringValue {
                dueDate = parseISO8601(isoStr)
            }
            do {
                return await svc.createReminder(title: title, dueDate: dueDate)
            } catch {
                return "Couldn't create reminder: \(error.localizedDescription)"
            }

        case "delete_reminder":
            guard let query = toolCall.params["query"]?.stringValue, !query.isEmpty else {
                return "Error: missing query for delete_reminder."
            }
            return await svc.deleteReminder(matching: query)

        case "complete_reminder":
            guard let query = toolCall.params["query"]?.stringValue, !query.isEmpty else {
                return "Error: missing query for complete_reminder."
            }
            return await svc.completeReminder(matching: query)

        case "update_calendar_event":
            guard let query = toolCall.params["query"]?.stringValue, !query.isEmpty else {
                return "Error: missing query for update_calendar_event."
            }
            let newTitle = toolCall.params["new_title"]?.stringValue
            let newStart = toolCall.params["new_start"]?.stringValue.flatMap(parseISO8601)
            var newDuration: Double?
            if case .number(let n) = toolCall.params["duration_minutes"] { newDuration = n }
            do {
                return try await CalendarService.shared.updateEvent(
                    matching: query,
                    newTitle: newTitle,
                    newStart: newStart,
                    newDurationMinutes: newDuration
                )
            } catch {
                return "Calendar event update failed: \(error.localizedDescription)"
            }

        case "delete_calendar_event":
            guard let query = toolCall.params["query"]?.stringValue, !query.isEmpty else {
                return "Error: missing query for delete_calendar_event."
            }
            do {
                return try await CalendarService.shared.deleteEvent(matching: query)
            } catch {
                return "Calendar event deletion failed: \(error.localizedDescription)"
            }

        case "create_note":
            guard let body = toolCall.params["body"]?.stringValue, !body.isEmpty else {
                return "Error: missing body for create_note."
            }
            let noteTitle = toolCall.params["title"]?.stringValue
            do {
                return try OrbitMacControlCenter.createNote(title: noteTitle, body: body)
            } catch {
                return error.localizedDescription
            }

        case "append_note":
            guard let title = toolCall.params["title"]?.stringValue, !title.isEmpty else {
                return "Error: missing title for append_note."
            }
            guard let content = toolCall.params["content"]?.stringValue, !content.isEmpty else {
                return "Error: missing content for append_note."
            }
            do {
                return try OrbitMacControlCenter.appendToNote(title: title, content: content)
            } catch {
                return error.localizedDescription
            }

        // MARK: Mac control tools (brain-first pivot Phase 1)

        case "open_app":
            guard let name = toolCall.params["name"]?.stringValue, !name.isEmpty else {
                return "Error: missing app name for open_app."
            }
            do {
                let opened = try await OrbitMacControlCenter.openApp(named: name)
                return "Opened \(opened)."
            } catch {
                return "Couldn't open \(name): \(OrbitMacControlCenter.richErrorMessage(for: error))"
            }

        case "quit_app":
            guard let name = toolCall.params["name"]?.stringValue, !name.isEmpty else {
                return "Error: missing app name for quit_app."
            }
            do {
                return try OrbitMacControlCenter.quitApp(named: name)
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "open_website":
            guard let site = toolCall.params["site"]?.stringValue, !site.isEmpty else {
                return "Error: missing site for open_website."
            }
            let browserBundle = toolCall.params["browser"]?.stringValue
                .flatMap { OrbitMacControlCenter.resolveBrowser($0)?.bundle }
            do {
                if let url = OrbitMacControlCenter.siteURL(for: site) ?? WebActionService.normalizeURL(from: site) {
                    return try OrbitMacControlCenter.openURLInBrowser(url, browserBundle: browserBundle)
                }
                // Unknown site name — fall back to a web search so something useful happens.
                return try OrbitMacControlCenter.searchInBrowser(query: site, browserBundle: browserBundle)
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "web_search":
            guard var query = toolCall.params["query"]?.stringValue, !query.isEmpty else {
                return "Error: missing query for web_search."
            }
            // The model sometimes passes the verb's object verbatim ("the web for X") — strip it.
            for prefix in ["the web for ", "the internet for ", "web for ", "online for ", "for "]
            where query.lowercased().hasPrefix(prefix) {
                query = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            let searchBundle = toolCall.params["browser"]?.stringValue
                .flatMap { OrbitMacControlCenter.resolveBrowser($0)?.bundle }
            do {
                return try OrbitMacControlCenter.searchInBrowser(query: query, browserBundle: searchBundle)
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "control_music":
            let action = toolCall.params["action"]?.stringValue ?? ""
            do {
                switch action {
                case "play": return try OrbitMacControlCenter.musicPlay()
                case "pause": return try OrbitMacControlCenter.musicPause()
                case "next": return try OrbitMacControlCenter.musicNext()
                case "previous": return try OrbitMacControlCenter.musicPrevious()
                case "now_playing": return try OrbitMacControlCenter.musicNowPlaying()
                default: return "Error: unknown music action '\(action)'."
                }
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "control_volume":
            let action = toolCall.params["action"]?.stringValue ?? ""
            do {
                switch action {
                case "set":
                    guard let level = intParam(toolCall.params["level"]) else {
                        return "Error: 'set' needs a level (0-100)."
                    }
                    let clamped = max(0, min(100, level))
                    try OrbitMacControlCenter.runAppleScript("set volume output volume \(clamped)")
                    return "Volume set to \(clamped)%."
                case "up", "down":
                    let step = max(1, min(100, intParam(toolCall.params["level"]) ?? 10))
                    let from = OrbitMacControlCenter.currentOutputVolume()
                    let next = action == "up" ? min(100, from + step) : max(0, from - step)
                    try OrbitMacControlCenter.runAppleScript("set volume output volume \(next)")
                    return "Volume \(action) \(step) points: was \(from)%, now \(next)%."
                case "mute":
                    try OrbitMacControlCenter.runAppleScript("set volume with output muted")
                    return "Muted."
                case "unmute":
                    try OrbitMacControlCenter.runAppleScript("set volume without output muted")
                    return "Unmuted."
                default:
                    return "Error: unknown volume action '\(action)'."
                }
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "control_brightness":
            let action = toolCall.params["action"]?.stringValue ?? ""
            do {
                switch action {
                case "set":
                    guard let level = intParam(toolCall.params["level"]) else {
                        return "Error: 'set' needs a level (0-100)."
                    }
                    return try OrbitMacControlCenter.setBrightnessLevel(level)
                case "up", "down":
                    let step = intParam(toolCall.params["level"]) ?? 20
                    return try OrbitMacControlCenter.adjustBrightness(up: action == "up", step: step)
                default: return "Error: unknown brightness action '\(action)'."
                }
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "set_system_feature":
            let feature = toolCall.params["feature"]?.stringValue ?? ""
            let on = (toolCall.params["state"]?.stringValue ?? "") == "on"
            do {
                switch feature {
                case "dark_mode":
                    try OrbitMacControlCenter.setDarkMode(enabled: on)
                    return "Dark mode \(on ? "on" : "off")."
                case "focus_mode":
                    return try OrbitMacControlCenter.setFocusMode(
                        mode: toolCall.params["mode"]?.stringValue, enabled: on
                    )
                case "bluetooth":
                    try OrbitMacControlCenter.setBluetooth(enabled: on)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    // Positive confirmation only: an unreadable state is NOT success.
                    guard let verified = try? OrbitMacControlCenter.bluetoothStatus() else {
                        return "I ran the Bluetooth command but could not confirm the result, so I don't know if it worked. Check the menu bar."
                    }
                    guard verified == on else {
                        return "Tried to turn Bluetooth \(on ? "on" : "off"), but macOS did not apply it — Bluetooth is still \(verified ? "on" : "off")."
                    }
                    return "Bluetooth is \(on ? "on" : "off")."
                case "wifi":
                    let iface = try OrbitMacControlCenter.wifiInterfaceObject()
                    do {
                        try iface.setPower(on)
                    } catch {
                        // Same fallback the phrase-match path uses — setPower can throw on some
                        // macOS configurations where the networksetup CLI still works.
                        if let ifName = iface.interfaceName {
                            _ = try OrbitMacControlCenter.runCommand(
                                "/usr/sbin/networksetup",
                                ["-setairportpower", ifName, on ? "on" : "off"],
                                failOnNonZero: false
                            )
                        }
                    }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    // Positive confirmation only — never report success on an unreadable state.
                    guard let isOn = try? OrbitMacControlCenter.wifiPowerStatus() else {
                        return "I ran the Wi-Fi command but could not confirm the result, so I don't know if it worked."
                    }
                    guard isOn == on else {
                        return "Tried to turn Wi-Fi \(on ? "on" : "off"), but macOS did not apply it — Wi-Fi is still \(isOn ? "on" : "off")."
                    }
                    return "Wi-Fi is \(on ? "on" : "off")."
                default:
                    return "Error: unknown feature '\(feature)'."
                }
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "get_battery_status":
            do {
                let result = try OrbitMacControlCenter.runCommand("/usr/bin/pmset", ["-g", "batt"])
                if let m = result.stdout.range(of: #"\d+%"#, options: .regularExpression) {
                    let pct = String(result.stdout[m])
                    let source = result.stdout.lowercased().contains("ac power") ? "charging" : "on battery"
                    return "Battery is \(pct), \(source)."
                }
                return "Couldn't read battery details."
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "get_weather":
            let when = toolCall.params["when"]?.stringValue ?? "now"
            switch when {
            case "tomorrow":
                if let forecast = await OrbitWeatherService.forecastTomorrow() {
                    return forecast
                }
                return "Couldn't get tomorrow's forecast right now."
            case "tonight":
                if let forecast = await OrbitWeatherService.forecastSummary(for: 20) {
                    return "Tonight's forecast: \(forecast)."
                }
                return "Couldn't get tonight's forecast right now."
            default:
                if let w = await OrbitWeatherService.fetchHalifax() {
                    let tip = OrbitWeatherService.tip(for: w.spoken)
                    return OrbitWeatherService.spokenSummary(spoken: w.spoken, tip: tip)
                }
                return "Couldn't get the current weather — check the internet connection."
            }

        case "find_file":
            guard let query = toolCall.params["query"]?.stringValue, !query.isEmpty else {
                return "Error: missing query for find_file."
            }
            do {
                return try await OrbitMacControlCenter.findAndMaybeOpenFile(named: query)
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "open_folder":
            guard let name = toolCall.params["name"]?.stringValue, !name.isEmpty else {
                return "Error: missing folder name for open_folder."
            }
            let home = OrbitMacControlCenter.realUserHomeForFiles()
            do {
                switch name.lowercased().trimmingCharacters(in: .whitespaces) {
                case "downloads":
                    return try OrbitMacControlCenter.openFolderInFinder(home.appendingPathComponent("Downloads"), label: "Downloads")
                case "documents":
                    return try OrbitMacControlCenter.openFolderInFinder(home.appendingPathComponent("Documents"), label: "Documents")
                case "desktop":
                    return try OrbitMacControlCenter.openFolderInFinder(home.appendingPathComponent("Desktop"), label: "Desktop")
                case "trash":
                    return try OrbitMacControlCenter.openFolderInFinder(home.appendingPathComponent(".Trash"), label: "Trash")
                default:
                    return OrbitMacControlCenter.findAndOpenFolderAcrossLocations(name: name)
                }
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "run_shortcut":
            guard let name = toolCall.params["name"]?.stringValue, !name.isEmpty else {
                return "Error: missing shortcut name for run_shortcut."
            }
            do {
                return try await OrbitMacControlCenter.runShortcutNamed(name)
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "get_focus_status":
            do {
                return try OrbitMacControlCenter.currentFocusStatus()
            } catch {
                return OrbitMacControlCenter.richErrorMessage(for: error)
            }

        case "lock_screen":
            // Delay so the brain's spoken confirmation isn't cut off mid-sentence by the lock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                try? OrbitMacControlCenter.lockScreen()
            }
            return "Locking the screen now."

        default:
            return "Unknown tool: \(toolCall.tool)."
        }
    }

    private static func intParam(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        if case .number(let n) = value { return Int(n) }
        if case .string(let s) = value { return Int(s) }
        return nil
    }

    // MARK: - Helpers

    private static func parseISO8601(_ raw: String) -> Date? {
        // Try with fractional seconds first, then without.
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            df.dateFormat = fmt
            if let d = df.date(from: raw) { return d }
        }
        // Fallback to system ISO8601DateFormatter
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
