//
//  WebActionService.swift
//  ORBITMac
//
//  Semi-automated browser actions with explicit user confirmation.
//

import AppKit
import Foundation

enum WebActionService {
    struct PageSnapshot: Sendable {
        let finalURL: URL
        let title: String?
        let text: String
    }

    static func normalizeURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), let scheme = direct.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
            return direct
        }
        if trimmed.contains(" "), !trimmed.contains(".") { return nil }
        if let withScheme = URL(string: "https://\(trimmed)") {
            return withScheme
        }
        return nil
    }

    static func searchURL(for query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var comps = URLComponents(string: "https://www.google.com/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: q)]
        return comps?.url
    }

    @discardableResult
    static func openInBrowser(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    // Keep default small enough so composed /chat payload stays under backend message limit (8000 chars).
    static func fetchPageSnapshot(url: URL, maxChars: Int = 4_500) async throws -> PageSnapshot {
        var req = URLRequest(url: url)
        req.timeoutInterval = 14
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ORBITMac/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<400 ~= http.statusCode else {
            throw NSError(domain: "WebActionService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Page request failed."])
        }
        guard let finalURL = http.url else {
            throw NSError(domain: "WebActionService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Page URL is invalid."])
        }
        let mime = (http.value(forHTTPHeaderField: "content-type") ?? "").lowercased()

        var title: String?
        var text = ""
        if mime.contains("text/html") || mime.contains("application/xhtml") || mime.isEmpty {
            if let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            ) {
                text = attributed.string
            } else {
                text = String(data: data, encoding: .utf8) ?? ""
            }
            title = extractHTMLTitle(from: String(data: data, encoding: .utf8) ?? "")
        } else {
            text = String(data: data, encoding: .utf8) ?? ""
        }

        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            throw NSError(domain: "WebActionService", code: 3, userInfo: [NSLocalizedDescriptionKey: "No readable text found on that page."])
        }
        let clipped = String(cleaned.prefix(maxChars))
        return PageSnapshot(finalURL: finalURL, title: title, text: clipped)
    }

    private static func extractHTMLTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = html as NSString
        guard let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1
        else { return nil }
        let raw = ns.substring(with: m.range(at: 1))
        let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

