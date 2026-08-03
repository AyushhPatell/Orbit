//
//  ShortcutsService.swift
//  ORBITMac
//
//  Lists and runs shortcuts via Apple’s `/usr/bin/shortcuts` CLI when available (accurate
//  success/failure). Falls back to the `shortcuts://` URL scheme when the CLI can’t run
//  (e.g. some sandboxed contexts) — handoff does not imply the shortcut finished.
//

import AppKit
import Foundation

struct ShortcutLibraryEntry: Identifiable, Hashable, Sendable {
    /// Stable identifier from Shortcuts (`shortcuts list --show-identifiers`).
    let id: String
    /// Display name (shown in UI; also used for URL handoff).
    let name: String
}

enum ShortcutRunOutcome: Sendable {
    /// `shortcuts run` exited 0.
    case completed
    /// URL scheme opened Shortcuts; actual run may still fail in that app.
    case handedOffToShortcutsApp
    case failed(message: String)
}

enum ShortcutsService {
    private static let executablePath = "/usr/bin/shortcuts"

    static var isCLIInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Runs a shortcut. Prefers `shortcuts run` with `runToken` (UUID or name). Uses `displayName`
    /// only for messaging and URL fallback.
    static func runShortcut(displayName: String, runToken: String, input: String?) async -> ShortcutRunOutcome {
        let token = runToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .failed(message: "Missing shortcut.")
        }

        if isCLIInstalled {
            do {
                var args = ["run", token]
                var tempFile: URL?
                defer {
                    if let tempFile {
                        try? FileManager.default.removeItem(at: tempFile)
                    }
                }
                if let input {
                    let trimmedIn = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedIn.isEmpty {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("orbit-shortcut-in-\(UUID().uuidString).txt")
                        try trimmedIn.write(to: url, atomically: true, encoding: .utf8)
                        tempFile = url
                        args.append(contentsOf: ["-i", url.path])
                    }
                }

                let result = try await runCLI(arguments: args)
                if result.status == 0 {
                    return .completed
                }
                let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = [err, out].first(where: { !$0.isEmpty })
                let suffix = detail.map { ": \($0)" } ?? ""
                return .failed(message: "Shortcut did not finish successfully\(suffix)")
            } catch {
                // Fall through to URL handoff.
            }
        }

        let handoffName = title.isEmpty ? token : title
        if openRunShortcutURL(named: handoffName, input: input) {
            return .handedOffToShortcutsApp
        }
        return .failed(message: "Could not run or open Shortcuts.")
    }

    /// All shortcuts in the library (sorted by localized name). Uses `--show-identifiers`.
    static func listShortcuts() async throws -> [ShortcutLibraryEntry] {
        guard isCLIInstalled else {
            throw ShortcutsCLIError.cliMissing
        }
        let result = try await runCLI(arguments: ["list", "--show-identifiers"])
        if result.status != 0 {
            let msg = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "Could not list shortcuts (exit \(result.status))."
            throw ShortcutsCLIError.commandFailed(msg)
        }
        let text = result.stdout
        var entries: [ShortcutLibraryEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let entry = parseListLine(String(line)) {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - URL fallback (no exit code)

    private static func openRunShortcutURL(named name: String, input: String?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var items: [URLQueryItem] = [URLQueryItem(name: "name", value: trimmed)]
        if let input {
            let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                items.append(URLQueryItem(name: "input", value: t))
            }
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = items

        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - CLI

    private struct CLIResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private enum ShortcutsCLIError: Error, LocalizedError {
        case cliMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliMissing:
                return "The shortcuts command-line tool was not found."
            case .commandFailed(let message):
                return message
            }
        }
    }

    private static func runCLI(arguments: [String]) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
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
                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    continuation.resume(
                        returning: CLIResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Parses `Name (UUID)` from `shortcuts list --show-identifiers`.
    private static func parseListLine(_ line: String) -> ShortcutLibraryEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard trimmed.hasSuffix(")"),
              let range = trimmed.range(of: " (", options: .backwards)
        else {
            return ShortcutLibraryEntry(id: trimmed, name: trimmed)
        }

        let name = String(trimmed[..<range.lowerBound])
        let uuidCandidate = trimmed[range.upperBound...].dropLast()
        let uuid = String(uuidCandidate)

        let uuidRegex = try? NSRegularExpression(
            pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        )
        let uuidNS = uuid as NSString
        if let uuidRegex,
           uuidRegex.firstMatch(in: uuid, range: NSRange(location: 0, length: uuidNS.length)) != nil {
            return ShortcutLibraryEntry(id: uuid, name: name)
        }

        return ShortcutLibraryEntry(id: trimmed, name: trimmed)
    }
}
