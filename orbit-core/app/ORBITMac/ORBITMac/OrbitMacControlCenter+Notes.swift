//
//  OrbitMacControlCenter+Notes.swift
//  ORBITMac
//
//  Apple Notes creation and editing via AppleScript.
//

import Foundation

// Tracks the last note ORBIT created so it can be amended on follow-up.
enum OrbitNotesState {
    static var lastCreatedNoteTitle: String?
    static var lastCreatedAt: Date?

    static var hasRecentNote: Bool {
        guard lastCreatedNoteTitle != nil, let at = lastCreatedAt else { return false }
        return Date().timeIntervalSince(at) < 120
    }
}

extension OrbitMacControlCenter {

    // MARK: - Intent detection

    static func isNotesCreateIntent(_ normalized: String) -> Bool {
        let triggers = [
            "take a note", "take note",
            "note to self", "jot this down", "jot down",
            "add to notes", "add to my notes", "add this to notes",
            "create a note", "create note",
            "make a note in notes", "save to notes", "save this to notes",
            "write a note", "write this down",
            // "please" variants
            "please note", "please take a note", "please make a note",
            "please jot", "please write a note", "please add to notes",
            "can you note", "can you take a note", "can you make a note",
            "could you note", "could you take a note",
        ]
        if triggers.contains(where: { normalized.hasPrefix($0) || normalized.contains($0 + ":") || normalized.contains($0 + " that") }) {
            return true
        }
        // Fallback: trigger anywhere in the text — catches "orbit take a note" or
        // "hey orbit take a note" where the wake phrase leaks into the STT transcript.
        if triggers.contains(where: { normalized.contains(" " + $0) }) {
            return true
        }
        // "note: X" at start of utterance
        return normalized.hasPrefix("note:")
            || normalized.range(of: #"^note\s*:"#, options: .regularExpression) != nil
    }

    static func isNotesAppendIntent(_ normalized: String) -> Bool {
        let cleaned = stripConversationalFluff(normalized)
        let phrases = [
            "add to that note", "add to the note", "add to it",
            "add to last note", "update the note", "update that note",
            "also add", "and add", "append to the note", "append to that note",
            "add more to the note", "put in that note", "add to my note",
        ]
        if phrases.contains(where: { cleaned.hasPrefix($0) || cleaned.contains($0) }) {
            return true
        }
        let addStarters = ["add ", "also add ", "and add ", "put "]
        guard addStarters.contains(where: { cleaned.hasPrefix($0) }) else { return false }
        // Flexible pattern: "add X to/in that/the/my note/list" — user puts content
        // between "add" and "that note" (e.g. "add buy eggs in that note").
        let noteRefs = ["that note", "the note", "my note", "last note",
                        "that list", "the list", "my list",
                        "this note", "this list"]
        if noteRefs.contains(where: { cleaned.contains($0) }) { return true }
        // Broad ending: text ends with "note", "notes", or "list" (possibly after
        // STT garbling the determiner: "dat note", "then note", etc.)
        let trailingWords = cleaned.split(separator: " ")
        if let last = trailingWords.last, ["note", "notes", "list"].contains(String(last)) {
            return true
        }
        // Recency context: if a note was created in the last 2 minutes, a bare "add X"
        // (without explicit "in that note") is treated as a note append. This prevents
        // the follow-up from leaking to the LLM which might create a spurious reminder.
        if OrbitNotesState.hasRecentNote {
            let nonNoteKeywords = ["reminder", "calendar", "event", "alarm", "timer"]
            if !nonNoteKeywords.contains(where: { cleaned.contains($0) }) {
                return true
            }
        }
        return false
    }

    static func extractNoteAppendContent(from text: String) -> String {
        let lower = stripConversationalFluff(text.lowercased())
        let original = text.count > lower.count
            ? String(text.suffix(lower.count)) : text
        // Exact prefix stripping (existing patterns)
        let prefixes = [
            "add to that note:", "add to that note",
            "add to the note:", "add to the note",
            "add to last note:", "add to last note",
            "add to my note:", "add to my note",
            "update the note with:", "update the note with", "update the note:",
            "update that note with:", "update that note with",
            "append to the note:", "append to the note",
            "append to that note:", "append to that note",
            "put in that note:", "put in that note",
            "add more to the note:", "add more to the note",
            "also add:", "also add",
            "and add:",  "and add",
            "add to it:", "add to it",
        ].sorted { $0.count > $1.count }
        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                return String(original.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Flexible extraction: "add buy eggs in that note please" → "buy eggs"
        // 1. Strip leading verb
        var working = original
        let leadVerbs = ["also add ", "and add ", "add ", "put "]
        for v in leadVerbs {
            if lower.hasPrefix(v) { working = String(original.dropFirst(v.count)); break }
        }
        // 2. Strip trailing filler words ("please", "also", "too", "as well")
        var wLower = working.lowercased()
        let fillers = [" as well", " please", " also", " too"]
        for f in fillers {
            if wLower.hasSuffix(f) {
                working = String(working.dropLast(f.count))
                wLower = working.lowercased()
                break
            }
        }
        // 3. Strip trailing note/list reference
        let suffixes = [
            " in that note", " to that note", " in the note", " to the note",
            " in that list", " to that list", " in the list", " to the list",
            " in my note", " to my note", " in last note", " to last note",
            " in this note", " to this note", " in this list", " to this list",
            " in it", " to it",
        ].sorted { $0.count > $1.count }
        for s in suffixes {
            if wLower.hasSuffix(s) { working = String(working.dropLast(s.count)); break }
        }
        // 4. If nothing was stripped by suffixes, try stripping a final bare "note"/"list"
        //    (catches "add eggs in dat note" where "dat" isn't a known determiner)
        let wLower2 = working.lowercased()
        if wLower2.hasSuffix(" note") || wLower2.hasSuffix(" notes") || wLower2.hasSuffix(" list") {
            if let lastSpace = working.lastIndex(of: " ") {
                let beforeNote = String(working[..<lastSpace])
                // Only strip if there's a preposition before ("in", "to", "on", etc.)
                let bl = beforeNote.lowercased()
                let preps = [" in", " to", " on", " into", " onto"]
                if preps.contains(where: { bl.hasSuffix($0) }) {
                    if let prepSpace = beforeNote.lastIndex(of: " ") {
                        working = String(beforeNote[..<prepSpace])
                    }
                }
            }
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripConversationalFluff(_ text: String) -> String {
        var t = text
        // Leading affirmations and polite prefixes
        let leadPrefixes = [
            "yes please ", "yeah sure ", "yes ", "yeah ", "sure ",
            "ok ", "okay ", "yep ", "yup ",
            "can you please ", "could you please ",
            "can you ", "could you ", "would you ", "will you ",
            "i want to ", "i'd like to ", "i would like to ",
            "please ",
        ]
        for p in leadPrefixes {
            if t.hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
        }
        // Trailing filler
        let trailFillers = [" please", " also", " too", " as well"]
        for f in trailFillers {
            if t.hasSuffix(f) { t = String(t.dropLast(f.count)); break }
        }
        return t
    }

    static func extractNoteContent(from text: String) -> (title: String?, body: String) {
        let lower = text.lowercased()
        let prefixes = [
            "please note to self:", "please note to self",
            "please take a note:", "please take a note",
            "please make a note about:", "please make a note about",
            "please make a note on:", "please make a note on",
            "please make a note:", "please make a note",
            "please write a note:", "please write a note",
            "please add to notes:", "please add to notes",
            "please jot this down:", "please jot this down",
            "please jot down:", "please jot down",
            "please note that:", "please note that",
            "please note:", "please note",
            "can you note that:", "can you note that",
            "can you take a note:", "can you take a note",
            "can you make a note:", "can you make a note",
            "could you note that:", "could you note that",
            "note to self:", "note to self",
            "take a note:", "take a note",
            "take note:", "take note",
            "jot this down:", "jot this down",
            "jot down:",
            "add to my notes:", "add to notes:",
            "create a note:", "create a note about",
            "make a note in notes:", "make a note:",
            "save to notes:", "save this to notes:",
            "write a note:", "write this down:",
            "note:",
        ].sorted { $0.count > $1.count }

        var body = text
        var prefixFound = false
        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                prefixFound = true
                break
            }
        }
        // Mid-text trigger: handles wake-phrase leakage like "hey orbit take a note buy milk".
        // Search for the first trigger inside the text when no prefix matched at the start.
        if !prefixFound {
            for prefix in prefixes {
                if let range = lower.range(of: " " + prefix) {
                    body = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    prefixFound = true
                    break
                }
            }
        }
        // Only fall back to the full text when no trigger prefix matched at all.
        // When a prefix was found but the remainder is empty ("take a note" with nothing after),
        // return empty so the caller can ask for the content.
        if !prefixFound && body.isEmpty { body = text }

        // Use first sentence or first 60 chars as title if body is long
        let title: String?
        if body.count > 60 {
            if let endIdx = body.firstIndex(where: { ".!?\n".contains($0) }) {
                title = String(body[..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = String(body.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            title = nil  // Apple Notes will use the body as title if short
        }

        return (title, body)
    }

    // MARK: - Execution

    static func createNote(title: String?, body: String) throws -> String {
        let safeBody = escape(body)
        // When title equals body (short notes), setting both name and body produces a
        // duplicate line in Notes. Only set name when it differs from body.
        let props: String
        if let title, title != body {
            let safeTitle = escape(title)
            props = "{name:\"\(safeTitle)\", body:\"\(safeBody)\"}"
        } else {
            props = "{body:\"\(safeBody)\"}"
        }

        let simple = """
        tell application "Notes"
            make new note with properties \(props)
        end tell
        """
        do {
            try runAppleScript(simple)
        } catch {
            let icloud = """
            tell application "Notes"
                tell account "iCloud"
                    make new note at folder "Notes" with properties \(props)
                end tell
            end tell
            """
            do {
                try runAppleScript(icloud)
            } catch {
                throw ControlError.actionFailed(
                    "I couldn\u{2019}t save the note \u{2014} make sure the Notes app is set up and iCloud Notes is enabled."
                )
            }
        }
        let displayTitle = title ?? String(body.prefix(40))
        OrbitNotesState.lastCreatedNoteTitle = displayTitle
        OrbitNotesState.lastCreatedAt = Date()
        return "Note saved \u{2014} \u{201C}\(displayTitle)\u{201D}."
    }

    static func appendToNote(title: String, content: String) throws -> String {
        let safeTitle = escape(title)
        let safeContent = escape(content)
        let script = """
        tell application "Notes"
            set theNote to first note whose name = "\(safeTitle)"
            set body of theNote to (body of theNote) & "<br>" & "\(safeContent)"
        end tell
        """
        do {
            try runAppleScript(script)
        } catch {
            throw ControlError.actionFailed(
                "I couldn\u{2019}t update the note. It may have been renamed or deleted."
            )
        }
        return "Added \u{201C}\(content)\u{201D} to the note \u{201C}\(title)\u{201D}."
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
