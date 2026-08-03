//
//  OrbitWebActionRunner.swift
//  ORBITMac
//
//  Executes confirmed web actions.
//

import Foundation

struct OrbitWebActionRunResult: Sendable {
    let reply: String
    let route: String
    let model: String
}

enum OrbitWebActionRunner {
    static func run(
        _ action: OrbitWebActionIntent,
        sessionID: String,
        includeMemoryDebug: Bool
    ) async throws -> OrbitWebActionRunResult {
        switch action {
        case .openSite(let url):
            guard WebActionService.openInBrowser(url) else {
                throw NSError(domain: "WebActionRunner", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not open browser URL."])
            }
            return OrbitWebActionRunResult(
                reply: "Opened \(url.absoluteString)",
                route: "web-action",
                model: "macos-web"
            )
        case .searchWeb(let query, let url):
            guard WebActionService.openInBrowser(url) else {
                throw NSError(domain: "WebActionRunner", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not open browser search URL."])
            }
            return OrbitWebActionRunResult(
                reply: "Opened web search for “\(query)”.",
                route: "web-action",
                model: "macos-web"
            )
        case .summarizePage(let url):
            let page = try await WebActionService.fetchPageSnapshot(url: url)
            let msg = """
            Summarize this webpage for me in concise bullets.
            Focus on key facts, decisions, and next steps.

            Source URL: \(page.finalURL.absoluteString)
            Title: \(page.title ?? "(unknown)")

            --- Page text ---
            \(page.text)
            --- End page text ---
            """
            let clock = OrbitClientClock.snapshotForAPI()
            let result = try await OrbitAPI().chat(
                sessionID: sessionID,
                message: msg,
                routeHint: .local,
                clientLocalISO8601: clock.iso8601,
                clientTimeZoneId: clock.timeZoneId,
                includeMemoryDebug: includeMemoryDebug ? true : nil
            )
            return OrbitWebActionRunResult(reply: result.reply, route: result.route, model: result.model)
        case .draftFromPage(let url, let request):
            let page = try await WebActionService.fetchPageSnapshot(url: url)
            let msg = """
            Draft a response based on the webpage content below.
            \(request.map { "User request: \($0)" } ?? "If context is unclear, produce a short professional default draft.")

            Source URL: \(page.finalURL.absoluteString)
            Title: \(page.title ?? "(unknown)")

            --- Page text ---
            \(page.text)
            --- End page text ---
            """
            let clock = OrbitClientClock.snapshotForAPI()
            let result = try await OrbitAPI().chat(
                sessionID: sessionID,
                message: msg,
                routeHint: .local,
                clientLocalISO8601: clock.iso8601,
                clientTimeZoneId: clock.timeZoneId,
                includeMemoryDebug: includeMemoryDebug ? true : nil
            )
            return OrbitWebActionRunResult(reply: result.reply, route: result.route, model: result.model)
        }
    }
}

