//
//  OrbitMacControlCenter+Audio.swift
//  ORBITMac
//
//  Volume and mute intent detection + execution.
//

import Foundation

extension OrbitMacControlCenter {

    // MARK: - Spoken-number normalisation
    // Voice ASR gives "sixty percent", not "60%". Resolve before pattern matching.

    static func resolveSpokenNumbers(in text: String) -> String {
        var s = text
        // Compound numbers first: "twenty five" → "25"
        let tens: [(String, Int)] = [
            ("twenty", 20), ("thirty", 30), ("forty", 40), ("fifty", 50),
            ("sixty", 60), ("seventy", 70), ("eighty", 80), ("ninety", 90),
        ]
        let units: [(String, Int)] = [
            ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5),
            ("six", 6), ("seven", 7), ("eight", 8), ("nine", 9),
        ]
        for (tw, tv) in tens {
            for (uw, uv) in units {
                s = s.replacingOccurrences(of: "\(tw)[ -]\(uw)\\b", with: "\(tv + uv)", options: .regularExpression)
            }
        }
        // Singles
        let singles: [(String, String)] = [
            ("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"),
            ("five", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"), ("nine", "9"),
            ("ten", "10"), ("eleven", "11"), ("twelve", "12"), ("thirteen", "13"),
            ("fourteen", "14"), ("fifteen", "15"), ("sixteen", "16"), ("seventeen", "17"),
            ("eighteen", "18"), ("nineteen", "19"),
            ("twenty", "20"), ("thirty", "30"), ("forty", "40"), ("fifty", "50"),
            ("sixty", "60"), ("seventy", "70"), ("eighty", "80"), ("ninety", "90"),
            ("hundred", "100"), ("full", "100"), ("max", "100"), ("maximum", "100"),
            ("minimum", "0"), ("half", "50"),
        ]
        for (word, digit) in singles {
            s = s.replacingOccurrences(of: "\\b\(word)\\b", with: digit, options: .regularExpression)
        }
        return s
    }

    // MARK: - Intent detection

    static func isMuteIntent(_ normalized: String) -> Bool {
        if normalized == "mute" || normalized == "silence" { return true }
        let snippets = [
            "mute volume", "mute the volume", "turn volume off", "mute sound", "mute the sound",
            "turn sound off", "silence volume", "volume mute", "silence the volume",
            "go silent", "silence it", "be quiet", "shh", "quiet please",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isUnmuteIntent(_ normalized: String) -> Bool {
        if normalized == "unmute" { return true }
        let snippets = [
            "unmute volume", "unmute the volume", "turn volume on", "unmute sound", "unmute the sound",
            "turn sound on", "volume unmute", "unsilence", "unmute it",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isVolumeUpIntent(_ normalized: String) -> Bool {
        let snippets = [
            "volume up", "increase volume", "raise volume",
            "turn volume up", "turn up the volume", "turn the volume up",
            "make it louder", "make the volume louder",
            "sound up", "raise the volume", "increase the volume",
            "crank it up", "crank the volume", "crank up the volume",
            "pump it up", "up the volume", "louder please",
            "a bit louder", "a little louder", "little louder", "bit louder",
            "can you raise the volume", "can you increase the volume",
            "boost the volume", "boost volume",
        ]
        if snippets.contains(where: { normalized.contains($0) }) { return true }
        if normalized.contains("volume") && normalized.contains("louder") { return true }
        if normalized.contains("volume") && normalized.contains("higher") { return true }
        return false
    }

    static func isVolumeDownIntent(_ normalized: String) -> Bool {
        let snippets = [
            "volume down", "decrease volume", "lower volume",
            "turn volume down", "turn down the volume", "turn the volume down",
            "make it quieter", "make the volume quieter",
            "sound down", "lower the volume", "decrease the volume",
            "reduce the volume", "reduce volume",
            "quiet it down", "tone it down", "bring it down", "bring the volume down",
            "quieter please", "a bit quieter", "a little quieter", "little quieter", "bit quieter",
            "can you lower the volume", "can you reduce the volume",
            "softer please", "a bit softer",
        ]
        if snippets.contains(where: { normalized.contains($0) }) { return true }
        if normalized.contains("volume") && normalized.contains("quieter") { return true }
        if normalized.contains("volume") && normalized.contains("lower") { return true }
        if normalized.contains("volume") && normalized.contains("softer") { return true }
        return false
    }

    /// Returns an absolute volume level (0–100) if the command specifies one.
    /// Resolves spoken numbers first so voice input like "sixty percent" works.
    static func extractVolumePercent(from normalized: String) -> Int? {
        let s = resolveSpokenNumbers(in: normalized)
        let patterns = [
            // "set/put/turn/change the volume to/at 60" / "set it to 60%"
            #"(?:set|put|change|turn|bring)\s+(?:the\s+)?(?:volume|sound|audio|it)\s+(?:up\s+)?(?:to|at)\s+(\d{1,3})\s*(?:percent|%)?"#,
            // "volume to 60" / "volume at 60%"
            #"(?:the\s+)?(?:volume|sound|audio)\s+(?:to|at)\s+(\d{1,3})\s*(?:percent|%)?"#,
            // "set volume 60" / "volume 60%"
            #"(?:^|\b)(?:set\s+)?(?:the\s+)?volume\s+(\d{1,3})\s*(?:percent|%)?\b"#,
            // "60% volume" / "60 percent volume"
            #"\b(\d{1,3})\s*(?:percent|%)\s+(?:volume|sound|loud)"#,
            // "turn the volume up/down to 60" (absolute target overrides relative intent)
            #"(?:volume|sound|audio)\s+(?:up|down)\s+(?:to|at)\s+(\d{1,3})\s*(?:percent|%)?"#,
            // Conversational: "at 60 percent" with volume context nearby
            #"(?:volume|sound).{0,30}(?:to|at)\s+(\d{1,3})\s*(?:percent|%)?"#,
        ]
        for p in patterns {
            if let cap = firstCapture(in: s, pattern: p), let value = Int(cap), value >= 0, value <= 100 {
                return value
            }
        }
        return nil
    }

    // MARK: - Execution helpers

    static func currentOutputVolume() -> Int {
        guard let script = NSAppleScript(source: "output volume of (get volume settings)") else { return 50 }
        var errorDict: NSDictionary?
        let result = script.executeAndReturnError(&errorDict)
        if errorDict != nil { return 50 }
        return max(0, min(100, Int(result.int32Value)))
    }
}
