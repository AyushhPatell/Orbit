//
//  OrbitRouteClassifier.swift
//  ORBITMac
//
//  Day 5 — chooses Tier hint: Foundation Models when OS supports it, else keyword router.
//

import Foundation

enum OrbitRouteClassifier {
    enum Source: String {
        case foundationModels
        case keyword
    }

    /// Last classification source (for UI/debug).
    static var lastSource: Source = .keyword

    @MainActor
    static func classify(_ message: String) async -> OrbitRoute {
        let keywordRoute = KeywordOrbitRouter.classify(message)
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let fmRoute = try await FoundationModelsOrbitRouter.classify(message)
                lastSource = .foundationModels
                // Keywords are deterministic for calendar/schedule; FM sometimes picks "local" and drops the tool snapshot.
                if keywordRoute == .tooling {
                    return .tooling
                }
                return fmRoute
            } catch {
                lastSource = .keyword
                return keywordRoute
            }
        }
#endif
        lastSource = .keyword
        return keywordRoute
    }
}
