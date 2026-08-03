//
//  KeywordOrbitRouter.swift
//  ORBITMac
//
//  Mirrors `orbit-core/app/router.py` classify_route heuristics (keep in sync when you change Python).
//

import Foundation

enum KeywordOrbitRouter {
    static func classify(_ message: String) -> OrbitRoute {
        let text = message.lowercased()

        // System-action verbs and media commands: always handled locally by OrbitMacControlCenter.
        // Never route to LLM even if the target word ("calendar", "schedule") is a tooling keyword.
        // Filler-word patterns handle voice transcription that prepends "um", "uh", "okay", etc.
        let systemActionPrefixes = [
            #"^(?:close|quit|exit|kill|force quit|force-quit)\s+"#,
            #"^(?:please|can you|could you)\s+(?:close|quit|exit|kill|force quit)\s+"#,
            #"^(?:open|launch|start)\s+"#,
            #"^(?:please|can you|could you)\s+(?:open|launch|start)\s+"#,
            #"^(?:um+|uh+|yeah|ok(?:ay)?|right|so|well|now)\s+(?:close|quit|exit|kill|open|launch|start)\s+"#,
            // Browser navigation — always local
            #"^(?:go to|navigate to|take me to|head to|pull up|browse to|visit|jump to)\s+"#,
            #"^(?:search for|search|look up|look for|find)\s+.+\s+(?:in|on|using|with)\s+[a-z]"#,
            // Music — these should never go to LLM
            #"^(?:play|pause|skip|resume)\s+(?:music|song|track|something|some music)"#,
            #"^(?:next|previous|last)\s+(?:song|track)"#,
            // Brightness — "brighter", "dimmer" could match nothing else
            #"\b(?:brighter|dimmer|brightness)\b"#,
        ]
        if systemActionPrefixes.contains(where: {
            text.range(of: $0, options: .regularExpression) != nil
        }) {
            return .local
        }

        let toolKeywords = [
            "calendar", "reminder", "schedule", "event", "todo", "task",
            "this week", "next week", "coming up",
            "agenda", "appointment", "appointments",
            "what's on", "whats on", "what is on",
            "my day", "free today", "busy today",
        ]
        if toolKeywords.contains(where: { text.contains($0) }) {
            return .tooling
        }

        let cloudKeywords = [
            "deep research", "compare papers", "long analysis",
            "multi-step plan with citations", "internet research", "latest news",
        ]
        if cloudKeywords.contains(where: { text.contains($0) }) {
            return .cloud
        }

        if message.count > 1200 {
            return .cloud
        }

        return .local
    }
}
