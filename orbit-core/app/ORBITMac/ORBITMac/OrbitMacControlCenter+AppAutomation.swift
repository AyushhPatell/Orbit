//
//  OrbitMacControlCenter+AppAutomation.swift
//  ORBITMac
//
//  App-specific automation (Terminal at folder) and email reading via Outlook/Mail AppleScript.
//

import AppKit
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Terminal at folder

    static func extractTerminalAtFolderTarget(from normalized: String) -> String? {
        let patterns = [
            #"\b(?:open\s+)?terminal\s+(?:in|at|for)\s+(?:the\s+|my\s+)?(.+)"#,
            #"\b(?:open\s+)?(?:iterm|iterm2)\s+(?:in|at|for)\s+(?:the\s+|my\s+)?(.+)"#,
            #"\b(?:open\s+)?(?:a\s+)?terminal\s+(?:in|at)\s+(?:the\s+|my\s+)?(.+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: normalized)
            else { continue }
            let folder = String(normalized[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !folder.isEmpty { return folder }
        }
        return nil
    }

    static func openTerminalAtFolder(_ folderName: String) throws -> String {
        let home = realUserHomeForFiles()
        let lower = folderName.lowercased()
        let path: URL
        switch lower {
        case "desktop":   path = home.appendingPathComponent("Desktop")
        case "documents": path = home.appendingPathComponent("Documents")
        case "downloads": path = home.appendingPathComponent("Downloads")
        case "home", "~": path = home
        default:
            // Search Desktop/Documents/Downloads for a matching subfolder
            let locations = ["Desktop", "Documents", "Downloads"]
            var found: URL?
            for loc in locations {
                let candidate = home.appendingPathComponent(loc).appendingPathComponent(folderName)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    found = candidate
                    break
                }
            }
            guard let f = found else {
                throw ControlError.actionFailed(
                    "I couldn\u{2019}t find a folder named \u{201C}\(folderName)\u{201D} in Desktop, Documents, or Downloads."
                )
            }
            path = f
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ControlError.actionFailed("Folder not found: \(tildeDisplayPath(for: path))")
        }
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(shellEscape(path.path))"
        end tell
        """
        try runAppleScript(script)
        return "Opened Terminal in \(tildeDisplayPath(for: path))."
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Email reading (Outlook + Mail.app)

    static func isReadEmailIntent(_ normalized: String) -> Bool {
        let phrases = [
            "read my email", "read my emails", "read my mail", "read my mails",
            "check my email", "check my emails", "check my mail", "check my mails",
            "check my inbox", "check email", "check emails", "check mail", "check mails",
            "any new email", "any new emails", "any new mail", "any new mails",
            "show my email", "show my emails", "show my inbox",
            "what emails do i have", "do i have any email", "do i have any emails",
            "do i have any mail", "do i have any mails",
            "unread emails", "unread mail", "new emails", "new mail",
            "my inbox", "open my inbox", "email update", "mail update",
            "read emails", "read email", "read mail", "read mails",
            "any emails", "any mail", "check inbox",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    static func readRecentEmails() throws -> String {
        // Apple Mail has full AppleScript support — try it first.
        if let _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
            if let result = try? readAppleMailEmails() { return result }
        }
        // New Outlook (v16+) doesn't expose account messages via AppleScript.
        // Activate Outlook so the user can see their inbox, then tell them to use screen reading.
        if let outlookURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") {
            try? NSWorkspace.shared.openApplication(at: outlookURL, configuration: .init())
            return "I\u{2019}ve opened Outlook for you. New Outlook doesn\u{2019}t support reading emails programmatically. You can say \u{201C}what\u{2019}s on my screen\u{201D} once your inbox is visible and I\u{2019}ll read it for you."
        }
        throw ControlError.actionFailed("No email app found. Install Outlook or Apple Mail.")
    }

    private static func readAppleMailEmails() throws -> String {
        let script = """
        tell application "Mail"
            set msgs to messages of inbox
            set msgCount to count of msgs
            if msgCount is 0 then return ""
            if msgCount > 5 then set msgCount to 5
            set res to ""
            repeat with i from 1 to msgCount
                set msg to item i of msgs
                set msgSubject to subject of msg
                set msgSender to (sender of msg)
                set isRead to (read status of msg)
                set readTag to ""
                if not isRead then set readTag to " [NEW]"
                set res to res & msgSender & ": " & msgSubject & readTag & linefeed
            end repeat
            return res
        end tell
        """
        let result = try runAppleScriptReturningString(script)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Your inbox is empty \u{2014} no recent messages."
        }
        return "Here are your latest emails:\n\n\(trimmed)"
    }
}
