//
//  OrbitVoicePartingLine.swift
//  ORBITMac
//
//  Short spoken acknowledgments before ending a voice session (Siri-style closure).
//

import AppKit
import Foundation

enum OrbitVoicePartingLine {
    /// First token of `NSFullUserName()` (macOS account), not from chat memory or the LLM.
    private static var companionFirstName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    private static func nameSuffix() -> String {
        let n = companionFirstName
        guard !n.isEmpty else { return "." }
        return ", \(n)."
    }

    /// Picks a natural one-liner from what the user said (stop / later / bye / done…).
    static func spokenLine(for userText: String) -> String {
        let t = userText.lowercased()

        if t.range(of: #"\b(bye|good[- ]?bye|goodbye)\b"#, options: .regularExpression) != nil {
            return "Okay — talk soon\(nameSuffix()) Take care."
        }
        if t.contains("later") || t.contains("catch you") || t.contains("see you") {
            return "Sure — talk to you later\(nameSuffix())"
        }
        if t.contains("good night") {
            return "Good night\(nameSuffix()) Rest well."
        }
        if t.contains("take care") || t.contains("have a good") {
            return "You too\(nameSuffix()) I’ll be here when you need me."
        }
        if t.contains("heading out") || t.contains("need to go") || t.contains("have to go")
            || t.contains("gotta go") || t.contains("got to go") || t.contains("leaving")
        {
            return "Of course — catch you later\(nameSuffix())"
        }
        if t.contains("i’m good") || t.contains("i am good") || t.contains("we’re good") || t.contains("we are good") {
            return "Great — I’m right here whenever you need me\(nameSuffix())"
        }
        if t.contains("let you go") || t.contains("let you rest") || t.contains("you’re dismissed") || t.contains("you are dismissed") {
            return "Understood — standing by\(nameSuffix())"
        }
        if t.contains("done") || t.contains("that’s it") || t.contains("that is it") || t.contains("all done")
            || t.contains("we’re done") || t.contains("we are done") || t.contains("i’m done") || t.contains("i am done")
        {
            return "Got it. I’m right here when you want to pick it up again\(nameSuffix())"
        }
        if t.contains("pause") {
            return "Okay — pausing here. Tap the mic when you’re ready\(nameSuffix())"
        }
        if t.contains("stop") || t.contains("halt") || t.contains("quit") || t.contains("cancel") {
            return "Alright, stopping now. I’m here whenever you need me\(nameSuffix())"
        }
        if t.contains("enough") || t.contains("no more") {
            return "Sure — I’ll give you some space. Call me back whenever\(nameSuffix())"
        }
        return "Okay — I’m here when you need me\(nameSuffix())"
    }
}
