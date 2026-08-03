//
//  FoundationModelsOrbitRouter.swift
//  ORBITMac
//
//  Tier-1 on-device routing via Apple Foundation Models (guided generation).
//  Falls back to KeywordOrbitRouter in OrbitRouteClassifier if unavailable or on error.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@Generable(description: "ORBIT routing tier for the next model hop")
struct ORBITRouteDecision {
    @Guide(description: "Exactly one of: local, cloud, tooling")
    var tier: String
}

@available(macOS 26.0, *)
enum FoundationModelsOrbitRouter {
    private static let instructions = """
    You are a tiny router for ORBIT, Ayush’s personal AI companion.
    Classify the user’s latest message into exactly one tier:

    - tooling — calendar, reminders, schedule, events, todos, tasks, deadlines; questions about this week, next week, or what the user has coming up
    - cloud — deep research, compare papers, citations, latest news, internet research, long multi-source analysis
    - local — everything else (chat, feelings, coding help, short planning, ORBIT itself)

    If the message asks what is on the user’s calendar or schedule (including “next week” / “this week”), choose tooling — not local.
    Otherwise be conservative: prefer local when unsure. Output only the structured tier field.
    """

    static func classify(_ message: String) async throws -> OrbitRoute {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: message,
            generating: ORBITRouteDecision.self,
            includeSchemaInPrompt: true
        )
        return normalizeTier(response.content.tier)
    }

    private static func normalizeTier(_ raw: String) -> OrbitRoute {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch t {
        case "cloud": return .cloud
        case "tooling": return .tooling
        case "local": return .local
        default:
            return .local
        }
    }
}
#endif
