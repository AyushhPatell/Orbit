//
//  OrbitUIAssist.swift
//  ORBITMac
//
//  Types Unicode into the current keyboard-focused UI element. Requires Accessibility permission.
//

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum OrbitUIAssist {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts System Settings → Privacy & Security → Accessibility if not trusted (when `prompt` is true).
    static func ensureTrusted(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Inserts text as if typed on the hardware keyboard (focused control must accept keyboard input).
    static func typeIntoFocusedField(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OrbitUIAssistError.empty
        }
        guard ensureTrusted(prompt: false) else {
            throw OrbitUIAssistError.notTrusted
        }

        let src = CGEventSource(stateID: .hidSystemState)
        var utf16 = Array(trimmed.utf16)
        try utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress, buf.count > 0 else { throw OrbitUIAssistError.empty }
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else {
                throw OrbitUIAssistError.cgEvent
            }
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func extractTypeIntoFocusedPayload(from normalized: String) -> String? {
        let prefixes = [
            "type in focused field ",
            "type into focused field ",
            "type in the focused field ",
            "ui type ",
            "orbit type ",
        ]
        for p in prefixes where normalized.hasPrefix(p) {
            let rest = String(normalized.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return rest }
        }
        return nil
    }
}

enum OrbitUIAssistError: LocalizedError {
    case empty
    case notTrusted
    case cgEvent

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Nothing to type."
        case .notTrusted:
            return "ORBIT needs Accessibility permission: System Settings → Privacy & Security → Accessibility → enable ORBITMac. Then try again."
        case .cgEvent:
            return "Could not post keyboard events."
        }
    }
}
