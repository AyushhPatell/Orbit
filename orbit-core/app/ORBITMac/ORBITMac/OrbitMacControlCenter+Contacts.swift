//
//  OrbitMacControlCenter+Contacts.swift
//  ORBITMac
//
//  FaceTime / audio call / iMessage intent detection and execution.
//
//  Call flow: find contact → open facetime:// URL (user still taps Call in FaceTime UI — not auto-dial)
//  Message flow: find contact → propose draft → require confirmation → send via Messages AppleScript
//

import AppKit
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Intent detection

    static func isFaceTimeVideoIntent(_ normalized: String) -> Bool {
        let triggers = [
            "facetime ", "face time ",
            "video call ", "video chat ",
            "call on facetime", "facetime call",
        ]
        if triggers.contains(where: { normalized.hasPrefix($0) || normalized.contains(" " + $0) }) { return true }
        // "call X on facetime"
        return normalized.range(of: #"\bcall\b.{1,30}\bfacetime\b"#, options: .regularExpression) != nil
    }

    static func isFaceTimeAudioIntent(_ normalized: String) -> Bool {
        let triggers = [
            "audio call ", "audio facetime ",
            "facetime audio ", "call audio ",
            "phone call ", "ring ", "dial ",
        ]
        if triggers.contains(where: { normalized.hasPrefix($0) }) { return true }
        // "call X" alone — default to FaceTime audio on Mac (no cellular)
        // Only matches when NOT already caught by video intent
        let callPattern = #"^call\s+([a-z][a-z\s]{1,30})$"#
        return normalized.range(of: callPattern, options: .regularExpression) != nil
    }

    static func isMessageIntent(_ normalized: String) -> Bool {
        let triggers = [
            "message ", "text ", "imessage ",
            "send a message to ", "send message to ",
            "msg ",
        ]
        return triggers.contains(where: { normalized.hasPrefix($0) })
    }

    // MARK: - Target extraction

    /// Extracts the contact name from "call John", "FaceTime Priya", "video call mom", etc.
    static func extractCallTarget(from normalized: String) -> String? {
        let prefixes = [
            "facetime audio ", "face time audio ",
            "audio facetime ", "facetime call ",
            "facetime ", "face time ",
            "video call ", "video chat ",
            "audio call ", "phone call ",
            "ring ", "dial ", "call ",
        ].sorted { $0.count > $1.count }

        var s = normalized
        for prefix in prefixes where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        // Strip trailing "on facetime", "please", "now"
        s = s
            .replacingOccurrences(of: #"\bon facetime\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(please|now|right now)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !s.isEmpty, s.split(separator: " ").count <= 4 else { return nil }
        return s
    }

    /// Extracts (contactName, messageBody) from "message dad: I'm on my way"
    static func extractMessageComponents(from text: String) -> (name: String, body: String)? {
        let lower = text.lowercased()
        let prefixes = [
            "send a message to ", "send message to ",
            "imessage ", "message ", "text ", "msg ",
        ].sorted { $0.count > $1.count }

        var rest = lower
        for prefix in prefixes where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        guard !rest.isEmpty else { return nil }

        // Expect "contact name: body" or "contact name saying body"
        if let colonRange = rest.range(of: ":") {
            let namePart = String(rest[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Recover body casing from original text
            let bodyStart = text.index(text.startIndex, offsetBy: min(text.count, lower.distance(from: lower.startIndex, to: colonRange.upperBound)))
            let body = String(text[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !namePart.isEmpty, !body.isEmpty else { return nil }
            return (namePart, body)
        }
        // "message dad saying I'm on my way"
        if let sayingRange = rest.range(of: " saying ") {
            let namePart = String(rest[..<sayingRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(rest[sayingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !namePart.isEmpty, !body.isEmpty else { return nil }
            return (namePart, body)
        }
        // No message body found — just a name → open conversation
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    // MARK: - Execution

    static func faceTimeCall(contactName: String, audioOnly: Bool) async throws -> String {
        let service = OrbitContactsService.shared
        await service.requestAccessIfNeeded()

        guard let contact = try service.findContact(named: contactName) else {
            throw ControlError.actionFailed("I couldn\u{2019}t find \u{201C}\(contactName)\u{201D} in your contacts.")
        }
        let displayName = service.displayName(for: contact)

        // Prefer phone number; fall back to email (FaceTime works with both)
        let identifier = service.bestPhone(for: contact) ?? service.bestEmail(for: contact)
        guard let id = identifier else {
            throw ControlError.actionFailed(
                "\(displayName) is in your contacts but has no phone number or email address I can call."
            )
        }

        // Encode identifier for URL — phone numbers need special handling
        let encoded = id
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id

        let scheme = audioOnly ? "facetime-audio" : "facetime"
        guard let url = URL(string: "\(scheme)://\(encoded)") else {
            throw ControlError.actionFailed("Couldn\u{2019}t build FaceTime URL for \(displayName).")
        }

        let opened = NSWorkspace.shared.open(url)
        guard opened else {
            throw ControlError.actionFailed("macOS couldn\u{2019}t open FaceTime. Make sure FaceTime is installed and signed in.")
        }
        let callType = audioOnly ? "audio call" : "FaceTime call"
        return "Opening \(callType) with \(displayName)."
    }

    static func openMessageConversation(contactName: String, body: String) async throws -> String {
        let service = OrbitContactsService.shared
        await service.requestAccessIfNeeded()

        guard let contact = try service.findContact(named: contactName) else {
            throw ControlError.actionFailed("I couldn\u{2019}t find \u{201C}\(contactName)\u{201D} in your contacts.")
        }
        let displayName = service.displayName(for: contact)
        let identifier = service.bestPhone(for: contact) ?? service.bestEmail(for: contact)

        if body.isEmpty {
            // No body — just open the conversation
            if let id = identifier,
               let url = URL(string: "imessage://\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)") {
                NSWorkspace.shared.open(url)
            } else {
                try runAppleScript("tell application \"Messages\" to activate")
            }
            return "Opened Messages conversation with \(displayName)."
        }

        // Has body — propose the message, require confirmation
        guard let id = identifier else {
            throw ControlError.actionFailed(
                "\(displayName) has no phone number or email in your contacts."
            )
        }
        OrbitLocalActionPendingStore.shared.setMessageProposal(
            recipient: displayName, identifier: id, body: body
        )
        return """
        Message ready for \(displayName):
        "\(body)"

        Reply yes send message to send, or cancel.
        """
    }

    /// Called from handlePendingLocalActions when the user confirms "yes send message".
    static func confirmAndSendMessage() throws -> String {
        guard let (name, id, body) = OrbitLocalActionPendingStore.shared.messageProposalPending() else {
            return "No message is pending."
        }
        OrbitLocalActionPendingStore.shared.clearMessageProposal()

        let safeId   = id.replacingOccurrences(of: "\"", with: "")
        let safeBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // AppleScript: send via Messages using iMessage service
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(safeId)" of targetService
            send "\(safeBody)" to targetBuddy
        end tell
        """
        do {
            try runAppleScript(script)
            return "Sent \u{2014} message delivered to \(name)."
        } catch {
            // Fallback: open Messages to the contact so user can send manually
            if let url = URL(string: "imessage://\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)") {
                NSWorkspace.shared.open(url)
            }
            return "Couldn\u{2019}t send automatically \u{2014} opened Messages to \(name) so you can send it manually."
        }
    }
}
