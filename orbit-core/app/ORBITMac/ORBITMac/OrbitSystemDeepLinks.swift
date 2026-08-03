//
//  OrbitSystemDeepLinks.swift
//  ORBITMac
//
//  System Settings panes (macOS 13+), App Store search, and Chrome/Google URL helpers.
//

import AppKit
import CoreServices
import Foundation

enum OrbitSystemSettingsPane: String, CaseIterable {
    case root
    case general
    case wifi
    case network
    case bluetooth
    case battery
    case displays
    case sound
    case privacy
    case accessibility
    case loginItems
    case storage
    case desktopDock
    case notifications
    case focus
    case keyboard
    case trackpad
    case mouse
    case appearance
    case screenTime
    case sharing
    case softwareUpdate
    case siri
    case wallpaper

    var fallbackSidebarHint: String? {
        switch self {
        case .root:          return nil
        case .general:       return "General (or search \u{201C}General\u{201D})"
        case .wifi:          return "Wi‑Fi"
        case .network:       return "Network"
        case .bluetooth:     return "Bluetooth"
        case .battery:       return "Battery"
        case .displays:      return "Displays"
        case .sound:         return "Sound"
        case .privacy:       return "Privacy & Security"
        case .accessibility: return "Accessibility"
        case .loginItems:    return "Login Items"
        case .storage:       return "General → Storage"
        case .desktopDock:   return "Desktop & Dock"
        case .notifications: return "Notifications"
        case .focus:         return "Focus"
        case .keyboard:      return "Keyboard"
        case .trackpad:      return "Trackpad"
        case .mouse:         return "Mouse"
        case .appearance:    return "Appearance"
        case .screenTime:    return "Screen Time"
        case .sharing:       return "Sharing"
        case .softwareUpdate:return "General → Software Update"
        case .siri:          return "Siri & Spotlight"
        case .wallpaper:     return "Wallpaper"
        }
    }

    var openSummary: String {
        switch self {
        case .root:          return "System Settings"
        case .general:       return "System Settings → General"
        case .wifi:          return "System Settings → Wi-Fi"
        case .network:       return "System Settings → Network"
        case .bluetooth:     return "System Settings → Bluetooth"
        case .battery:       return "System Settings → Battery"
        case .displays:      return "System Settings → Displays"
        case .sound:         return "System Settings → Sound"
        case .privacy:       return "System Settings → Privacy & Security"
        case .accessibility: return "System Settings → Accessibility"
        case .loginItems:    return "System Settings → Login Items"
        case .storage:       return "System Settings → Storage"
        case .desktopDock:   return "System Settings → Desktop & Dock"
        case .notifications: return "System Settings → Notifications"
        case .focus:         return "System Settings → Focus"
        case .keyboard:      return "System Settings → Keyboard"
        case .trackpad:      return "System Settings → Trackpad"
        case .mouse:         return "System Settings → Mouse"
        case .appearance:    return "System Settings → Appearance"
        case .screenTime:    return "System Settings → Screen Time"
        case .sharing:       return "System Settings → Sharing"
        case .softwareUpdate:return "System Settings → Software Update"
        case .siri:          return "System Settings → Siri & Spotlight"
        case .wallpaper:     return "System Settings → Wallpaper"
        }
    }
}

enum OrbitSystemDeepLinks {
    /// Tries several URL schemes per pane. Newer macOS often still registers **`x-apple.systempreferences:`** while **`x-apple.systemsettings:`** may be missing → Finder "no application" sheet.
    enum SettingsOpenResult: Sendable {
        case openedPane
        case openedSystemSettingsAppOnly
        case failed
    }

    static func openSettingsPane(_ pane: OrbitSystemSettingsPane) -> SettingsOpenResult {
        for url in settingsURLCandidates(for: pane) {
            guard shouldAttemptOpeningSettingsURL(url) else { continue }
            if NSWorkspace.shared.open(url) {
                return .openedPane
            }
        }
        if openSystemSettingsApplication() {
            return .openedSystemSettingsAppOnly
        }
        return .failed
    }

    /// When `x-apple.systemsettings` has **no** real handler, macOS routes the open to **Finder** and shows "no application set to open the URL".
    private static func shouldAttemptOpeningSettingsURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        if scheme != "x-apple.systemsettings" { return true }
        guard let raw = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String? else {
            return false
        }
        let bid = raw.lowercased()
        if bid == "com.apple.finder" { return false }
        return true
    }

    private static func settingsURLCandidates(for pane: OrbitSystemSettingsPane) -> [URL] {
        func u(_ s: String) -> URL? { URL(string: s) }

        // Order: legacy `systempreferences` first (still works on many macOS 15/16+ builds), then `systemsettings`.
        switch pane {
        case .root:
            return [
                u("x-apple.systempreferences:"),
                u("x-apple.systemsettings:"),
            ].compactMap { $0 }
        case .general:
            return [
                u("x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension"),
                u("x-apple.systempreferences:com.apple.preference.general"),
                u("x-apple.systemsettings:com.apple.SystemProfiler.AboutExtension"),
            ].compactMap { $0 }
        case .wifi:
            return [
                u("x-apple.systempreferences:com.apple.Network-Settings.extension?Wi-Fi"),
                u("x-apple.systempreferences:com.apple.wifi-settings-extension"),
                u("x-apple.systemsettings:com.apple.Network-Settings.extension?Wi-Fi"),
                u("x-apple.systemsettings:com.apple.wifi-settings-extension"),
            ].compactMap { $0 }
        case .network:
            return [
                u("x-apple.systempreferences:com.apple.Network-Settings.extension"),
                u("x-apple.systemsettings:com.apple.Network-Settings.extension"),
            ].compactMap { $0 }
        case .bluetooth:
            return [
                u("x-apple.systempreferences:com.apple.BluetoothSettings"),
                u("x-apple.systempreferences:com.apple.preferences.Bluetooth"),
                u("x-apple.systemsettings:com.apple.Bluetooth-settings"),
            ].compactMap { $0 }
        case .battery:
            return [
                u("x-apple.systempreferences:com.apple.preference.battery"),
                u("x-apple.systemsettings:com.apple.Battery-Settings.extension"),
            ].compactMap { $0 }
        case .displays:
            return [
                u("x-apple.systempreferences:com.apple.preference.displays"),
                u("x-apple.systemsettings:com.apple.Displays-Settings.extension"),
            ].compactMap { $0 }
        case .sound:
            return [
                u("x-apple.systempreferences:com.apple.preference.sound"),
                u("x-apple.systemsettings:com.apple.Sound-Settings.extension"),
            ].compactMap { $0 }
        case .privacy:
            return [
                u("x-apple.systempreferences:com.apple.preference.security"),
                u("x-apple.systemsettings:com.apple.settings.PrivacySecurity.extension"),
            ].compactMap { $0 }
        case .accessibility:
            return [
                u("x-apple.systempreferences:com.apple.preference.universalaccess"),
                u("x-apple.systemsettings:com.apple.Accessibility-Settings.extension"),
            ].compactMap { $0 }
        case .loginItems:
            return [
                u("x-apple.systemsettings:com.apple.LoginItems-Settings.extension"),
                u("x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
            ].compactMap { $0 }
        case .storage:
            return [
                u("x-apple.systemsettings:com.apple.settings.Storage"),
                u("x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"),
            ].compactMap { $0 }
        case .desktopDock:
            return [
                u("x-apple.systempreferences:com.apple.preference.desktopscreeneffect"),
                u("x-apple.systemsettings:com.apple.Desktop-Settings.extension"),
            ].compactMap { $0 }
        case .notifications:
            return [
                u("x-apple.systempreferences:com.apple.preference.notifications"),
                u("x-apple.systemsettings:com.apple.Notifications-Settings.extension"),
            ].compactMap { $0 }
        case .focus:
            return [
                u("x-apple.systemsettings:com.apple.Focus-Settings.extension"),
                u("x-apple.systempreferences:com.apple.preference.notifications"),
            ].compactMap { $0 }
        case .keyboard:
            return [
                u("x-apple.systempreferences:com.apple.preference.keyboard"),
                u("x-apple.systemsettings:com.apple.Keyboard-Settings.extension"),
            ].compactMap { $0 }
        case .trackpad:
            return [
                u("x-apple.systempreferences:com.apple.preference.trackpad"),
                u("x-apple.systemsettings:com.apple.Trackpad-Settings.extension"),
            ].compactMap { $0 }
        case .mouse:
            return [
                u("x-apple.systempreferences:com.apple.preference.mouse"),
                u("x-apple.systemsettings:com.apple.Mouse-Settings.extension"),
            ].compactMap { $0 }
        case .appearance:
            return [
                u("x-apple.systempreferences:com.apple.preference.general"),
                u("x-apple.systemsettings:com.apple.Appearance-Settings.extension"),
            ].compactMap { $0 }
        case .screenTime:
            return [
                u("x-apple.systempreferences:com.apple.preference.screentime"),
                u("x-apple.systemsettings:com.apple.Screen-Time-Settings.extension"),
            ].compactMap { $0 }
        case .sharing:
            return [
                u("x-apple.systempreferences:com.apple.preferences.sharing"),
                u("x-apple.systemsettings:com.apple.Sharing-Settings.extension"),
            ].compactMap { $0 }
        case .softwareUpdate:
            return [
                u("x-apple.systempreferences:com.apple.preferences.softwareupdate"),
                u("x-apple.systemsettings:com.apple.Software-Update-Settings.extension"),
            ].compactMap { $0 }
        case .siri:
            return [
                u("x-apple.systempreferences:com.apple.preference.speech"),
                u("x-apple.systemsettings:com.apple.Siri-Settings.extension"),
            ].compactMap { $0 }
        case .wallpaper:
            return [
                u("x-apple.systemsettings:com.apple.Wallpaper-Settings.extension"),
                u("x-apple.systempreferences:com.apple.preference.desktopscreeneffect"),
            ].compactMap { $0 }
        }
    }

    private static func openSystemSettingsApplication() -> Bool {
        let paths = [
            "/System/Applications/System Settings.app",
            "/Applications/System Settings.app",
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            if NSWorkspace.shared.open(URL(fileURLWithPath: p)) { return true }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systemsettings") {
            return NSWorkspace.shared.open(url)
        }
        return false
    }

    static func openAppStoreSearch(term raw: String) -> Bool {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: " &:+")
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) else { return false }

        let urlStrings = [
            "macappstore://apps.apple.com/search?term=\(encoded)",
            "macappstore://itunes.apple.com/search?term=\(encoded)",
            "itms-apps://itunes.apple.com/search?term=\(encoded)",
            "https://apps.apple.com/search?term=\(encoded)",
        ]
        for s in urlStrings {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return true }
        }
        let appPaths = [
            "/System/Applications/App Store.app",
            "/Applications/App Store.app",
        ]
        for p in appPaths where FileManager.default.fileExists(atPath: p) {
            if NSWorkspace.shared.open(URL(fileURLWithPath: p)) { return true }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") {
            return NSWorkspace.shared.open(url)
        }
        return false
    }

    static func openGoogleSearchInChrome(query raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "www.google.com"
        parts.path = "/search"
        parts.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = parts.url else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Google Chrome", url.absoluteString]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Pane inference

    /// Infer a settings pane from normalized user text (already lowercased / cleaned).
    ///
    /// Two-gate design:
    /// - **With "settings" keyword**: returns `.root` if no pane keyword matched (still opens System Settings).
    /// - **Bare nav** ("open X" without "settings"): only matches unambiguous pane keywords that have no same-named app.
    ///   Falls through (returns nil) for generic app names like "chrome", "safari", "word".
    static func inferSettingsPane(from normalized: String) -> OrbitSystemSettingsPane? {
        let n = normalized
        let hasSettingsWord =
            n.contains("system settings") || n.contains("system preferences")
            || n.contains("preferences") || n.contains("settings")
        let hasNavWord =
            n.contains("open") || n.contains("go to") || n.contains("take me") || n.contains("show") || n.contains("bring up")

        // Gate 1: has "settings"/"preferences" + a navigation word → broad match, fallback to .root
        let isNavWithSettings = hasSettingsWord && hasNavWord
        // Gate 2: bare navigation word, no settings keyword → only match specific pane words (no app has these names)
        let isBareNav = hasNavWord && !hasSettingsWord

        guard isNavWithSettings || isBareNav else { return nil }

        // Pane detection — most specific first
        if n.contains("notif") { return .notifications }
        if n.contains("focus") {
            // Only route to Focus settings pane, not "turn focus on" commands which have their own handler
            if isNavWithSettings || isBareNav { return .focus }
        }
        if n.contains("screen time") || n.contains("screentime") { return .screenTime }
        if n.contains("software update") || n.contains("system update") { return .softwareUpdate }
        if n.contains("wallpaper") || n.contains("background") || n.contains("desktop picture") { return .wallpaper }
        if n.contains("siri") || n.contains("spotlight") { return .siri }
        if n.contains("sharing") { return .sharing }
        if n.contains("appearance") || n.contains("dark mode settings") || n.contains("light mode settings") {
            return .appearance
        }
        if n.contains("wi fi") || n.contains("wifi") { return .wifi }
        if n.contains("network") && !n.contains("wifi") { return .network }
        if n.contains("bluetooth") { return .bluetooth }
        if n.contains("battery") || n.contains("power") { return .battery }
        if n.contains("display") || n.contains("displays") || n.contains("screen brightness") || n.contains("resolution") {
            return .displays
        }
        if n.contains("sound") || n.contains("audio") || (n.contains("volume") && n.contains("settings")) {
            return .sound
        }
        if n.contains("privacy") || n.contains("security") { return .privacy }
        if n.contains("accessibility") { return .accessibility }
        if n.contains("login item") || n.contains("login items") || n.contains("open at login") { return .loginItems }
        if n.contains("storage") || n.contains("icloud storage") { return .storage }
        if n.contains("desktop") && n.contains("dock") { return .desktopDock }
        if n.contains("keyboard") { return .keyboard }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("mouse") { return .mouse }
        if n.contains("general") || n.contains("about this mac") || n.contains("about mac") { return .general }

        // Only fall back to root if the user explicitly mentioned "settings"/"preferences"
        return isNavWithSettings ? .root : nil
    }

    static func extractAppStoreSearchQuery(from normalized: String) -> String? {
        let ns = normalized as NSString
        let full = NSRange(location: 0, length: ns.length)
        let patterns = [
            // "search call of duty in app store"
            #"(?:^|\b)search\s+(.+?)\s+in\s+(?:the\s+)?app\s+store\s*$"#,
            #"(?:^|\b)find\s+(.+?)\s+in\s+(?:the\s+)?app\s+store\s*$"#,
            #"(?:^|\b)search\s+in\s+(?:the\s+)?app\s+store\s+for\s+(.+)$"#,
            #"(?:^|\b)(?:search|find)\s+(?:the\s+)?app\s+store\s+for\s+(.+)$"#,
            #"(?:^|\b)app\s+store\s+search\s+for\s+(.+)$"#,
            #"(?:^|\b)app\s+store\s+search\s+(.+)$"#,
            #"(?:^|\b)search\s+app\s+store\s+for\s+(.+)$"#,
            #"(?:^|\b)find\s+(.+)\s+on\s+(?:the\s+)?app\s+store\s*$"#,
        ]
        for pattern in patterns {
            guard let r = try? NSRegularExpression(pattern: pattern),
                  let m = r.firstMatch(in: normalized, range: full),
                  m.numberOfRanges >= 2,
                  let range = Range(m.range(at: 1), in: normalized)
            else { continue }
            let s = String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return nil
    }

    static func extractGoogleChromeSearchQuery(from normalized: String) -> String? {
        let patterns = [
            #"(?:^|\b)search\s+google\s+for\s+(.+)$"#,
            #"(?:^|\b)google\s+search\s+for\s+(.+)$"#,
            #"(?:^|\b)chrome\s+search\s+for\s+(.+)$"#,
            #"(?:^|\b)search\s+in\s+chrome\s+for\s+(.+)$"#,
            #"(?:^|\b)google\s+(.+)\s+in\s+chrome$"#,
        ]
        for pattern in patterns {
            if let r = try? NSRegularExpression(pattern: pattern),
               let m = r.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
               m.numberOfRanges >= 2,
               let range = Range(m.range(at: 1), in: normalized)
            {
                let s = String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { return s }
            }
        }
        return nil
    }
}
