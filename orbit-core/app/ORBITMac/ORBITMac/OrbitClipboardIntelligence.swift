//
//  OrbitClipboardIntelligence.swift
//  ORBITMac
//
//  #3 Smart clipboard: reads the system pasteboard when the user asks in natural language,
//  then expands the message sent to `/chat` so the local model can summarize, rewrite, etc.
//

import AppKit
import Foundation

enum OrbitClipboardIntelligence {
    /// How to send the user’s phrase to `orbit-core` `/chat`.
    enum ChatMessagePreparation: Sendable {
        /// Normal conversation; use classifier routing.
        case useAsIs(String)
        /// Clipboard command with text injected; always route `.local` (privacy).
        case clipboardExpanded(String)
        /// User asked for a clipboard op but pasteboard has no usable plain text.
        case clipboardEmpty
        /// User asked for a clipboard op but clipboard access is off in privacy settings.
        case clipboardDisabled
    }

    private static let maxClipboardChars = 48_000

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s.&+\\-']", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mentionsClipboardContext(_ n: String) -> Bool {
        n.contains("clipboard")
            || n.contains("pasteboard")
            || n.contains("what i copied")
            || n.contains("copied text")
            || n.contains("copied data")
            || n.contains("text i have copied")
            || n.contains("data i have copied")
            || n.contains("text in my clipboard")
            || n.contains("text which is in my clipboard")
            || n.contains("copied")
            || n.contains("from my clipboard")
    }

    /// Commands like "summarize this email/article/paragraph" imply "the thing I just copied".
    /// Also matches bare "this" at the end of an operation phrase (e.g., "summarize this").
    private static func mentionsImplicitCopiedObject(_ n: String) -> Bool {
        let hints = [
            "this text", "this data", "this content", "this note", "this notes",
            "this email", "this mail", "this message", "this paragraph", "this article",
            "this doc", "this document", "this writeup", "this write up",
            "this code", "this snippet", "this page", "this thing",
            "this sentence", "this section", "this part", "this stuff",
            "that text", "that email", "that message", "that code",
            "the text", "the email", "the message", "the code",
        ]
        if hints.contains(where: { n.contains($0) }) { return true }
        // Bare "this"/"it"/"that" at end — "summarize this", "rewrite it", "explain that"
        if n.hasSuffix(" this") || n.hasSuffix(" it") || n.hasSuffix(" that") { return true }
        // Operation verb + "this"/"it" mid-sentence — "explain this to me", "translate this to french"
        if n.range(of: #"\b(summarize|summarise|rewrite|rephrase|translate|explain|simplify|polish|shorten|improve|condense|fix|correct|proofread|decode|outline) (this|it|that)\b"#,
                   options: .regularExpression) != nil { return true }
        return false
    }

    private enum ClipboardOp {
        case summarize
        case rewrite
        case professionalTone
        case casualTone
        case bullets
        case actionItems
        case draftReply
        case translate(language: String)
        case explain
    }

    private static func detectOp(_ n: String) -> ClipboardOp? {
        // Translate: check first because "translate this to French" has a specific structure
        if let lang = extractTranslateLanguage(n) {
            if mentionsClipboardContext(n) || mentionsImplicitCopiedObject(n)
                || isBareClipboardCommand(n) {
                return .translate(language: lang)
            }
            return nil
        }

        let snippetsDraft: [(ClipboardOp, [String])] = [
            (.draftReply, [
                "draft a reply", "draft reply", "draft a response", "draft response",
                "quick reply", "email reply", "reply draft", "response draft",
                "write a reply", "write a response", "write reply",
                "compose a reply", "compose a response",
                "reply to this", "reply for this", "reply to it", "reply to that",
                "respond to this", "respond to it", "respond to that",
                "answer this", "answer it", "answer that",
                "help me reply", "help me respond", "help me answer",
            ]),
            (.explain, [
                "explain this", "explain it", "explain that", "explain to me",
                "what does this mean", "what does it mean", "what does that mean",
                "what is this", "what is it", "what is that",
                "what does this say", "what does it say",
                "break this down", "break it down", "break that down",
                "explain this code", "explain the code", "what does this code do",
                "help me understand", "can you explain", "could you explain",
                "decode this", "decode it", "make sense of this",
                "dumb this down", "simplify this", "explain simply",
                "explain in simple words", "explain in simple terms",
                "what's going on here", "walk me through",
            ]),
            (.actionItems, [
                "action items", "action item", "extract tasks", "tasks from",
                "todos from", "todo from", "to do from", "to dos from",
                "next steps", "follow ups", "follow ups from",
                "checklist from", "checklist", "extract action items",
                "list action items", "make action items",
                "what do i need to do", "what are the tasks",
                "pull out tasks", "pull out the tasks", "pull out action items",
                "to do list", "to do list from", "todo list",
                "what needs to be done", "what should i do",
            ]),
            (.bullets, [
                "bullet points", "bullet point", "bullets from", "bulletize", "bullet list",
                "turn into bullets", "as bullets", "make bullet points", "convert to bullets",
                "list the points", "make a list", "list this out", "list it out",
                "key takeaways", "outline this", "outline it",
                "put in bullet form", "in bullet form", "give me bullets",
            ]),
            (.professionalTone, [
                "professional tone", "more professional", "formal tone", "business tone",
                "make it professional", "make this professional", "make it more professional",
                "make it formal", "make this formal", "make it more formal",
                "more formal", "sound professional", "sound more professional",
                "formalize", "formalize this", "formalize it",
                "business version", "formal version", "professional version",
                "make it sound professional", "make this sound professional",
                "corporate tone", "workplace tone",
            ]),
            (.casualTone, [
                "casual tone", "more casual", "friendly tone", "informal tone",
                "make it casual", "make this casual", "make it more casual",
                "make it informal", "make this informal", "make it more informal",
                "make it friendly", "make this friendly", "make it more friendly",
                "more friendly", "less formal", "make it less formal",
                "relax the tone", "relaxed tone", "conversational tone",
                "make it conversational", "make it natural", "make it sound natural",
                "casual version", "friendly version", "informal version",
                "soften the tone", "lighten the tone", "warm it up",
            ]),
            (.summarize, [
                "summarize", "summarise", "summary of", "summary", "sum up", "sum this up",
                "tl dr", "tldr", "tl;dr", "too long", "too long didn't read",
                "key points", "main points", "main ideas", "key ideas",
                "in short", "brief summary", "quick summary", "short summary",
                "give me a summary", "give me the gist", "what's the gist",
                "condense", "condense this", "condense it",
                "give me the key points", "what are the main points",
                "boil this down", "boil it down", "bottom line",
                "cliff notes", "cliffnotes", "overview of",
                "give me a brief", "brief me", "quick overview",
                "what's this about", "what is this about",
            ]),
            (.rewrite, [
                "rewrite", "rephrase", "re word", "reword", "re-word",
                "improve", "improve this", "improve it", "make this better", "make it better",
                "polish", "polish this", "polish it",
                "clean up", "clean this up", "clean it up", "tidy up", "tidy this up",
                "fix grammar", "fix the grammar", "fix spelling", "fix the spelling",
                "fix this", "fix it", "correct this", "correct it",
                "tighten", "tighten this", "tighten it up",
                "shorter", "make it shorter", "make this shorter",
                "more concise", "make it concise", "make this concise",
                "edit this", "edit it", "refine this", "refine it",
                "make this clearer", "make it clearer", "make it clear",
                "smooth this out", "smooth it out",
                "proofread", "proofread this", "proofread it",
                "rework this", "rework it",
            ]),
        ]

        var matched: ClipboardOp?
        for (op, phrases) in snippetsDraft {
            if phrases.contains(where: { n.contains($0) }) {
                matched = op
                break
            }
        }
        guard let matched else { return nil }

        if mentionsClipboardContext(n) { return matched }
        if mentionsImplicitCopiedObject(n) { return matched }
        // Bare clipboard commands: "summarize", "rewrite", "explain" with no other object
        // mentioned — the user is almost certainly referring to their clipboard.
        if isBareClipboardCommand(n) { return matched }
        return nil
    }

    private static func isBareClipboardCommand(_ n: String) -> Bool {
        let bareOps = [
            "summarize", "summarise", "summary", "sum up", "sum this",
            "rewrite", "rephrase", "reword", "re word", "re-word",
            "explain", "decode", "break this down", "break it down",
            "translate", "convert to",
            "draft a reply", "draft reply", "draft a response", "draft response",
            "reply to", "respond to", "answer this", "answer it",
            "help me reply", "help me respond",
            "bullet points", "bullets", "outline",
            "action items", "next steps", "checklist", "todo list", "to do list",
            "fix grammar", "fix spelling", "fix this", "fix it",
            "proofread", "correct this", "correct it",
            "improve", "polish", "clean up", "tidy up",
            "make it professional", "make this professional", "make it formal",
            "make it casual", "make this casual", "make it informal",
            "make it friendly", "make this friendly", "make it natural",
            "make it better", "make this better", "make it clearer",
            "make it shorter", "make this shorter", "make it concise",
            "professional tone", "casual tone", "formal tone", "friendly tone",
            "formalize", "relax the tone", "soften the tone",
            "condense", "boil this down", "shorten",
            "key points", "main points", "quick summary",
            "what does this mean", "what is this", "what does it mean",
            "simplify", "dumb this down",
        ]
        return bareOps.contains(where: { n.hasPrefix($0) })
    }

    private static func extractTranslateLanguage(_ n: String) -> String? {
        let triggers = [
            #"\btranslate\b.*\bto\s+(\w+)"#,
            #"\btranslate\b.*\bin(?:to)?\s+(\w+)"#,
            #"\bin\s+(\w+)\b.*\btranslate"#,
            #"\btranslation\b.*\bto\s+(\w+)"#,
            #"\bconvert\b.*\bto\s+(\w+)"#,
            #"\bsay this in\s+(\w+)"#,
            #"\bhow do you say.*in\s+(\w+)"#,
            #"\bin\s+(\w+)\s+please"#,
        ]
        let knownLanguages: Set<String> = [
            "english", "french", "spanish", "german", "italian", "portuguese",
            "dutch", "russian", "chinese", "japanese", "korean", "arabic",
            "hindi", "urdu", "bengali", "punjabi", "gujarati", "tamil", "telugu",
            "marathi", "kannada", "malayalam", "thai", "vietnamese", "indonesian",
            "malay", "turkish", "polish", "swedish", "norwegian", "danish",
            "finnish", "greek", "hebrew", "czech", "romanian", "hungarian",
            "ukrainian", "persian", "swahili", "tagalog", "nepali",
        ]
        for pattern in triggers {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
                  match.numberOfRanges >= 2,
                  let langRange = Range(match.range(at: 1), in: n)
            else { continue }
            let lang = String(n[langRange]).lowercased()
            if knownLanguages.contains(lang) {
                return lang.prefix(1).uppercased() + lang.dropFirst()
            }
        }
        // Bare "translate this" with no language → default English
        if n.contains("translate") { return "English" }
        return nil
    }

    private static func instructionLine(for op: ClipboardOp) -> String {
        switch op {
        case .summarize:
            return "Summarize the clipboard text clearly and concisely in 1-4 bullets. No markdown heading."
        case .rewrite:
            return "Rewrite the clipboard text to be clearer and smoother. Preserve meaning and facts."
        case .professionalTone:
            return "Rewrite the clipboard text in a professional, workplace-appropriate tone. Preserve meaning."
        case .casualTone:
            return "Rewrite the clipboard text in a warm, conversational tone. Preserve meaning."
        case .bullets:
            return "Convert the clipboard text into a tight bullet list. Merge related points."
        case .actionItems:
            return "Extract concrete action items / next steps from the clipboard text as a checklist. If none, say so briefly."
        case .draftReply:
            return "Draft a helpful reply to the clipboard text (for example an email or message). Match the implied context. Do not invent private facts."
        case .translate(let language):
            return "Translate the clipboard text into \(language). Output only the translation — no original text, no labels, no explanations."
        case .explain:
            return "Explain the clipboard text in plain, simple language. If it is code, explain what it does step by step. If it is jargon-heavy, clarify the key terms. Keep it concise."
        }
    }

    private static func readClipboardPlainText() -> String? {
        let pb = NSPasteboard.general
        let raw: String? = {
            if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
            if let data = pb.data(forType: .rtf),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtf],
                   documentAttributes: nil
               )
            {
                let s = attributed.string
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            }
            if let data = pb.data(forType: .html),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.html],
                   documentAttributes: nil
               )
            {
                let s = attributed.string
                if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            }
            if let data = pb.data(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")),
               let s = String(data: data, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return s
            }
            if let data = pb.data(forType: NSPasteboard.PasteboardType("public.utf16-external-plain-text")),
               let s = String(data: data, encoding: .utf16),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return s
            }
            return nil
        }()

        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxClipboardChars { return trimmed }
        let head = String(trimmed.prefix(maxClipboardChars))
        return head + "\n\n[Note: clipboard was truncated for length.]"
    }

    /// Same source as voice parting lines: macOS full user name → first token (not “learned” from chat).
    private static func macAccountFirstName() -> String? {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return nil }
        return full.split(separator: " ").first.map(String.init)
    }

    private static func composeMessage(userOriginal: String, op: ClipboardOp, clipboard: String) -> String {
        let instruction = instructionLine(for: op)
        let nameHint: String = {
            guard let name = macAccountFirstName(), !name.isEmpty else { return "" }
            return """

            ### Local device context (trust for this request)
            The macOS account’s preferred first name is **\(name)**. If the user asks you to add their name or a sign-off to an email or message draft, use this first name naturally. Do not claim you lack the user’s name when this line is present.
            """
        }()
        return """
        The user invoked a clipboard helper from ORBITMac (macOS). Their exact request was: "\(userOriginal.replacingOccurrences(of: "\"", with: "'"))"

        \(instruction)
        \(nameHint)

        --- Clipboard begin ---
        \(clipboard)
        --- Clipboard end ---

        Reply with only the transformed content.
        Do not add meta framing such as "Clipboard Summary", "The clipboard text is", or similar.
        Do not explain what you are doing.
        Do not paste back the entire clipboard unless they explicitly asked for a full quote.
        """
    }

    /// If this returns `.clipboardEmpty`, show a short notice and do not call `/chat`.
    static func prepareUserMessageForChat(_ userText: String) -> ChatMessagePreparation {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .useAsIs(trimmed) }
        let n = normalize(trimmed)
        guard let op = detectOp(n) else {
            return .useAsIs(trimmed)
        }
        guard OrbitMacControlCenter.privacyToggleEnabled("orbitMac.allowClipboard") else {
            return .clipboardDisabled
        }
        guard let clip = readClipboardPlainText() else {
            return .clipboardEmpty
        }
        return .clipboardExpanded(composeMessage(userOriginal: trimmed, op: op, clipboard: clip))
    }
}
