//
//  OrbitWebActionIntent.swift
//  ORBITMac
//
//  Voice/text intents for semi-automated web actions with confirmation.
//

import Foundation

enum OrbitWebActionIntent: Sendable {
    case openSite(URL)
    case searchWeb(query: String, url: URL)
    case summarizePage(URL)
    case draftFromPage(url: URL, request: String?)
}

@MainActor
final class OrbitWebActionIntentBroker {
    static let shared = OrbitWebActionIntentBroker()

    enum Outcome {
        case none
        case message(String)
        case run(OrbitWebActionIntent)
    }

    private var pendingIntent: OrbitWebActionIntent?
    private var pendingExpiresAt: Date?
    private let ttl: TimeInterval = 120

    private init() {}

    func process(_ rawText: String) -> Outcome {
        pruneExpired()
        let normalized = normalize(rawText)
        if let pending = pendingIntent {
            if isCancelIntent(normalized) {
                clearPending()
                return .message("Okay — canceled web action.")
            }
            if isConfirmIntent(normalized) {
                clearPending()
                return .run(pending)
            }
            return .message("I am waiting to run the web action. Reply yes run web action to confirm, or cancel.")
        }

        guard let intent = parseIntent(from: rawText, normalized: normalized) else {
            return .none
        }
        pendingIntent = intent
        pendingExpiresAt = Date().addingTimeInterval(ttl)
        return .message(confirmText(for: intent))
    }

    private func pruneExpired() {
        if let expiry = pendingExpiresAt, Date() > expiry {
            clearPending()
        }
    }

    private func clearPending() {
        pendingIntent = nil
        pendingExpiresAt = nil
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s.:/?&=_%+\\-']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isConfirmIntent(_ n: String) -> Bool {
        let snippets = [
            "yes run web action", "run web action", "yes run it", "yes do it",
            "confirm", "go ahead", "proceed", "yes",
        ]
        return snippets.contains(where: { n == $0 || n.contains($0) })
    }

    private func isCancelIntent(_ n: String) -> Bool {
        let snippets = ["cancel", "stop", "no", "never mind", "nevermind", "abort"]
        return snippets.contains(where: { n == $0 || n.contains($0) })
    }

    private func parseIntent(from raw: String, normalized n: String) -> OrbitWebActionIntent? {
        // Search intent: "search web for <query>"
        if let q = firstCapture(in: n, pattern: #"(?:^|\b)(?:search|look up|find)\s+(?:the\s+)?web\s+for\s+(.+)$"#) {
            let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty, let url = WebActionService.searchURL(for: query) {
                return .searchWeb(query: query, url: url)
            }
        }

        guard let url = extractURL(from: raw) else { return nil }

        // Open site intent
        if n.contains("open site") || n.contains("open website") || n.contains("open this site") || n.contains("open this page") {
            return .openSite(url)
        }
        // Summarize page intent
        if n.contains("summarize this page") || n.contains("summarise this page")
            || n.contains("summarize this site") || n.contains("summarize this article")
            || n.contains("summarize this url") || n.contains("summarize page")
        {
            return .summarizePage(url)
        }
        // Draft from page intent
        if n.contains("draft response from") || n.contains("draft reply from")
            || n.contains("write reply from") || n.contains("reply from this page")
        {
            return .draftFromPage(url: url, request: raw)
        }
        return nil
    }

    private func confirmText(for intent: OrbitWebActionIntent) -> String {
        switch intent {
        case .openSite(let url):
            return "I can open this site: \(url.absoluteString)\n\nReply yes run web action to confirm, or cancel."
        case .searchWeb(let query, _):
            return "I can search the web for: \(query)\n\nReply yes run web action to confirm, or cancel."
        case .summarizePage(let url):
            return "I can fetch and summarize this page: \(url.absoluteString)\n\nReply yes run web action to confirm, or cancel."
        case .draftFromPage(let url, _):
            return "I can draft a response from this page: \(url.absoluteString)\n\nReply yes run web action to confirm, or cancel."
        }
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private func extractURL(from raw: String) -> URL? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: (raw as NSString).length)
            if let match = detector.firstMatch(in: raw, range: range), let url = match.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            {
                return url
            }
        }
        return WebActionService.normalizeURL(from: raw)
    }
}

