//
//  OrbitCommunicationDrafting.swift
//  ORBITMac
//
//  Communication drafting (draft-only, never send) for email/Slack/Teams/follow-ups/status updates.
//

import AppKit
import Foundation

enum OrbitCommDraftChannel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case email = "Email"
    case slack = "Slack"
    case teams = "Teams"
    case meetingFollowUp = "Meeting Follow-up"
    case statusUpdate = "Status Update"
    case general = "General"

    var id: String { rawValue }
}

struct OrbitCommunicationDraftRequest: Sendable {
    let channel: OrbitCommDraftChannel
    let userInstruction: String
    let extraContext: String?
}

enum OrbitCommunicationDraftOutcome: Sendable {
    case none
    case message(String)
    case run(OrbitCommunicationDraftRequest)
}

@MainActor
final class OrbitCommunicationDraftIntentBroker {
    static let shared = OrbitCommunicationDraftIntentBroker()

    private var pending: OrbitCommunicationDraftRequest?
    private var pendingExpiresAt: Date?
    private let ttl: TimeInterval = 120

    private init() {}

    func process(_ rawText: String) -> OrbitCommunicationDraftOutcome {
        pruneExpired()
        let n = normalize(rawText)
        if let pending {
            if isCancelIntent(n) {
                clearPending()
                return .message("Okay — canceled communication drafting.")
            }
            if isConfirmIntent(n) {
                clearPending()
                return .run(pending)
            }
            return .message("I am waiting to draft your message. Reply yes draft it to confirm, or cancel.")
        }

        guard let req = parseDraftRequest(rawText: rawText, normalized: n) else { return .none }
        pending = req
        pendingExpiresAt = Date().addingTimeInterval(ttl)
        return .message(confirmText(for: req))
    }

    private func pruneExpired() {
        if let expiry = pendingExpiresAt, Date() > expiry { clearPending() }
    }

    private func clearPending() {
        pending = nil
        pendingExpiresAt = nil
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s.&+\\-']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isConfirmIntent(_ n: String) -> Bool {
        let snippets = ["yes draft it", "draft it", "yes", "go ahead", "confirm", "proceed", "yes run"]
        return snippets.contains(where: { n == $0 || n.contains($0) })
    }

    private func isCancelIntent(_ n: String) -> Bool {
        let snippets = ["cancel", "stop", "no", "nevermind", "never mind", "abort"]
        return snippets.contains(where: { n == $0 || n.contains($0) })
    }

    private func parseDraftRequest(rawText: String, normalized n: String) -> OrbitCommunicationDraftRequest? {
        let wantsDraft = n.contains("draft") || n.contains("write") || n.contains("compose") || n.contains("create")
        guard wantsDraft else { return nil }

        let channel: OrbitCommDraftChannel =
            if n.contains("slack") { .slack }
            else if n.contains("teams") || n.contains("microsoft teams") { .teams }
            else if n.contains("follow up") || n.contains("follow-up") || n.contains("meeting follow up") { .meetingFollowUp }
            else if n.contains("status update") || n.contains("update for team") { .statusUpdate }
            else if n.contains("email") || n.contains("mail") { .email }
            else { .general }

        // Avoid hijacking clipboard actions like "draft a reply [to what I copied]".
        // Only fire when a clear communication channel/tool is mentioned.
        let hasChannelContext = n.contains("email") || n.contains("mail")
            || n.contains("slack") || n.contains("teams")
            || n.contains("follow up") || n.contains("follow-up") || n.contains("status update")
        // "reply" alone is ambiguous — paired with a channel it's comm, otherwise clipboard handles it.
        let replyWithChannel = n.contains("reply") && hasChannelContext
        guard hasChannelContext || replyWithChannel else { return nil }

        return OrbitCommunicationDraftRequest(channel: channel, userInstruction: rawText, extraContext: nil)
    }

    private func confirmText(for req: OrbitCommunicationDraftRequest) -> String {
        "I can draft a \(req.channel.rawValue.lowercased()) message based on your request.\n\nReply yes draft it to confirm, or cancel."
    }
}

enum OrbitCommunicationDraftRunner {
    static func run(
        _ req: OrbitCommunicationDraftRequest,
        sessionID: String,
        includeMemoryDebug: Bool
    ) async throws -> OrbitWebActionRunResult {
        let clipboard = clipboardTextIfMentioned(req.userInstruction)
        let prompt = composePrompt(req: req, clipboard: clipboard)
        let clock = OrbitClientClock.snapshotForAPI()
        let result = try await OrbitAPI().chat(
            sessionID: sessionID,
            message: prompt,
            routeHint: .local,
            clientLocalISO8601: clock.iso8601,
            clientTimeZoneId: clock.timeZoneId,
            includeMemoryDebug: includeMemoryDebug ? true : nil
        )
        return OrbitWebActionRunResult(reply: result.reply, route: result.route, model: result.model)
    }

    private static func composePrompt(req: OrbitCommunicationDraftRequest, clipboard: String?) -> String {
        let toneGuide: String = switch req.channel {
        case .email:
            "Professional, concise, and clear."
        case .slack:
            "Concise, friendly, and action-oriented."
        case .teams:
            "Professional and collaborative; concise."
        case .meetingFollowUp:
            "Summarize decisions, owners, and next steps."
        case .statusUpdate:
            "Structured update: progress, blockers, next steps."
        case .general:
            "Clear and practical."
        }

        let contextBlock: String = {
            var blocks: [String] = []
            if let extra = req.extraContext?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
                blocks.append("Additional context:\n\(extra)")
            }
            if let clipboard, !clipboard.isEmpty {
                blocks.append("Copied context:\n\(clipboard)")
            }
            return blocks.isEmpty ? "No extra context provided." : blocks.joined(separator: "\n\n")
        }()

        return """
        Draft a \(req.channel.rawValue) communication message from the request below.
        This is draft-only. Do not claim the message was sent.
        Style: \(toneGuide)

        User request:
        \(req.userInstruction)

        \(contextBlock)

        Output only the draft message content (no analysis).
        """
    }

    private static func clipboardTextIfMentioned(_ request: String) -> String? {
        let n = request.lowercased()
        guard n.contains("clipboard") || n.contains("copied") || n.contains("copied text") || n.contains("copied email") else {
            return nil
        }
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return String(s.prefix(4000))
        }
        if let data = pb.data(forType: .rtf),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           )
        {
            let t = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return String(t.prefix(4000)) }
        }
        return nil
    }
}

