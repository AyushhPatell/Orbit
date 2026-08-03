//
//  OrbitMacControlCenter+Files.swift
//  ORBITMac
//
//  Finder, file search, project folder creation, and delete/trash helpers.
//

import AppKit
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Finder folder intent detection

    static func isOpenFinderIntent(_ normalized: String) -> Bool {
        let snippets = [
            "open finder", "launch finder", "start finder",
            "show finder", "open file manager",
            "bring up finder", "take me to finder",
            "go to finder", "finder please",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isOpenDownloadsIntent(_ normalized: String) -> Bool {
        let snippets = [
            "open downloads", "show downloads", "go to downloads",
            "open downloads folder", "open my downloads",
            "take me to downloads", "take me to my downloads",
            "bring up downloads", "show me downloads",
            "show me my downloads", "go to my downloads",
            "navigate to downloads",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isOpenDocumentsIntent(_ normalized: String) -> Bool {
        let snippets = [
            "open documents", "show documents", "go to documents",
            "open documents folder", "open my documents",
            "take me to documents", "take me to my documents",
            "bring up documents", "show me documents",
            "show me my documents", "navigate to documents",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isOpenDesktopIntent(_ normalized: String) -> Bool {
        let snippets = [
            "open desktop", "show desktop folder", "go to desktop",
            "open my desktop", "take me to desktop",
            "take me to my desktop", "show my desktop folder",
            "open the desktop folder", "go to the desktop",
            "navigate to desktop",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isOpenTrashIntent(_ normalized: String) -> Bool {
        let snippets = [
            "open trash", "show trash", "go to trash", "open the trash", "show the trash",
            "open my trash", "open bin", "show bin", "go to bin",
            "open recycle bin", "show recycle bin", "where is trash", "where is the trash",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isEmptyTrashIntent(_ normalized: String) -> Bool {
        let snippets = [
            "empty trash", "empty the trash", "empty my trash", "clear trash", "clear the trash",
            "erase trash", "delete trash", "delete everything in trash",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isEmptyTrashConfirmIntent(_ n: String) -> Bool {
        // Specific empty-trash phrases
        let specific = [
            "yes empty trash", "yes empty it", "please empty trash", "empty the trash please",
            "go ahead and empty", "empty trash now", "yes delete all", "yes clear trash",
        ]
        if specific.contains(where: { n == $0 || n.contains($0) }) { return true }
        // Generic affirmatives are accepted since the prompt is explicit about the consequence
        let affirmatives = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay",
                            "confirm", "do it", "yes do it", "go ahead", "yes go ahead",
                            "please do it", "yes please", "proceed"]
        return affirmatives.contains(where: { n == $0 })
    }

    // MARK: - Subfolder navigation ("open PJ folder in documents")

    /// Matches "open|show|find X [folder] in|on documents|downloads|desktop".
    /// Returns (sanitizedName, location) — callers should try exact match then case-insensitive scan.
    static func extractSubfolderOpenSpec(from normalized: String) -> (name: String, location: DeleteFolderLocation)? {
        let pattern =
            #"(?:^|\b)(?:open|show|go to|navigate to|take me to|find|bring up|look in|access)\s+(?:the\s+|my\s+)?(.+?)\s+(?:folder\s+)?(?:in|from|on|inside)\s+(?:my\s+)?(documents|downloads|desktop)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = normalized as NSString
        guard let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3,
              match.range(at: 1).location != NSNotFound,
              match.range(at: 2).location != NSNotFound
        else { return nil }

        var name = ns.substring(with: match.range(at: 1))
            .replacingOccurrences(of: #"\s+folder\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let locRaw = ns.substring(with: match.range(at: 2)).lowercased()

        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else { return nil }
        // Don't intercept bare well-known folder names already handled upstream
        let alreadyHandled = ["downloads", "documents", "desktop", "trash", "finder"]
        if alreadyHandled.contains(name.lowercased()) { return nil }

        let location: DeleteFolderLocation
        switch locRaw {
        case "desktop": location = .desktop
        case "documents": location = .documents
        case "downloads": location = .downloads
        default: return nil
        }
        return (sanitizeFolderName(name), location)
    }

    static func openSubfolderInFinder(name: String, location: DeleteFolderLocation) throws -> String {
        let home = realUserHomeForFiles()
        let (base, label): (URL, String)
        switch location {
        case .desktop:   (base, label) = (home.appendingPathComponent("Desktop"), "Desktop")
        case .documents: (base, label) = (home.appendingPathComponent("Documents"), "Documents")
        case .downloads: (base, label) = (home.appendingPathComponent("Downloads"), "Downloads")
        }

        // Exact match
        let directURL = base.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: directURL.path) {
            NSWorkspace.shared.open(directURL)
            return "Opened \(name) from \(label)."
        }

        // Case-insensitive scan: exact name → separator-agnostic → prefix fallback
        let normName = name.lowercased()
        let squeezedName = normalizedFileName(name)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        if let exact = entries.first(where: { $0.lastPathComponent.lowercased() == normName }) {
            NSWorkspace.shared.open(exact)
            return "Opened \(exact.lastPathComponent) from \(label)."
        }
        // Separator-agnostic: "myhub project" matches "MyHub_Project"
        if let hit = entries.first(where: { normalizedFileName($0.lastPathComponent) == squeezedName }) {
            NSWorkspace.shared.open(hit)
            return "Opened \(hit.lastPathComponent) from \(label)."
        }
        if let prefix = entries.first(where: { $0.lastPathComponent.lowercased().hasPrefix(normName) }) {
            NSWorkspace.shared.open(prefix)
            return "Opened \(prefix.lastPathComponent) from \(label)."
        }

        throw ControlError.actionFailed(
            "I couldn't find \"\(name)\" in your \(label). Check the spelling, or use find \(name) to search."
        )
    }

    // MARK: - Delete / file-pick confirm + cancel intents

    static func isDeleteConfirmIntent(_ n: String) -> Bool {
        if n == "yes" || n == "yeah" || n == "yep" || n == "ok" || n == "okay" { return true }
        let snippets = [
            "yes delete it", "yes please", "confirm", "delete it", "go ahead", "please delete",
            "please remove", "remove it", "trash it", "do it", "proceed", "ok delete", "sure delete",
            "please do that", "do that", "go for it",
        ]
        return snippets.contains(where: { n == $0 || n.contains($0) })
    }

    static func isDeleteOrFilePickCancelIntent(_ n: String) -> Bool {
        let snippets = [
            "cancel", "never mind", "nevermind", "stop", "no thanks", "no thank you",
            "don't delete", "do not delete", "forget it", "abort", "don't", "do not",
        ]
        return snippets.contains(where: { n == $0 || n.hasPrefix($0 + " ") || n.hasSuffix(" " + $0) })
    }

    /// True when the user's input looks like a wake phrase ("wake up orbit", "hey orbit", etc.)
    /// rather than a spelling response. Used to bail out of pending spelling state on re-wake.
    static func isWakePhraseInput(_ text: String) -> Bool {
        let patterns = [
            #"\bwake\s+(up\s+)?orbit\b"#,
            #"\bwake\s+up\b"#,
            #"\b(hey|hi|hello|hay|helo)\s+(up\s+)?orbit\b"#,
            #"\borbit\s+wake\s+up\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - Trash

    static func emptyTrashByRemovingContents() throws {
        let trash = realUserHomeForFiles().appendingPathComponent(".Trash")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trash.path, isDirectory: &isDir), isDir.boolValue else {
            throw ControlError.actionFailed("Could not find your Trash folder at ~/.Trash.")
        }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        } catch {
            throw ControlError.actionFailed("Could not read Trash: \(error.localizedDescription)")
        }
        if urls.isEmpty { return }
        var firstFailure: Error?
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure {
            throw ControlError.actionFailed(
                "Could not remove everything in Trash: \(firstFailure.localizedDescription). Close apps using files in Trash, or remove locked items in Finder, then try again."
            )
        }
    }

    // MARK: - File-pick index parsing

    static func parseOpenPickIndex(_ n: String) -> Int? {
        if let m = firstCapture(in: n, pattern: #"^open\s+(\d{1,2})$"#), let i = Int(m), (1...20).contains(i) { return i }
        if n == "open one" || n == "first" || n == "the first" || n == "first one" || n == "open first" || n == "number 1" || n == "#1" || n == "1" { return 1 }
        if n == "open two" || n == "second" || n == "the second" || n == "second one" || n == "open second" || n == "number 2" || n == "#2" || n == "2" { return 2 }
        if n == "open three" || n == "third" || n == "open third" || n == "number 3" || n == "#3" || n == "3" { return 3 }
        if n == "open four" || n == "fourth" || n == "open fourth" || n == "number 4" || n == "#4" || n == "4" { return 4 }
        if n == "open five" || n == "fifth" || n == "open fifth" || n == "number 5" || n == "#5" || n == "5" { return 5 }
        if n == "open six" || n == "sixth" || n == "open sixth" || n == "number 6" || n == "#6" || n == "6" { return 6 }
        if n == "open seven" || n == "seventh" || n == "open seventh" || n == "number 7" || n == "#7" || n == "7" { return 7 }
        if n == "open eight" || n == "eighth" || n == "open eighth" || n == "number 8" || n == "#8" || n == "8" { return 8 }
        return nil
    }

    // MARK: - Delete folder intent + execution

    static func extractDeleteFolderSpec(from normalized: String) -> (name: String, location: DeleteFolderLocation)? {
        let pattern =
            #"(?:^|\b)(?:delete|remove|trash)\s+(?:the\s+)?(?:folder\s+)?(.+?)\s+from\s+(?:my\s+)?(desktop|documents|downloads)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = normalized as NSString
        guard let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3
        else { return nil }
        var name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let locRaw = ns.substring(with: match.range(at: 2)).lowercased()
        name = name.replacingOccurrences(of: #"\s+folder\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else { return nil }
        let location: DeleteFolderLocation
        switch locRaw {
        case "desktop": location = .desktop
        case "documents": location = .documents
        case "downloads": location = .downloads
        default: return nil
        }
        return (sanitizeFolderName(name), location)
    }

    static func resolveDeleteFolderURL(name: String, location: DeleteFolderLocation) throws -> URL {
        let home = realUserHomeForFiles()
        let base: URL
        switch location {
        case .desktop: base = home.appendingPathComponent("Desktop")
        case .documents: base = home.appendingPathComponent("Documents")
        case .downloads: base = home.appendingPathComponent("Downloads")
        }
        return base.appendingPathComponent(name)
    }

    static func isURLUnderUserDeletableRoots(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let rp = resolved.path
        let home = realUserHomeForFiles().path
        let roots = [
            home + "/Desktop",
            home + "/Documents",
            home + "/Downloads",
        ]
        guard roots.contains(where: { rp == $0 || rp.hasPrefix($0 + "/") }) else { return false }
        if rp == home || rp == home + "/" { return false }
        return true
    }

    static func proposeDeleteFolder(named name: String, location: DeleteFolderLocation) throws -> String {
        guard !name.isEmpty else {
            throw ControlError.actionFailed("Tell me which folder to delete, for example: delete folder Notes from my desktop.")
        }
        let url = try resolveDeleteFolderURL(name: name, location: location)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlError.actionFailed("Nothing exists at \(tildeDisplayPath(for: url)). Check the folder name.")
        }
        guard isURLUnderUserDeletableRoots(url) else {
            throw ControlError.actionFailed("For safety, I can only delete folders inside your Desktop, Documents, or Downloads.")
        }
        OrbitLocalActionPendingStore.shared.clearEmptyTrashProposal()
        OrbitLocalActionPendingStore.shared.clearFilePick()
        OrbitLocalActionPendingStore.shared.setDeleteProposal(url: url, summary: name)
        return """
        I can move this folder to Trash: \(name) (\(tildeDisplayPath(for: url))).

        Reply yes delete it to confirm, or cancel to stop. I will not delete anything until you confirm.
        """
    }

    static func moveUserItemToTrash(at url: URL) throws {
        guard isURLUnderUserDeletableRoots(url) else {
            throw ControlError.actionFailed("Refusing to delete outside Desktop, Documents, or Downloads.")
        }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw ControlError.actionFailed("Trash failed: \(error.localizedDescription)")
        }
    }

    // MARK: - File search intent + execution

    static func extractFindFileQuery(from normalized: String) -> String? {
        // Explicit patterns — user names the type (file/doc/folder/app)
        let explicitPatterns = [
            #"(?:^|\b)(?:find|search)\s+([a-z0-9 ._+\-']+?)\s+(?:file|document|doc|folder|app|application)\s*$"#,
            #"(?:^|\b)(?:find|search)\s+(?:file|document|doc|folder|app|application)\s+(?:named\s+)?([a-z0-9 ._+\-']+)$"#,
            #"(?:^|\b)(?:find|search)\s+for\s+([a-z0-9 ._+\-']+)\s+(?:file|document|doc|folder|app|application)$"#,
            #"(?:^|\b)(?:where is|locate)\s+(?:my\s+)?([a-z0-9 ._+\-']+)$"#,
            #"(?:^|\b)(?:where's|wheres)\s+(?:my\s+)?([a-z0-9 ._+\-']+)$"#,
            #"(?:^|\b)(?:show me|can you find)\s+(?:my\s+)?([a-z0-9 ._+\-']+?)\s+(?:file|document|doc|folder|app)$"#,
        ]
        for pattern in explicitPatterns {
            if let match = firstCapture(in: normalized, pattern: pattern) {
                let cleaned = cleanedUserToken(match)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        // Loose patterns — no type qualifier; search everything (files + folders + apps)
        let loosePatterns = [
            #"(?:^|\b)find\s+([a-z0-9][a-z0-9 ._+\-']{2,})$"#,
            #"(?:^|\b)(?:search|look)\s+for\s+([a-z0-9][a-z0-9 ._+\-']{2,})$"#,
            #"(?:^|\b)(?:can\s+you\s+find|help\s+me\s+find)\s+(?:my\s+)?([a-z0-9][a-z0-9 ._+\-']{2,})$"#,
        ]
        for pattern in loosePatterns {
            guard let loose = firstCapture(in: normalized, pattern: pattern) else { continue }
            let token = loose.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("out ") || token.hasPrefix("if ") { continue }
            if looseFindSubstringDenylist.contains(where: { token.contains($0) }) { continue }
            let cleaned = cleanedUserToken(token)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    static let looseFindSubstringDenylist: [String] = [
        "wifi", "wi fi", "bluetooth", "volume", "battery", "focus", "finder", "calendar",
        "system settings", "app store", "google chrome",
        "how to", "why is", "what is", "can you", "could you",
    ]

    static func runMdfind(_ arguments: [String]) throws -> [String] {
        let result = try runCommand("/usr/bin/mdfind", arguments, failOnNonZero: false)
        return result.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(700)
            .map { $0 }
    }

    /// Directory components that are never what the user means by "find my X" —
    /// dependency/build junk that flooded results (e.g. lodash's sum.js matching "resume").
    static let findJunkDirComponents: Set<String> = [
        "node_modules", ".git", "Pods", ".venv", "venv", "DerivedData",
        "dist", "build", ".build", "vendor", "__pycache__", "site-packages",
        ".pytest_cache", ".next", "coverage",
    ]

    static func isPathInUserSearchScope(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { findJunkDirComponents.contains($0) }) { return false }
        let home = realUserHomeForFiles().path
        // iCloud Drive: ~/Library/Mobile Documents/... — must come first before the Library exclusion
        if path.hasPrefix(home + "/Library/Mobile Documents/") { return true }
        // Other cloud storage (OneDrive, Dropbox via CloudStorage)
        if path.hasPrefix(home + "/Library/CloudStorage/") { return true }
        // System + user applications — included so bare "find X" can surface apps
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return true }
        // Standard user home subtree
        guard path.hasPrefix(home + "/") else { return false }
        // Exclude the rest of ~/Library (caches, support, prefs, etc.)
        if path.hasPrefix(home + "/Library/") { return false }
        return true
    }

    static func collectFindCandidates(named query: String) throws -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func appendUnique(_ paths: [String]) {
            for p in paths {
                guard isPathInUserSearchScope(p) else { continue }
                if seen.insert(p).inserted { ordered.append(p) }
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // For short queries (≤5 chars): scan Desktop/Documents/Downloads directly first.
        // mdfind broad globs return thousands of results for short strings and may miss exact matches.
        let normTrimmed = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        if normTrimmed.count <= 5 {
            let home = realUserHomeForFiles()
            let roots = [
                home.appendingPathComponent("Desktop"),
                home.appendingPathComponent("Documents"),
                home.appendingPathComponent("Downloads"),
            ]
            for root in roots {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                let exactHits = entries.filter {
                    normalizedFileName($0.lastPathComponent) == normTrimmed
                }.map { $0.path }
                appendUnique(exactHits)
                let prefixHits = entries.filter {
                    normalizedFileName($0.lastPathComponent).hasPrefix(normTrimmed) && normalizedFileName($0.lastPathComponent) != normTrimmed
                }.map { $0.path }
                appendUnique(prefixHits)
            }
        }

        let starParts = trimmed.lowercased()
            .split { $0.isWhitespace || $0 == "-" }
            .map { String($0) }
            .filter { !$0.isEmpty }
        if !starParts.isEmpty {
            let glob = "*\(starParts.joined(separator: "*"))*"
            appendUnique(try runMdfind(["-name", glob]))
        }

        // Drop filler words and short fragments — "find my resume file" must search for
        // "resume", not explode into an OR-query on "my" that matches Myanmar.js.
        let fillerTokens: Set<String> = ["my", "the", "our", "your", "file", "files",
                                         "folder", "doc", "docs", "document", "documents"]
        let tokens = trimmed.split { $0.isWhitespace || $0 == "-" }
            .map { String($0).lowercased() }
            .filter { $0.count >= 3 && !fillerTokens.contains($0) }
        let safeTokens = tokens.filter { !$0.contains("*") && !$0.contains("?") && !$0.contains("'") }
        if safeTokens.count >= 2 {
            let andClause = safeTokens.map { "(kMDItemFSName == '*\($0)*'c)" }.joined(separator: " && ")
            appendUnique(try runMdfind([andClause]))
            let orClause = safeTokens.map { "(kMDItemFSName == '*\($0)*'c)" }.joined(separator: " || ")
            appendUnique(try runMdfind([orClause]))
        } else if safeTokens.count == 1, let t = safeTokens.first, t.count >= 5 {
            let prefix = String(t.prefix(4))
            appendUnique(try runMdfind(["(kMDItemFSName == '*\(prefix)*'c)"]))
        }

        let squashed = normalizedFileName(trimmed)
        if squashed.count >= 4 {
            appendUnique(try runMdfind(["(kMDItemFSName == '*\(squashed)*'c)"]))
        }

        // Spelling-variant fallback: use 5-char prefix AND clause so "enrollment" finds
        // "Enrolment" (both share "enrol"), "colour" finds "color" (share "colo"), etc.
        // Only runs when the standard token AND search added nothing meaningful.
        if ordered.count < 5 && safeTokens.count >= 2 {
            let longToks = safeTokens.filter { $0.count >= 5 }
            if longToks.count >= 2 {
                let prefixAnd = longToks
                    .map { "(kMDItemFSName == '*\(String($0.prefix(5)))*'c)" }
                    .joined(separator: " && ")
                appendUnique(try runMdfind([prefixAnd]))
            }
        }

        // Local directory scan: when Spotlight yields nothing, enumerate common folders and
        // match filenames with per-token Levenshtein distance ≤ 2.  Catches files that aren't
        // indexed yet (new iCloud downloads, external drives, etc.).
        if ordered.isEmpty {
            appendUnique(localFuzzyScan(for: trimmed))
        }

        let pool = ordered.count > 300 ? Array(ordered.prefix(300)) : ordered
        return rankFindCandidates(query: trimmed, paths: pool)
    }

    static func localFuzzyScan(for query: String) -> [String] {
        let queryTokens = query.lowercased()
            .split { $0.isWhitespace || $0 == "-" }
            .map { String($0) }
            .filter { $0.count >= 3 }
        guard !queryTokens.isEmpty else { return [] }

        let home = realUserHomeForFiles()
        var scanDirs: [URL] = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
        ]
        let iCloudRoot = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloudRoot.path) {
            scanDirs.append(iCloudRoot)
        }

        var results: [String] = []
        let fm = FileManager.default
        for dir in scanDirs {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if findJunkDirComponents.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                let nameFull = url.lastPathComponent.lowercased()
                let fileTokens = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" }
                    .map { String($0) }
                let allMatch = queryTokens.allSatisfy { qTok in
                    nameFull.contains(qTok) ||
                    fileTokens.contains { fTok in
                        fTok == qTok || (fTok.count >= 3 && qTok.count >= 3 && levenshteinDistance(fTok, qTok) <= 2)
                    }
                }
                if allMatch {
                    results.append(url.path)
                    if results.count >= 30 { return results }
                }
            }
        }
        return results
    }

    static func rankFindCandidates(query: String, paths: [String]) -> [String] {
        let qn = normalizedFileName(query)
        let capped = paths.count > 120 ? Array(paths.prefix(120)) : paths
        return capped.sorted { a, b in
            findPathMatchScore(path: a, queryNorm: qn) < findPathMatchScore(path: b, queryNorm: qn)
        }
    }

    static func findPathMatchScore(path: String, queryNorm: String) -> Int {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bn = normalizedFileName(base)
        if bn == queryNorm { return 0 }
        if bn.contains(queryNorm) { return 1 }
        // Reverse containment needs a substantial name — "sum" ⊂ "resume" is noise, not a match.
        if queryNorm.contains(bn), bn.count >= 5 { return 4 }
        return 10 + min(levenshteinDistance(bn, queryNorm), 48)
    }

    static func levenshteinDistance(_ s: String, _ t: String) -> Int {
        let a = Array(s), b = Array(t)
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? 0 : 1
                cur.append(min(prev[j] + 1, cur[j] + 1, prev[j + 1] + cost))
            }
            prev = cur
        }
        return prev.last ?? s.count + t.count
    }

    /// Searches Desktop, Documents, and Downloads for a folder matching `name` (case-insensitive,
    /// prefix fallback), opens it in Finder, and returns a reply string.
    /// On failure sets spelling pending and returns a short prompt.
    static func findAndOpenFolderAcrossLocations(name: String) -> String {
        guard !name.isEmpty else { return "Tell me the folder name." }
        let home = realUserHomeForFiles()
        let roots: [(URL, String)] = [
            (home.appendingPathComponent("Desktop"), "Desktop"),
            (home.appendingPathComponent("Documents"), "Documents"),
            (home.appendingPathComponent("Downloads"), "Downloads"),
        ]
        // Normalized match: strips underscores, spaces, hyphens so "myhub project" == "MyHub_Project".
        let squeezedName = normalizedFileName(name)
        let lowerName = name.lowercased()
        for (base, label) in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            // Exact case-insensitive (original names like "notes")
            if let hit = entries.first(where: { $0.lastPathComponent.lowercased() == lowerName }) {
                NSWorkspace.shared.open(hit)
                return "Opened \(hit.lastPathComponent) from \(label)."
            }
            // Separator-agnostic match: "myhub project" matches "MyHub_Project", "my-hub-project", etc.
            if let hit = entries.first(where: { normalizedFileName($0.lastPathComponent) == squeezedName }) {
                NSWorkspace.shared.open(hit)
                return "Opened \(hit.lastPathComponent) from \(label)."
            }
        }
        // Prefix fallback across all roots
        for (base, label) in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            if let hit = entries.first(where: { normalizedFileName($0.lastPathComponent).hasPrefix(squeezedName) && !squeezedName.isEmpty }) {
                NSWorkspace.shared.open(hit)
                return "Opened \(hit.lastPathComponent) from \(label)."
            }
        }
        // Fuzzy match — no exact hit but something looks similar. Offer it for confirmation.
        var bestHit: URL? = nil
        var bestScore: Double = 0
        for (base, _) in roots {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for entry in entries {
                let score = fuzzyFolderScore(query: squeezedName, folderNorm: normalizedFileName(entry.lastPathComponent)) ?? 0
                if score > bestScore { bestScore = score; bestHit = entry }
            }
        }
        if let hit = bestHit {
            OrbitLocalActionPendingStore.shared.setFolderConfirm(url: hit, displayName: hit.lastPathComponent)
            return "I found \u{201C}\(hit.lastPathComponent)\u{201D} \u{2014} looks like it might be what you\u{2019}re after. Want me to open it?"
        }
        OrbitLocalActionPendingStore.shared.setSpellingPending(.openSubfolder(locationLabel: "your folders"))
        return "I couldn't find a \"\(name)\" folder. Can you spell it for me?"
    }

    /// Extracts "open X folder" intent where no location (Desktop/Documents/Downloads) is given.
    static func extractOpenFolderNoLocationSpec(from normalized: String) -> String? {
        // Must end with " folder" and start with open/show/find — but NOT already matched by extractSubfolderOpenSpec.
        let pattern = #"^(?:open|show|find|go to|take me to)\s+(?:the\s+|my\s+)?(.+?)\s+folder\s*$"#
        guard let match = firstCapture(in: normalized, pattern: pattern) else { return nil }
        let name = match.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject if it ends with a location qualifier (handled by extractSubfolderOpenSpec already).
        let locationQualifiers = ["in desktop", "in documents", "in downloads",
                                  "on desktop", "on documents", "on downloads",
                                  "from desktop", "from documents", "from downloads"]
        if locationQualifiers.contains(where: { normalized.hasSuffix($0) }) { return nil }
        // Reject known standalone folder names.
        let wellKnown = ["downloads", "documents", "desktop", "trash", "finder"]
        if wellKnown.contains(name.lowercased()) { return nil }
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        return sanitizeFolderName(name)
    }

    static func findAndMaybeOpenFile(named query: String) async throws -> String {
        guard !query.isEmpty else {
            throw ControlError.actionFailed("Tell me a file name to search for.")
        }
        OrbitLocalActionPendingStore.shared.clearFilePick()

        let candidates = try await collectFindCandidatesAsync(named: query)
        if candidates.isEmpty {
            return "I couldn\u{2019}t find anything named \u{201C}\(query)\u{201D}."
        }

        let queryNorm = normalizedFileName(query)
        let exact = candidates.first { path in
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return normalizedFileName(base) == queryNorm
        }
        if let exact {
            let opened = NSWorkspace.shared.open(URL(fileURLWithPath: exact))
            if opened {
                return "Found and opened \(exact.components(separatedBy: "/").last ?? "the file")\n\(tildeDisplayPath(for: URL(fileURLWithPath: exact)))"
            }
            return "I found a match at \(tildeDisplayPath(for: URL(fileURLWithPath: exact))), but macOS would not open it. Check System Settings \u{2192} Privacy & Security \u{2192} Files and Folders for ORBITMac."
        }

        if candidates.count == 1 {
            let path = candidates[0]
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let isFuzzyOnly = normalizedFileName(base) != queryNorm
            if isFuzzyOnly {
                OrbitLocalActionPendingStore.shared.setFilePick(paths: [path])
                return """
                I didn't find an exact match for \(displayName(for: query)), but this looks like the closest file:

                1. \((path as NSString).lastPathComponent)
                   \(tildeDisplayPath(for: URL(fileURLWithPath: path)))

                Say **open 1** if that's the one you want, or **cancel**.
                """
            }
            let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            if opened {
                return "Found and opened \((path as NSString).lastPathComponent)\n\(tildeDisplayPath(for: URL(fileURLWithPath: path)))"
            }
            return "I found \((path as NSString).lastPathComponent) at \(tildeDisplayPath(for: URL(fileURLWithPath: path))), but macOS would not open it."
        }

        let top = Array(candidates.prefix(8))
        OrbitLocalActionPendingStore.shared.setFilePick(paths: top)
        let lines = top.enumerated().map { idx, path in
            "\(idx + 1). \((path as NSString).lastPathComponent)\n   \(tildeDisplayPath(for: URL(fileURLWithPath: path)))"
        }.joined(separator: "\n\n")
        return """
        I found \(candidates.count) matches for \(displayName(for: query)). Here are the first \(top.count) (numbered):

        \(lines)

        Say open 1 or open 2 to open one of these, or cancel to dismiss. For a shorter list, try a longer name (for example include Patel or pdf).
        """
    }

    static func collectFindCandidatesAsync(named query: String) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask(priority: .userInitiated) {
                try collectFindCandidates(named: query)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 7_000_000_000)
                throw ControlError.actionFailed("File search is taking too long right now. Please try again with a slightly longer filename.")
            }
            let first = try await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    // MARK: - Project folder creation

    static func extractProjectFolderSpec(from normalized: String) -> (name: String, parent: ProjectFolderParent, scaffold: ProjectFolderScaffold)? {
        let patterns = [
            #"(?:^|\b)(?:create|make)\s+(?:a\s+)?folder\s+named\s+(.+)$"#,
            #"(?:^|\b)(?:create|make)\s+(?:a\s+)?(?:project\s+)?folder(?:\s+named)?\s+(.+)$"#,
            #"(?:^|\b)new\s+project\s+(.+)$"#,
        ]
        for pattern in patterns {
            if let match = firstCapture(in: normalized, pattern: pattern) {
                let trimmed = stripTrailingConversationalFill(match.trimmingCharacters(in: .whitespacesAndNewlines))
                let (baseWithScaffold, parent) = stripProjectFolderLocation(from: trimmed)
                let (base, scaffold) = stripProjectScaffold(from: baseWithScaffold)
                let name = cleanedUserToken(base)
                if !name.isEmpty { return (name, parent, scaffold) }
            }
        }
        return nil
    }

    static func stripProjectScaffold(from raw: String) -> (String, ProjectFolderScaffold) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return (s, .standard) }
        if let (rest, names) = extractCustomSubfolderList(from: s) {
            let cleanedNames = names.compactMap { n -> String? in
                let t = sanitizeFolderName(n)
                return t.isEmpty ? nil : t
            }
            if cleanedNames.isEmpty { return (rest, .standard) }
            return (rest, .custom(cleanedNames))
        }
        if let rest = stripFlatProjectSuffix(from: s) { return (rest, .flat) }
        if let rest = stripDefaultScaffoldHint(from: s) { return (rest, .standard) }
        return (s, .standard)
    }

    static func extractCustomSubfolderList(from s: String) -> (String, [String])? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\s+with\s+(?:folders|subfolders)\s+(.+)$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1
        else { return nil }
        let listRaw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = ns.substring(with: NSRange(location: 0, length: m.range.location)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !listRaw.isEmpty else { return nil }
        var parts: [String] = []
        for segment in listRaw.split(separator: ",") {
            let piece = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }
            for sub in piece.components(separatedBy: " and ") {
                let t = sub.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { parts.append(t) }
            }
        }
        let capped = Array(parts.prefix(12))
        return capped.isEmpty ? nil : (rest, capped)
    }

    static let flatProjectSuffixes: [String] = [
        " with no subfolders", " with no internal folders", " with no inner folders",
        " with no extra folders", " with nothing inside", " with empty inside",
        " with just the main folder", " with only the main folder", " without subfolders",
        " without internal folders", " without any inner folders", " without inner folders",
        " flat layout", " flat inside", " flat only", " no subfolders", " no internal folders",
    ]

    static func stripFlatProjectSuffix(from s: String) -> String? {
        let lower = s.lowercased()
        for suffix in flatProjectSuffixes.sorted(by: { $0.count > $1.count }) {
            if lower.hasSuffix(suffix) {
                let end = s.index(s.endIndex, offsetBy: -suffix.count)
                let cut = String(s[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                return cut.isEmpty ? nil : cut
            }
        }
        return nil
    }

    static let defaultScaffoldHintSuffixes: [String] = [
        " with default folders", " with default structure", " with standard folders",
        " with your default folders", " default layout", " whatever you want inside",
        " whatever structure you want", " nothing specific for folders",
        " no preference on folders", " i do not care about inner folders",
        " i don't care about inner folders",
    ]

    static func stripDefaultScaffoldHint(from s: String) -> String? {
        let lower = s.lowercased()
        for suffix in defaultScaffoldHintSuffixes.sorted(by: { $0.count > $1.count }) {
            if lower.hasSuffix(suffix) {
                let end = s.index(s.endIndex, offsetBy: -suffix.count)
                let cut = String(s[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                return cut.isEmpty ? nil : cut
            }
        }
        return nil
    }

    static func stripTrailingConversationalFill(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var lower = s.lowercased()
        let softSuffixes = [
            " please", " thanks", " thank you", " if you can", " if possible",
            " when you can", " would be great", " would be appreciated", " for me",
        ]
        var changed = true
        while changed {
            changed = false
            for suf in softSuffixes.sorted(by: { $0.count > $1.count }) {
                if lower.hasSuffix(suf) {
                    s = String(s.dropLast(suf.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    lower = s.lowercased()
                    changed = true
                    break
                }
            }
        }
        return s
    }

    static func stripProjectFolderLocation(from raw: String) -> (String, ProjectFolderParent) {
        let s = stripTrailingConversationalFill(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let suffixes: [(String, ProjectFolderParent)] = [
            (" on my desktop please", .desktop), (" on the desktop please", .desktop),
            (" on desktop please", .desktop), (" in desktop please", .desktop),
            (" to desktop please", .desktop), (" on my desktop", .desktop),
            (" on the desktop", .desktop), (" on desktop", .desktop),
            (" in desktop", .desktop), (" to desktop", .desktop),
            (" on my documents please", .documentsOrbitProjects),
            (" in my documents please", .documentsOrbitProjects),
            (" on documents please", .documentsOrbitProjects),
            (" in documents please", .documentsOrbitProjects),
            (" on my documents", .documentsOrbitProjects),
            (" in my documents", .documentsOrbitProjects),
            (" on documents", .documentsOrbitProjects),
            (" in documents", .documentsOrbitProjects),
        ]
        for (suffix, parent) in suffixes.sorted(by: { $0.0.count > $1.0.count }) {
            if s.hasSuffix(suffix) {
                let cut = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return (cut, parent)
            }
        }
        return (s, .documentsOrbitProjects)
    }

    static func createProjectFolderTemplate(named rawName: String, parent: ProjectFolderParent, scaffold: ProjectFolderScaffold) throws -> String {
        let safeName = sanitizeFolderName(rawName)
        guard !safeName.isEmpty else {
            throw ControlError.actionFailed("I need a valid project folder name.")
        }
        let rootParent: URL
        switch parent {
        case .documentsOrbitProjects:
            rootParent = realUserHomeForFiles().appendingPathComponent("Documents").appendingPathComponent("ORBIT Projects")
        case .desktop:
            rootParent = realUserHomeForFiles().appendingPathComponent("Desktop")
        }
        let project = rootParent.appendingPathComponent(safeName)
        let fm = FileManager.default
        let subfolders: [String]
        switch scaffold {
        case .standard: subfolders = ["Notes", "Assets", "Drafts"]
        case .flat: subfolders = []
        case .custom(let names): subfolders = names
        }
        do {
            try fm.createDirectory(at: project, withIntermediateDirectories: true, attributes: nil)
            for name in subfolders {
                try fm.createDirectory(at: project.appendingPathComponent(name), withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            throw ControlError.actionFailed(
                "I couldn't create folders at \(tildeDisplayPath(for: project)). Allow ORBITMac under System Settings \u{2192} Privacy & Security \u{2192} Files and Folders, then try again."
            )
        }
        _ = NSWorkspace.shared.open(project)
        switch scaffold {
        case .standard:
            return "Created project folder at \(tildeDisplayPath(for: project)) with Notes, Assets, and Drafts."
        case .flat:
            return "Created folder at \(tildeDisplayPath(for: project)) with no subfolders."
        case .custom(let names):
            return "Created project folder at \(tildeDisplayPath(for: project)) with subfolders: \(names.joined(separator: ", "))."
        }
    }

    // MARK: - Folder name sanitization + file name normalization

    static func sanitizeFolderName(_ raw: String) -> String {
        raw
            .split(separator: " ").map(String.init).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\\/:*?"<>|]"#, with: "", options: .regularExpression)
    }

    static func normalizedFileName(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    // MARK: - Fuzzy folder matching

    /// Levenshtein edit distance — both strings should already be lowercased.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let temp = row[j]
                row[j] = a[i-1] == b[j-1] ? prev : Swift.min(prev, Swift.min(row[j], row[j-1])) + 1
                prev = temp
            }
        }
        return row[b.count]
    }

    /// Similarity score (0...1) if the folder is a plausible fuzzy hit for the query, else nil.
    /// Both arguments must already be run through `normalizedFileName` (all lowercase, no separators).
    static func fuzzyFolderScore(query: String, folderNorm: String) -> Double? {
        guard query.count >= 3, folderNorm.count >= 3 else { return nil }
        // Substring containment: user said part of the folder name (or more than the folder name).
        if folderNorm.contains(query) || query.contains(folderNorm) { return 0.95 }
        // Edit distance: allow up to 40% differences (covers one misheard word, a dropped letter, etc.)
        let maxLen = max(query.count, folderNorm.count)
        let sim = 1.0 - Double(editDistance(query, folderNorm)) / Double(maxLen)
        return sim >= 0.60 ? sim : nil
    }
}
