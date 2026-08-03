//
//  OrbitMacControlCenter+Utilities.swift
//  ORBITMac
//
//  Shared low-level helpers used across OrbitMacControlCenter extensions.
//

import AppKit
import Darwin
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Path helpers

    /// Real user home (e.g. /Users/you). FileManager.homeDirectoryForCurrentUser is the sandbox container when App Sandbox is on.
    static func realUserHomeForFiles() -> URL {
        guard let pw = getpwuid(getuid()) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let path = String(cString: pw.pointee.pw_dir)
        guard !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func tildeDisplayPath(for url: URL) -> String {
        let homePath = realUserHomeForFiles().path
        let p = url.path
        // Show iCloud Drive paths with a friendly prefix
        let iCloudRoot = homePath + "/Library/Mobile Documents/com~apple~CloudDocs"
        if p.hasPrefix(iCloudRoot) {
            return "iCloud Drive" + p.dropFirst(iCloudRoot.count)
        }
        if p.hasPrefix(homePath) {
            return "~" + p.dropFirst(homePath.count)
        }
        return p
    }

    static func openFolderInFinder(_ folderURL: URL, label: String) throws -> String {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            throw ControlError.actionFailed(
                "I couldn't find your \(label) folder at \(tildeDisplayPath(for: folderURL))."
            )
        }
        let opened = NSWorkspace.shared.open(folderURL)
        if !opened {
            throw ControlError.actionFailed(
                "macOS blocked opening \(label) (\(tildeDisplayPath(for: folderURL))). Enable access for ORBITMac under System Settings \u{2192} Privacy & Security \u{2192} Files and Folders (Downloads / Documents / Desktop), then try again."
            )
        }
        return "Opened \(label) (\(tildeDisplayPath(for: folderURL)))."
    }

    // MARK: - Text normalization

    /// Rewrites a pronoun command into its explicit form using the last system feature ORBIT
    /// touched: after "turn off wifi", "turn it back on" becomes "turn wifi on".
    ///
    /// Runs before parsing so the existing phrase matchers handle it unchanged — which means it
    /// works instantly and **offline**, with no brain call. Returns nil when there is nothing to
    /// resolve, so ordinary commands are untouched.
    @MainActor
    static func resolveSystemPronoun(in normalized: String) -> String? {
        guard let target = OrbitConversationMemory.shared.lastSystemTarget() else { return nil }

        // Must be a short toggle command: a leading toggle verb, a pronoun, and no named subject.
        // The verb requirement matters — without it "is it done" matches (\"done\" contains "on")
        // and would switch wi-fi on.
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count <= 6 else { return nil }
        let toggleVerbs = ["turn ", "switch ", "put ", "set ", "make "]
        guard toggleVerbs.contains(where: { normalized.hasPrefix($0) }) else { return nil }
        guard normalized.range(of: #"\b(it|that|this)\b"#, options: .regularExpression) != nil else { return nil }
        // If the user already named a subject, there is nothing ambiguous to fix.
        let namedTargets = ["wifi", "wi fi", "bluetooth", "volume", "brightness", "dark mode",
                            "focus", "do not disturb", "music", "sound", "screen"]
        guard !namedTargets.contains(where: { normalized.contains($0) }) else { return nil }

        // Word-boundary matching only — substrings hide inside ordinary words ("done", "upset").
        func mentions(_ options: String) -> Bool {
            normalized.range(of: "\\b(\(options))\\b", options: .regularExpression) != nil
        }
        let wantsOff = mentions("off|down|mute|lower|dim|decrease|darker|quieter")
        let wantsOn = mentions("on|up|raise|increase|brighten|unmute|louder|brighter")
        guard wantsOff != wantsOn else { return nil }   // neither, or contradictory
        let state = wantsOff ? "off" : "on"

        switch target {
        case "wifi": return "turn wifi \(state)"
        case "bluetooth": return "turn bluetooth \(state)"
        case "dark mode": return state == "on" ? "turn on dark mode" : "turn off dark mode"
        case "focus": return state == "on" ? "turn on focus mode" : "turn off focus mode"
        case "volume": return state == "on" ? "volume up" : "volume down"
        case "brightness": return state == "on" ? "brightness up" : "brightness down"
        default: return nil
        }
    }

    static func normalize(_ text: String) -> String {
        var t = text.lowercased()
        t = t.replacingOccurrences(of: "wi-fi", with: "wifi")
        t = t.replacingOccurrences(of: "wi fi", with: "wifi")
        t = t.replacingOccurrences(of: "blue-tooth", with: "bluetooth")
        t = t.replacingOccurrences(of: "blue tooth", with: "bluetooth")
        return t
            .replacingOccurrences(of: "[^a-z0-9\\s.&+\\-']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func cleanedUserToken(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\b(folder|project|named)\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayName(for rawName: String) -> String {
        rawName
            .split(separator: " ")
            .map { token in
                guard let first = token.first else { return String(token) }
                return String(first).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    // MARK: - Process execution

    @discardableResult
    static func runCommand(
        _ launchPath: String,
        _ args: [String],
        failOnNonZero: Bool = true
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            let ns = error as NSError
            throw ControlError.actionFailed(
                "Could not start \(launchPath) (\(ns.domain) \(ns.code): \(ns.localizedDescription))."
            )
        }
        // Drain stdout/stderr while the process runs — waiting for exit first fills the pipe buffer
        // (~64KB) and deadlocks the child (common with mdfind on broad queries).
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        var outData = Data()
        var errData = Data()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outHandle.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errHandle.readDataToEndOfFile()
            drainGroup.leave()
        }
        process.waitUntilExit()
        drainGroup.wait()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        if failOnNonZero, process.terminationStatus != 0 {
            let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ControlError.actionFailed(detail.isEmpty ? "Command failed." : detail)
        }
        return (out, err, process.terminationStatus)
    }

    static func runAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw ControlError.actionFailed("Could not compile AppleScript.")
        }
        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = (errorDict[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "AppleScript failed."
            throw ControlError.actionFailed(message)
        }
    }

    static func runAppleScriptReturningString(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw ControlError.actionFailed("Could not compile AppleScript.")
        }
        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let message = (errorDict[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "AppleScript failed."
            throw ControlError.actionFailed(message)
        }
        return result.stringValue ?? ""
    }
}
