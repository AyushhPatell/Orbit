//
//  OrbitMacControlCenter+System.swift
//  ORBITMac
//
//  Battery, Focus/DND, and app launch intent detection + execution.
//

import AppKit
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Battery intent detection

    static func isBatteryStatusIntent(_ normalized: String) -> Bool {
        if normalized == "battery" { return true }
        let snippets = [
            "battery status", "battery percentage", "battery percent",
            "battery level", "battery left", "how much battery",
            "what is my battery", "check battery", "am i charging",
            "is charging", "on battery",
            "what is the status of battery", "what is the status of the battery",
            "status of battery", "status of the battery", "the status of battery",
            "how is my battery", "how is battery", "battery how much", "battery remaining",
            "what s my battery", "whats my battery", "what is battery", "tell me my battery",
            "do i have battery", "device battery", "laptop battery", "mac battery",
            "power left", "how much power", "charge level", "charging status",
        ]
        if snippets.contains(where: { normalized.contains($0) }) { return true }
        if normalized.contains("battery"), normalized.contains("status") { return true }
        if normalized.contains("battery"), normalized.contains("level") { return true }
        if normalized.contains("battery"), normalized.contains("percentage") || normalized.contains("percent") {
            return true
        }
        return false
    }

    // MARK: - Focus / DND intent detection

    static func isFocusOnIntent(_ normalized: String) -> Bool {
        let snippets = [
            "focus mode on", "turn focus on", "enable focus mode",
            "turn on focus mode", "do not disturb on", "turn dnd on",
            "turn on dnd", "enable do not disturb", "turn on do not disturb",
            "activate focus mode", "activate focus", "start focus mode",
            "enable focus", "switch focus mode on", "switch on focus",
            "put focus on", "focus mode please", "turn on focus",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isFocusOffIntent(_ normalized: String) -> Bool {
        let snippets = [
            "focus mode off", "turn focus off", "disable focus mode",
            "turn off focus mode", "do not disturb off", "turn dnd off",
            "turn off dnd", "disable do not disturb", "turn off do not disturb",
            "deactivate focus mode", "deactivate focus",
            "end focus mode", "end focus", "end dnd",
            "stop focus mode", "stop focus", "disable focus",
            "switch focus mode off", "switch off focus",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isFocusStatusIntent(_ normalized: String) -> Bool {
        let snippets = [
            "focus status", "is focus mode on", "check focus mode",
            "dnd status", "is dnd on", "is do not disturb on",
            "check do not disturb", "focus mode status",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    // MARK: - Focus / DND execution helpers

    /// Toggling Focus has no public API on modern macOS. The old trick — writing the
    /// `com.apple.notificationcenterui doNotDisturb` key — is silently ignored: the write
    /// "succeeds", nothing changes, and reading the same key back "verifies" it. That made
    /// ORBIT claim "Focus is on" while doing nothing, which breaks the honesty rule.
    /// Honest path: run a user Shortcut built on the 'Set Focus' action, or admit failure
    /// and explain the one-time setup.
    /// Switches a Focus mode by running the user's matching Shortcut.
    /// `mode` is free text as spoken ("sleep", "do not disturb", "work"); nil means Do Not Disturb.
    static func setFocusMode(mode: String?, enabled: Bool) throws -> String {
        let want = enabled ? "on" : "off"
        let requested = (mode ?? "do not disturb").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let names = shortcutNames()
        guard !names.isEmpty else {
            throw ControlError.actionFailed(focusSetupHint(for: requested, enabled: enabled))
        }
        guard let shortcut = focusShortcutName(mode: requested, enabled: enabled, in: names) else {
            let modes = availableFocusModes(in: names)
            let known = modes.isEmpty
                ? focusSetupHint(for: requested, enabled: enabled)
                : "I don\u{2019}t have a Shortcut for \u{201C}\(requested)\u{201D}. The Focus modes I can switch are: "
                    + modes.joined(separator: ", ") + "."
            throw ControlError.actionFailed(known)
        }
        let result = try runCommand("/usr/bin/shortcuts", ["run", shortcut], failOnNonZero: false)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ControlError.actionFailed(
                "Shortcut \u{201C}\(shortcut)\u{201D} failed\(detail.isEmpty ? "." : ": \(detail)")"
            )
        }
        // Which shortcut ran is plumbing — say what changed, the way a person would.
        return "\(focusDisplayName(requested)) is \(want) now."
    }

    /// "sleep" → "Sleep mode", "do not disturb" → "Do Not Disturb", "work" → "Work focus".
    static func focusDisplayName(_ mode: String) -> String {
        let m = mode.lowercased()
        if m.contains("do not disturb") || m == "dnd" { return "Do Not Disturb" }
        if m.contains("sleep") { return "Sleep mode" }
        if m.contains("work") { return "Work focus" }
        let titled = m.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        return m.contains("focus") ? titled : "\(titled) focus"
    }

    private static func focusSetupHint(for mode: String, enabled: Bool) -> String {
        let title = "Turn \(enabled ? "On" : "Off") \(mode.capitalized)"
        return "macOS doesn\u{2019}t let apps switch Focus directly. One-time setup: in the Shortcuts app, "
            + "create a shortcut named \u{201C}\(title)\u{201D} using the \u{2018}Set Focus\u{2019} action \u{2014} "
            + "after that this works by voice."
    }

    /// Reads the user's current Focus by running a "Get Current Focus" style Shortcut.
    static func currentFocusStatus() throws -> String {
        let names = shortcutNames()
        guard let shortcut = names.first(where: {
            let l = $0.lowercased()
            return l.contains("focus") && (l.contains("current") || l.contains("get") || l.contains("status"))
        }) else {
            throw ControlError.actionFailed(
                "I don\u{2019}t have a Shortcut that reports Focus. Create one named \u{201C}Get Current Focus\u{201D} "
                + "that ends with a \u{2018}Stop and Output\u{2019} step so I can read the answer."
            )
        }
        let result = try runCommand("/usr/bin/shortcuts", ["run", shortcut, "-o", "-"], failOnNonZero: false)
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ControlError.actionFailed("Shortcut \u{201C}\(shortcut)\u{201D} failed\(detail.isEmpty ? "." : ": \(detail)")")
        }
        guard !out.isEmpty else {
            throw ControlError.actionFailed(
                "\u{201C}\(shortcut)\u{201D} ran but returned nothing. Open it in Shortcuts and add a "
                + "\u{2018}Stop and Output\u{2019} action with the Focus value so I can read it back."
            )
        }
        return "Current Focus: \(out)"
    }

    /// Focus mode names ORBIT can switch, derived from "Turn On/Off X" shortcut names.
    static func availableFocusModes(in names: [String]? = nil) -> [String] {
        let list = names ?? shortcutNames()
        var modes: [String] = []
        for n in list {
            let l = n.lowercased()
            guard l.hasPrefix("turn on ") || l.hasPrefix("turn off ") else { continue }
            let mode = l.hasPrefix("turn on ")
                ? String(l.dropFirst("turn on ".count))
                : String(l.dropFirst("turn off ".count))
            let cleaned = mode.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, !modes.contains(cleaned) else { continue }
            // Only Focus-ish targets; "turn on bedroom lights" is smart home, not Focus.
            if cleaned.contains("light") || cleaned.contains("plug") || cleaned.contains("fan") { continue }
            modes.append(cleaned)
        }
        return modes
    }

    static func shortcutNames() -> [String] {
        guard let result = try? runCommand("/usr/bin/shortcuts", ["list"], failOnNonZero: false) else { return [] }
        return result.stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func focusShortcutName(mode: String, enabled: Bool, in names: [String]) -> String? {
        let want = enabled ? "on" : "off"
        let other = enabled ? "off" : "on"
        // Synonyms so "quiet mode"/"dnd" resolve to the user's "Do Not Disturb" shortcut.
        var aliases = [mode]
        if ["dnd", "do not disturb", "quiet", "quiet mode", "silent"].contains(mode) {
            aliases += ["do not disturb", "dnd"]
        }
        if mode.contains("sleep") || mode.contains("bed") { aliases += ["sleep"] }
        if mode.contains("work") || mode.contains("focus mode") { aliases += ["work"] }

        func matches(_ name: String, _ alias: String) -> Bool {
            let l = name.lowercased()
            let words = Set(l.split { !$0.isLetter }.map(String.init))
            guard words.contains(want), !words.contains(other) else { return false }
            return l.contains(alias)
        }
        for alias in aliases {
            if let hit = names.first(where: { matches($0, alias) }) { return hit }
        }
        // Generic "Turn On Focus" as a last resort.
        return names.first { matches($0, "focus") }
    }

    // MARK: - Dark mode intent detection
    // All checks require an action verb to avoid matching queries like "is dark mode on?"

    static func isDarkModeOnIntent(_ normalized: String) -> Bool {
        let n = normalized
        // Require an action word alongside dark mode references
        let actionWords = ["turn", "enable", "switch", "set", "put", "use", "go"]
        let hasDark = n.contains("dark mode") || n.contains("dark theme")
        let hasAction = actionWords.contains(where: { n.contains($0) })
        guard hasDark && hasAction else { return false }
        if n.contains("turn on dark") || n.contains("turn dark mode on") { return true }
        if n.contains("enable dark mode") { return true }
        if n.contains("switch to dark mode") { return true }
        if n.contains("set dark mode on") || n.contains("set to dark") { return true }
        if n.contains("use dark mode") { return true }
        if n.contains("go dark") { return true }
        if n.contains("dark theme on") { return true }
        return false
    }

    static func isDarkModeOffIntent(_ normalized: String) -> Bool {
        let n = normalized
        let actionWords = ["turn", "disable", "switch", "set", "put", "use", "go"]
        let hasAction = actionWords.contains(where: { n.contains($0) })
        if n.contains("turn off dark mode") || n.contains("turn dark mode off") { return true }
        if n.contains("disable dark mode") { return true }
        if n.contains("switch to light mode") || n.contains("use light mode") { return true }
        if hasAction && (n.contains("light mode") || n.contains("light theme")) { return true }
        if n.contains("go light") { return true }
        if n.contains("turn on light mode") || n.contains("enable light mode") { return true }
        return false
    }

    static func isDarkModeToggleIntent(_ normalized: String) -> Bool {
        let n = normalized
        let snippets = [
            "toggle dark mode", "toggle dark", "switch dark mode",
            "flip dark mode", "dark mode toggle",
        ]
        return snippets.contains(where: { n.contains($0) })
    }

    // MARK: - Dark mode execution

    /// Sets dark mode via System Events AppleScript — works macOS 10.14+.
    static func setDarkMode(enabled: Bool) throws {
        let value = enabled ? "true" : "false"
        try runAppleScript(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)"
        )
    }

    static func toggleDarkMode() throws {
        try runAppleScript(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        )
    }


    // MARK: - Wake orbit intent (catches "wake up orbit" in the chat pipeline)

    static func isWakeOrbitIntent(_ normalized: String) -> Bool {
        let triggers = [
            "wake up orbit", "wakeup orbit", "wake orbit",
            "orbit wake up", "orbit wakeup",
            "hey wake up orbit", "wake up please orbit",
        ]
        return triggers.contains { normalized.contains($0) }
    }

    // MARK: - Screen lock intent + execution

    static func isLockScreenIntent(_ normalized: String) -> Bool {
        let snippets = [
            "lock screen", "lock the screen", "lock my screen",
            "lock my mac", "lock the mac", "lock my computer",
            "lock the computer", "lock this computer",
            "lock display", "lock the display", "lock my laptop",
            "screen lock", "lock my device",
            // "block" variants — common voice shorthand
            "block my screen", "block the screen", "block screen",
            // Sleep / turn off display
            "sleep my screen", "sleep the screen", "sleep the display",
            "put my screen to sleep", "put the screen to sleep",
            "turn off the screen", "turn off my screen",
            "turn off the display", "turn off my display",
            "blank the screen", "blank my screen",
            // Suspend
            "suspend the screen", "suspend display",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func lockScreen() throws {
        // Method 1: CGSession -suspend — hard screen lock (shows login window immediately)
        let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        if FileManager.default.fileExists(atPath: cgSession) {
            _ = try? runCommand(cgSession, ["-suspend"], failOnNonZero: false)
            return
        }
        // Method 2: pmset displaysleepnow — sleeps the display; password required on wake
        // Does NOT require Accessibility permission and works on all macOS versions.
        _ = try? runCommand("/usr/bin/pmset", ["displaysleepnow"], failOnNonZero: false)
    }

    // MARK: - Quit app intent + execution

    static func extractQuitAppTarget(from normalized: String) -> String? {
        // Only fire when the verb begins the utterance (possibly after "please" / "can you" /
        // voice filler words like "um", "uh", "okay") to avoid catching "I want to quit smoking"
        // or "close the chapter" in conversational context.
        let patterns = [
            #"^(?:force\s+quit|quit|close|exit|kill)\s+([a-z0-9][a-z0-9 .&+\-']*?)$"#,
            #"^(?:please|can you|could you)\s+(?:force\s+quit|quit|close|exit|kill)\s+([a-z0-9][a-z0-9 .&+\-']*?)$"#,
            // Voice transcription often prepends filler words before the command verb.
            #"^(?:um+|uh+|yeah|yep|ok(?:ay)?|right|so|well|now|hey)\s+(?:force\s+quit|quit|close|exit|kill)\s+([a-z0-9][a-z0-9 .&+\-']*?)$"#,
        ]
        let leadingArticles = ["my ", "the ", "your ", "this ", "that "]
        let genericWords = Set(["window", "tab", "it", "this", "that", "everything", "all", "all apps"])
        for pattern in patterns {
            if var match = firstCapture(in: normalized, pattern: pattern) {
                match = match.trimmingCharacters(in: .whitespacesAndNewlines)
                match = stripTrailingConversationalFill(match)
                for prefix in leadingArticles where match.lowercased().hasPrefix(prefix) {
                    match = String(match.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                match = match.replacingOccurrences(of: #"\b(app|application)\b$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if match.isEmpty || genericWords.contains(match.lowercased()) { continue }
                // Reject multi-word targets that don't look like app names (> 3 words is suspicious)
                if match.split(separator: " ").count > 3 { continue }
                return match
            }
        }
        return nil
    }

    static func quitApp(named rawName: String) throws -> String {
        let rawNorm = normalizedAppName(rawName)
        // Expand spoken short-names to their real macOS app names.
        let expandedNames = expandedAppNames(for: rawNorm)
        let allNorms = ([rawNorm] + expandedNames.map { normalizedAppName($0) })

        // Match against currently running applications.
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.localizedName else { return false }
            let norm = normalizedAppName(name)
            // Accept: exact match, prefix match, contains match (catches "System Settings" ← "settings")
            return allNorms.contains { q in
                norm == q || norm.hasPrefix(q) || q.hasPrefix(norm) || norm.contains(q)
            }
        }
        if let app = running.first {
            let label = app.localizedName ?? displayName(for: rawName)
            app.terminate()
            return "Closed \(label)."
        }
        // Fallback: try each expanded name via AppleScript (most reliable for system apps)
        let scriptNames = expandedNames.isEmpty ? [displayName(for: rawName)] : expandedNames
        for scriptName in scriptNames {
            if (try? runAppleScript("quit application \"\(scriptName)\"")) != nil {
                return "Closed \(scriptName)."
            }
        }
        // If nothing worked, be honest about what we tried
        let friendlyName = expandedNames.first ?? displayName(for: rawName)
        throw ControlError.actionFailed("I couldn\u{2019}t find \(friendlyName) running — is it open?")
    }

    // Maps spoken short-names to their real macOS application names.
    // Used by both quitApp and openApp alias resolution.
    static func expandedAppNames(for normalizedQuery: String) -> [String] {
        let aliases: [String: [String]] = [
            "settings":     ["System Settings", "System Preferences"],
            "preferences":  ["System Settings", "System Preferences"],
            "prefs":        ["System Settings", "System Preferences"],
            "systemsettings":   ["System Settings"],
            "systempreferences": ["System Preferences"],
            "finder":       ["Finder"],
            "files":        ["Finder"],
            "filemanager":  ["Finder"],
            "safari":       ["Safari"],
            "chrome":       ["Google Chrome"],
            "googlechrome": ["Google Chrome"],
            "mail":         ["Mail"],
            "calendar":     ["Calendar"],
            "reminders":    ["Reminders"],
            "notes":        ["Notes"],
            "maps":         ["Maps"],
            "music":        ["Music"],
            "photos":       ["Photos"],
            "contacts":     ["Contacts"],
            "facetime":     ["FaceTime"],
            "messages":     ["Messages"],
            "imessage":     ["Messages"],
            "appstore":     ["App Store"],
            "calculator":   ["Calculator"],
            "terminal":     ["Terminal"],
            "activitymonitor": ["Activity Monitor"],
            "diskutility":  ["Disk Utility"],
            "preview":      ["Preview"],
            "textedit":     ["TextEdit"],
            "xcode":        ["Xcode"],
            "vscode":       ["Visual Studio Code"],
            "visualstudiocode": ["Visual Studio Code"],
            "slack":        ["Slack"],
            "zoom":         ["Zoom"],
            "teams":        ["Microsoft Teams"],
            "microsoftteams": ["Microsoft Teams"],
            "word":         ["Microsoft Word"],
            "excel":        ["Microsoft Excel"],
            "powerpoint":   ["Microsoft PowerPoint"],
            "outlook":      ["Microsoft Outlook"],
        ]
        return aliases[normalizedQuery] ?? []
    }

    // MARK: - App launch intent + execution

    static func extractOpenAppTarget(from normalized: String) -> String? {
        let patterns = [
            #"(?:^|\b)(?:open|launch|start)\s+([a-z0-9 .&+\-']+)$"#,
            #"(?:^|\b)can you\s+(?:open|launch|start)\s+([a-z0-9 .&+\-']+)$"#,
            #"(?:^|\b)please\s+(?:open|launch|start)\s+([a-z0-9 .&+\-']+)$"#,
        ]
        for pattern in patterns {
            if let match = firstCapture(in: normalized, pattern: pattern) {
                var cleaned = match
                    .replacingOccurrences(of: #"\b(app|application)\b$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Strip trailing conversational fill words ("open safari please" → "safari")
                cleaned = stripTrailingConversationalFill(cleaned)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    static func openApp(named rawName: String) async throws -> String {
        let appName = displayName(for: rawName)
        let rawNorm = normalizedAppName(rawName)
        let aliases: [String: String] = [
            "teams": "Microsoft Teams",
            "team": "Microsoft Teams",
            "outlook": "Microsoft Outlook",
            "safari": "Safari",
            "chrome": "Google Chrome",
            "google": "Google Chrome",
        ]
        let bundleAliases: [String: String] = [
            "safari": "com.apple.Safari",
            "teams": "com.microsoft.teams2",
            "outlook": "com.microsoft.Outlook",
            "chrome": "com.google.Chrome",
        ]
        let aliasResolved = aliases[rawNorm] ?? ""
        let candidateNames = [appName, aliasResolved].filter { !$0.isEmpty }
        let installedApps = allInstalledAppURLs()

        if let bundleId = bundleAliases[rawNorm],
           let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        {
            try await openApplication(at: bundleURL)
            return appDisplayName(from: bundleURL)
        }

        for name in candidateNames {
            let nameNorm = normalizedAppName(name)
            if let exact = installedApps.first(where: { normalizedAppName(appDisplayName(from: $0)) == nameNorm }) {
                try await openApplication(at: exact)
                return appDisplayName(from: exact)
            }
        }

        if let bestURL = bestMatchingInstalledApp(for: rawNorm, installedApps: installedApps) {
            try await openApplication(at: bestURL)
            return appDisplayName(from: bestURL)
        }

        for name in [appName, aliasResolved, rawName].filter({ !$0.isEmpty }) {
            if runOpenCLI(appName: name) { return displayName(for: name) }
        }

        throw ControlError.appNotFound
    }

    static func openApplication(at url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func appDisplayName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func normalizedAppName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    static func bestMatchingInstalledApp(for normalizedQuery: String, installedApps: [URL]) -> URL? {
        guard !normalizedQuery.isEmpty else { return nil }
        var best: (url: URL, score: Int)?
        for appURL in installedApps {
            let name = appDisplayName(from: appURL)
            let norm = normalizedAppName(name)
            if norm.isEmpty { continue }
            let score: Int
            if norm == normalizedQuery {
                score = 0
            } else if norm.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(norm) {
                score = 1
            } else if norm.contains(normalizedQuery) {
                score = 2
            } else {
                let d = levenshtein(norm, normalizedQuery)
                let threshold = max(2, min(5, normalizedQuery.count / 3))
                if d > threshold { continue }
                score = 10 + d
            }
            if best == nil || score < best!.score { best = (appURL, score) }
        }
        return best?.url
    }

    static func allInstalledAppURLs() -> [URL] {
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            realUserHomeForFiles().appendingPathComponent("Applications"),
        ]
        var seen = Set<String>()
        var out: [URL] = []
        for root in roots {
            for url in appURLs(in: root) {
                let p = url.path
                if !seen.contains(p) { seen.insert(p); out.append(url) }
            }
        }
        return out
    }

    static func appURLs(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var apps: [URL] = []
        for url in entries {
            if url.pathExtension.lowercased() == "app" { apps.append(url); continue }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true
            else { continue }
            if let nested = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for child in nested where child.pathExtension.lowercased() == "app" {
                    apps.append(child)
                }
            }
        }
        return apps
    }

    static func runOpenCLI(appName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var dist = Array(0...bChars.count)
        for i in 1...aChars.count {
            var prev = dist[0]
            dist[0] = i
            for j in 1...bChars.count {
                let tmp = dist[j]
                dist[j] = aChars[i - 1] == bChars[j - 1] ? prev : min(prev, dist[j - 1], dist[j]) + 1
                prev = tmp
            }
        }
        return dist[bChars.count]
    }
}
