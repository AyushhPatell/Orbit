//
//  OrbitMacControlCenter+Documents.swift
//  ORBITMac
//
//  PDF and document summarization — find a file, extract text, summarize via LLM.
//

import AppKit
import Foundation
import PDFKit

extension OrbitMacControlCenter {

    // MARK: - Intent detection

    struct DocumentQuery {
        let action: String        // "summarize", "read", "explain", "what's in"
        let fileName: String?     // specific name if provided ("resume.pdf")
        let location: String?     // "desktop", "documents", "downloads"
        let fileType: String?     // "pdf", "document", "file"
    }

    static func extractDocumentQuery(from normalized: String) -> DocumentQuery? {
        let actionPhrases: [(action: String, phrases: [String])] = [
            ("summarize", [
                "summarize the pdf", "summarize that pdf", "summarize this pdf", "summarize my pdf",
                "summarize the document", "summarize that document", "summarize this document",
                "summarize the file", "summarize that file", "summarize this file",
                "pdf summary", "document summary", "file summary",
                "sum up the pdf", "sum up that document", "give me a summary of the pdf",
                "give me a summary of that document", "give me a summary of the file",
                "summarize", "summarise",
            ]),
            ("read", [
                "read the pdf", "read that pdf", "read this pdf", "read my pdf",
                "read the document", "read that document", "read this document",
                "read the file", "read that file", "read this file",
                "open and read", "read it",
            ]),
            ("explain", [
                "what's in the pdf", "what's in that pdf", "what's in this pdf",
                "what's in the document", "what's in that document", "what's in that file",
                "what is in the pdf", "what is in that document", "what is in the file",
                "what does the pdf say", "what does that document say",
                "explain the pdf", "explain that document", "explain this document",
                "tell me about the pdf", "tell me about that document",
                "what's this pdf about", "what's that document about",
            ]),
        ]

        var matchedAction: String?
        for (action, phrases) in actionPhrases {
            if phrases.contains(where: { normalized.contains($0) }) {
                matchedAction = action
                break
            }
        }

        // Also match "summarize [filename]" directly
        if matchedAction == nil {
            let verbs = ["summarize ", "summarise ", "sum up ", "read ", "explain ", "what's in "]
            for verb in verbs {
                if normalized.hasPrefix(verb) {
                    let rest = String(normalized.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
                    if rest.contains(".pdf") || rest.contains(".doc") || rest.contains(".txt")
                        || rest.contains(".rtf") || rest.contains("document") || rest.contains("pdf") {
                        matchedAction = verb.trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
        }

        guard let action = matchedAction else { return nil }

        // Extract location
        var location: String?
        if normalized.contains("on desktop") || normalized.contains("on my desktop")
            || normalized.contains("in desktop") || normalized.contains("from desktop")
            || normalized.contains("from my desktop") {
            location = "desktop"
        } else if normalized.contains("in documents") || normalized.contains("in my documents")
            || normalized.contains("from documents") || normalized.contains("from my documents") {
            location = "documents"
        } else if normalized.contains("in downloads") || normalized.contains("in my downloads")
            || normalized.contains("from downloads") || normalized.contains("from my downloads") {
            location = "downloads"
        }

        // Extract file type hint
        var fileType: String?
        if normalized.contains("pdf") { fileType = "pdf" }
        else if normalized.contains("document") || normalized.contains("doc") { fileType = "document" }
        else if normalized.contains("file") { fileType = "file" }

        // Try to extract a specific filename
        var fileName = extractFileName(from: normalized)
        // Reject generic words that aren't real filenames
        let genericNames: Set<String> = [
            "files", "file", "documents", "document", "pdfs", "pdf",
            "the files", "the documents", "the pdfs", "all files",
            "files documents", "files desktop", "files downloads",
            "documents documents", "document documents",
        ]
        if let name = fileName, genericNames.contains(name.lowercased()) {
            fileName = nil
        }

        return DocumentQuery(action: action, fileName: fileName, location: location, fileType: fileType)
    }

    // MARK: - File finding

    enum DocumentFindResult {
        case exactMatch(URL)
        case fuzzyMatch(URL, query: String)
        case multipleFound(paths: [String], action: String)
        case notFound(hint: String)
    }

    static func findDocument(query: DocumentQuery) -> DocumentFindResult {
        let home = realUserHomeForFiles()
        let fm = FileManager.default
        let docExtensions = ["pdf", "txt", "rtf", "docx", "doc", "md", "pages"]

        // If a specific filename was given, search for it
        if let name = query.fileName, !name.isEmpty {
            let searchLocations = locationPaths(for: query.location, home: home)
            for loc in searchLocations {
                // Exact filename match (with or without extension)
                let exact = loc.appendingPathComponent(name)
                if fm.fileExists(atPath: exact.path) { return .exactMatch(exact) }
                for ext in docExtensions {
                    let withExt = loc.appendingPathComponent(name + "." + ext)
                    if fm.fileExists(atPath: withExt.path) { return .exactMatch(withExt) }
                }
                // Fuzzy: files containing the name or its words
                if let contents = try? fm.contentsOfDirectory(atPath: loc.path) {
                    let lower = name.lowercased()
                    let nameWords = lower.split(separator: " ").map(String.init).filter { $0.count >= 3 }
                    let matches = contents.filter { file in
                        let fileLower = file.lowercased()
                        guard docExtensions.contains(where: { fileLower.hasSuffix("." + $0) }) else { return false }
                        if fileLower.contains(lower) { return true }
                        if nameWords.count >= 1 {
                            return nameWords.allSatisfy { word in
                                fileLower.contains(word) || fileLower.contains(dropDoubleLetters(word))
                            }
                        }
                        return false
                    }.map { loc.appendingPathComponent($0).path }
                    // Check if any match is exact (filename minus extension equals the query)
                    for m in matches {
                        let fn = ((m as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                        if fn == lower || fn.replacingOccurrences(of: "_", with: " ") == lower {
                            return .exactMatch(URL(fileURLWithPath: m))
                        }
                    }
                    if matches.count == 1 { return .fuzzyMatch(URL(fileURLWithPath: matches[0]), query: name) }
                    if matches.count > 1 { return .multipleFound(paths: matches, action: query.action) }
                }
            }
            return .notFound(hint: name)
        }

        // No specific name — list matching files so the user can pick
        let searchLocations = locationPaths(for: query.location, home: home)
        let filterExtensions: [String] = query.fileType == "pdf" ? ["pdf"] : docExtensions
        var allMatches: [(path: String, date: Date)] = []
        for loc in searchLocations {
            guard let contents = try? fm.contentsOfDirectory(atPath: loc.path) else { continue }
            for file in contents {
                guard filterExtensions.contains(where: { file.lowercased().hasSuffix("." + $0) }) else { continue }
                let url = loc.appendingPathComponent(file)
                let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
                allMatches.append((url.path, date))
            }
        }
        guard !allMatches.isEmpty else {
            return .notFound(hint: query.fileType ?? "document")
        }
        // Sort by most recent, take top 8
        let sorted = allMatches.sorted { $0.date > $1.date }
        let top = Array(sorted.prefix(8))
        if top.count == 1 { return .exactMatch(URL(fileURLWithPath: top[0].path)) }
        return .multipleFound(paths: top.map(\.path), action: query.action)
    }

    static func parseDocPickIndex(_ n: String) -> Int? {
        // "open 1", "open 2" — matches constellation prompt format
        if let m = n.range(of: #"^open\s+(\d{1,2})$"#, options: .regularExpression) {
            let digits = n[m].filter { $0.isNumber }
            if let i = Int(digits) { return i }
        }
        // Bare number
        if let m = n.range(of: #"^\d{1,2}$"#, options: .regularExpression), let i = Int(n[m]) { return i }
        // Word forms
        let words: [String: Int] = ["first": 1, "one": 1, "second": 2, "two": 2,
                                     "third": 3, "three": 3, "fourth": 4, "four": 4,
                                     "fifth": 5, "five": 5, "sixth": 6, "six": 6,
                                     "seventh": 7, "seven": 7, "eighth": 8, "eight": 8]
        for (word, num) in words where n == word || n == "the \(word)" || n == "number \(num)"
            || n == "open \(word)" { return num }
        return nil
    }

    // MARK: - Text extraction

    static func extractDocumentText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            var text = ""
            for i in 0..<min(doc.pageCount, 50) {
                if let page = doc.page(at: i), let pageText = page.string {
                    text += pageText + "\n"
                }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(48_000))

        case "txt", "md", "csv":
            return try? String(contentsOf: url, encoding: .utf8).prefix(48_000).description

        case "rtf":
            guard let data = try? Data(contentsOf: url),
                  let attr = try? NSAttributedString(data: data,
                      options: [.documentType: NSAttributedString.DocumentType.rtf],
                      documentAttributes: nil)
            else { return nil }
            return String(attr.string.prefix(48_000))

        case "docx", "doc":
            guard let data = try? Data(contentsOf: url),
                  let attr = try? NSAttributedString(data: data,
                      options: [.documentType: NSAttributedString.DocumentType.docFormat],
                      documentAttributes: nil)
            else { return nil }
            return String(attr.string.prefix(48_000))

        default:
            return try? String(contentsOf: url, encoding: .utf8).prefix(48_000).description
        }
    }

    // MARK: - Compose LLM message

    static func composeDocumentSummaryMessage(action: String, fileName: String, text: String) -> String {
        let instruction: String
        switch action {
        case "read":
            instruction = "Read and present the key content of this document clearly. Keep it concise."
        case "explain":
            instruction = "Explain what this document is about in plain, simple language. Highlight the key points."
        default:
            instruction = "Summarize this document concisely in 3-6 bullet points. Focus on the most important information."
        }
        return """
        The user asked to \(action) a document: "\(fileName)".

        \(instruction)

        --- Document content begin ---
        \(text)
        --- Document content end ---

        Reply with only the summary/explanation. Do not add meta framing.
        """
    }

    // MARK: - Helpers

    private static func dropDoubleLetters(_ word: String) -> String {
        var result = ""
        var prev: Character = "\0"
        for ch in word {
            if ch != prev { result.append(ch) }
            prev = ch
        }
        return result
    }

    private static func locationPaths(for location: String?, home: URL) -> [URL] {
        switch location {
        case "desktop":   return [home.appendingPathComponent("Desktop")]
        case "documents": return [home.appendingPathComponent("Documents")]
        case "downloads": return [home.appendingPathComponent("Downloads")]
        default:
            return [
                home.appendingPathComponent("Desktop"),
                home.appendingPathComponent("Documents"),
                home.appendingPathComponent("Downloads"),
            ]
        }
    }

    private static func extractFileName(from normalized: String) -> String? {
        // Quoted filename: "resume.pdf"
        if let start = normalized.firstIndex(of: "\""),
           let end = normalized[normalized.index(after: start)...].firstIndex(of: "\"") {
            let name = String(normalized[normalized.index(after: start)..<end])
            if !name.isEmpty { return name }
        }
        // Explicit "called X" or "named X"
        let namePatterns = [#"\bcalled\s+(.+?)(?:\s+(?:on|in|from)\b|$)"#,
                            #"\bnamed\s+(.+?)(?:\s+(?:on|in|from)\b|$)"#]
        for pattern in namePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
               match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: normalized) {
                let name = String(normalized[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        // File with extension: "resume.pdf"
        if let extRange = normalized.range(of: #"\b[\w\s-]+\.(?:pdf|docx?|txt|rtf|md)\b"#, options: .regularExpression) {
            return String(normalized[extRange]).trimmingCharacters(in: .whitespaces)
        }
        // Subtraction approach: strip action prefix and location suffix → what's left is the name.
        // "summarize the enrollment letter from documents" → "enrollment letter"
        var text = normalized
        let actionPrefixes = [
            "summarize the ", "summarize that ", "summarize this ", "summarize my ",
            "summarise the ", "summarise that ", "summarise this ", "summarise my ",
            "read the ", "read that ", "read this ", "read my ",
            "explain the ", "explain that ", "explain this ",
            "what's in the ", "what's in that ", "what's in my ",
            "what is in the ", "what is in that ", "what is in my ",
            "sum up the ", "sum up that ", "sum up my ",
            "give me a summary of the ", "give me a summary of my ",
            "tell me about the ", "tell me about my ",
            "summarize ", "summarise ", "read ", "explain ", "sum up ",
        ].sorted { $0.count > $1.count }
        for prefix in actionPrefixes {
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
        }
        let locationSuffixes = [
            " from my documents folder", " from my documents", " from documents",
            " from my desktop folder", " from my desktop", " from desktop",
            " from my downloads folder", " from my downloads", " from downloads",
            " for my documents", " for documents", " for my desktop", " for desktop",
            " for my downloads", " for downloads",
            " on my desktop", " on desktop", " on my documents", " on documents",
            " in my documents", " in documents", " in my downloads", " in downloads",
            " in my desktop", " in desktop",
            " my documents", " my desktop", " my downloads",
            " documents", " desktop", " downloads",
        ].sorted { $0.count > $1.count }
        for suffix in locationSuffixes {
            if text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)); break }
        }
        // Strip trailing file type words
        let typeWords = [" pdf file", " pdf", " document", " doc file", " doc", " file", " text file"]
        for tw in typeWords {
            if text.hasSuffix(tw) { text = String(text.dropLast(tw.count)); break }
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let skip: Set<String> = [
            "that", "the", "this", "my", "a", "an", "it",
            "pdf", "pdfs", "document", "documents", "file", "files",
            "all", "everything", "the files", "the documents", "the pdfs",
            "all files", "all documents", "all pdfs", "some",
        ]
        guard cleaned.count >= 2, !skip.contains(cleaned) else { return nil }
        return cleaned
    }
}
