//
//  OrbitMacControlCenter+SmartHome.swift
//  ORBITMac
//
//  Smart home control via macOS Shortcuts. The user creates Shortcuts on iPhone
//  (e.g. via Globe Suite) that sync to Mac. ORBIT detects "turn on bedroom lights"
//  and runs the matching shortcut by name.
//

import Foundation

extension OrbitMacControlCenter {

    // MARK: - Intent detection

    static func isSmartHomeIntent(_ normalized: String) -> Bool {
        extractSmartHomeComponents(normalized) != nil
    }

    struct SmartHomeComponents {
        let action: String   // "on", "off", "toggle"
        let target: String   // "bedroom lights", "hall", "all lights", etc.
    }

    static func extractSmartHomeComponents(_ normalized: String) -> SmartHomeComponents? {
        // System features are never smart-home shortcuts. Without this guard, "turn off wifi"
        // is claimed here (this runs BEFORE parseCommand) and dies with a "create a shortcut
        // named Turn Off Wifi" error instead of reaching the real Wi-Fi handler.
        let systemTargets = [
            "wifi", "wi fi", "wi-fi", "bluetooth", "dark mode", "light mode",
            "focus", "do not disturb", "dnd", "volume", "brightness", "night shift",
            "screen", "display", "airdrop", "notification", "music", "sound",
        ]
        if systemTargets.contains(where: { normalized.contains($0) }) { return nil }
        // Focus modes ("sleep", "work") are not smart-home devices. Without this the
        // smart-home matcher claimed "turn off sleep" and replied with raw shortcut plumbing.
        if availableFocusModes().contains(where: { normalized.contains($0) }) { return nil }
        // Pattern 1: "turn on/off X" or "switch on/off X"
        if let m = normalized.range(of: #"\b(turn|switch)\s+(on|off)\s+(?:the\s+|my\s+)?(.+)"#,
                                     options: .regularExpression) {
            let sub = String(normalized[m])
            let action = sub.contains(" on ") ? "on" : "off"
            let targetStart = sub.range(of: action == "on" ? " on " : " off ")!.upperBound
            var target = String(sub[targetStart...]).trimmingCharacters(in: .whitespaces)
            target = stripArticles(target)
            if !target.isEmpty { return SmartHomeComponents(action: action, target: target) }
        }
        // Pattern 2: "X lights on/off" or "X on/off"
        if let m = normalized.range(of: #"(.+?)\s+(lights?|bulbs?|lamp)\s+(on|off)\b"#,
                                     options: .regularExpression) {
            let sub = String(normalized[m])
            let action = sub.hasSuffix("on") ? "on" : "off"
            let target = sub.replacingOccurrences(of: #"\s+(on|off)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !target.isEmpty { return SmartHomeComponents(action: action, target: stripArticles(target)) }
        }
        // Pattern 3: "lights on/off in X"
        if let m = normalized.range(of: #"\b(lights?|bulbs?)\s+(on|off)\s+in\s+(?:the\s+)?(.+)"#,
                                     options: .regularExpression) {
            let sub = String(normalized[m])
            let action = sub.contains(" on ") ? "on" : "off"
            if let inRange = sub.range(of: " in ") {
                let room = String(sub[inRange.upperBound...])
                    .replacingOccurrences(of: #"^the\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let target = "\(room) lights"
                return SmartHomeComponents(action: action, target: target)
            }
        }
        return nil
    }

    // MARK: - Shortcut execution

    static func executeSmartHome(_ components: SmartHomeComponents) async throws -> String {
        let shortcuts = try listShortcuts()
        guard let match = findBestShortcut(action: components.action, target: components.target, in: shortcuts) else {
            let suggestion = "Turn \(components.action) \(components.target)"
                .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            throw ControlError.actionFailed(
                "I couldn\u{2019}t find a shortcut for that. Create one named \u{201C}\(suggestion)\u{201D} in the Shortcuts app on your iPhone \u{2014} it\u{2019}ll sync to your Mac."
            )
        }
        try runShortcut(match)
        let actionWord = components.action == "on" ? "Turned on" : "Turned off"
        return "\(actionWord) the \(components.target)."
    }

    /// Brain-tool entry point: runs a Shortcut from a spoken name or description.
    /// Exact/substring name matching first, then smart-home action/target matching
    /// ("turn on bedroom lights"). System settings are rejected so the brain retries
    /// with the right tool instead of inventing a shortcut.
    static func runShortcutNamed(_ spoken: String) async throws -> String {
        let q = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        // Self-healing: the brain sometimes reaches for run_shortcut on a Focus request
        // ("Turn On Focus"). Route it to the real Focus handler instead of failing.
        if q.contains("focus") || q.contains("do not disturb") || q.contains("dnd") {
            let enabling = !(q.contains("off") || q.contains("disable") || q.contains("stop"))
            return try setFocusMode(mode: spokenFocusMode(in: q), enabled: enabling)
        }
        let shortcuts = (try? listShortcuts()) ?? []
        let nameMatch = shortcuts.first { $0.lowercased() == q }
            ?? shortcuts.first { $0.lowercased().contains(q) || q.contains($0.lowercased()) }
            ?? shortcuts.first { sc in
                let scWords = Set(sc.lowercased().split(separator: " ").map(String.init))
                let qWords = q.split(separator: " ").map(String.init).filter { $0.count > 2 }
                return !qWords.isEmpty && qWords.allSatisfy { scWords.contains($0) }
            }
        if let nameMatch {
            try runShortcut(nameMatch)
            return "Done \u{2014} \(nameMatch.lowercased()) ran."
        }
        if let components = extractSmartHomeComponents(q) {
            return try await executeSmartHome(components)
        }
        throw ControlError.actionFailed(
            "No shortcut matching \u{201C}\(spoken)\u{201D} was found. If this is a system setting (wi-fi, focus, volume, brightness), it isn\u{2019}t a Shortcut \u{2014} use the matching system tool instead."
        )
    }

    // MARK: - Shortcuts helpers

    private static var shortcutsCache: (list: [String], at: Date)?
    private static let shortcutsCacheTTL: TimeInterval = 300

    private static func listShortcuts() throws -> [String] {
        if let cached = shortcutsCache, Date().timeIntervalSince(cached.at) < shortcutsCacheTTL {
            return cached.list
        }
        let result = try runCommand("/usr/bin/shortcuts", ["list"])
        let list = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        shortcutsCache = (list, Date())
        return list
    }

    private static func runShortcut(_ name: String) throws {
        let result = try runCommand("/usr/bin/shortcuts", ["run", name], failOnNonZero: false)
        if result.status != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ControlError.actionFailed(
                "Shortcut \u{201C}\(name)\u{201D} failed\(detail.isEmpty ? "." : ": \(detail)")"
            )
        }
    }

    private static func findBestShortcut(action: String, target: String, in shortcuts: [String]) -> String? {
        let targetWords = target.lowercased()
            .replacingOccurrences(of: "lights", with: "")
            .replacingOccurrences(of: "light", with: "")
            .replacingOccurrences(of: "bulbs", with: "")
            .replacingOccurrences(of: "bulb", with: "")
            .replacingOccurrences(of: "lamp", with: "")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let actionWord = action.lowercased()

        // Exact name match first: "Turn on Bedroom Lights", "Turn off Hall"
        for sc in shortcuts {
            let scLower = sc.lowercased()
            if scLower.contains(actionWord), targetWords.allSatisfy({ scLower.contains($0) }) {
                return sc
            }
        }
        // Relaxed: shortcut contains the room name and "on"/"off"
        for sc in shortcuts {
            let scLower = sc.lowercased()
            let hasAction = scLower.contains(actionWord) || scLower.contains("toggle")
            let hasRoom = targetWords.contains { scLower.contains($0) }
            if hasAction && hasRoom { return sc }
        }
        // Last resort: shortcut name contains ALL target words (ignoring action)
        for sc in shortcuts {
            let scLower = sc.lowercased()
            if targetWords.allSatisfy({ scLower.contains($0) }) { return sc }
        }
        return nil
    }

    private static func stripArticles(_ text: String) -> String {
        text.replacingOccurrences(of: #"^(the|my|a|an)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
