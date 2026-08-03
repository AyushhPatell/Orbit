//
//  OrbitConversationContext.swift
//  ORBITMac
//
//  Two responsibilities:
//  1. Speech context hints — feeds app names, contacts, tech terms to SFSpeechRecognitionRequest
//     for better STT accuracy (reduces "git"→"gate" type mishearings).
//  2. Short-term conversation memory — tracks last N command results so the user can say
//     "open that file", "remind me about that", "that one" and ORBIT resolves the reference.
//

import AppKit
import Contacts
import Foundation

// MARK: - Speech context hints

enum OrbitSpeechContextProvider {

    static func contextualStrings() -> [String] {
        var hints: [String] = []

        // ORBIT-specific terms
        hints += ["ORBIT", "Hey ORBIT", "wake up ORBIT"]

        // Developer tools (commonly misheared)
        hints += ["git", "git status", "git pull", "git push", "git commit", "git clone",
                  "git checkout", "git branch", "git merge", "git stash", "git log", "git diff",
                  "npm", "npm install", "npm start", "npm run", "npx",
                  "node", "python", "python3", "pip", "pip install",
                  "brew", "brew install", "brew update",
                  "swift", "xcodebuild", "xcode",
                  "docker", "kubectl", "terraform"]

        // Common app names on this Mac
        let runningApps = NSWorkspace.shared.runningApplications
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty && $0.count <= 25 }
        hints += runningApps

        // Installed apps (top ones)
        let appDirs = ["/Applications", "/Applications/Utilities"]
        for dir in appDirs {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                hints += contents
                    .filter { $0.hasSuffix(".app") }
                    .map { $0.replacingOccurrences(of: ".app", with: "") }
                    .prefix(30)
            }
        }

        // Desktop/Documents/Downloads folder names (project names the user might say)
        let home = FileManager.default.homeDirectoryForCurrentUser
        for loc in ["Desktop", "Documents", "Downloads"] {
            let path = home.appendingPathComponent(loc)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: path.path) {
                hints += contents
                    .filter { !$0.hasPrefix(".") }
                    .prefix(20)
            }
        }
        // One level deeper in Documents (project subfolder names)
        let docsPath = home.appendingPathComponent("Documents")
        if let subs = try? FileManager.default.contentsOfDirectory(atPath: docsPath.path) {
            for sub in subs.prefix(10) {
                let subPath = docsPath.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: subPath.path, isDirectory: &isDir), isDir.boolValue {
                    if let deepContents = try? FileManager.default.contentsOfDirectory(atPath: subPath.path) {
                        hints += deepContents.filter { !$0.hasPrefix(".") }.prefix(10)
                    }
                }
            }
        }

        // Contact first names (for "call John", "message Mom")
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
            if let contacts = try? store.unifiedContacts(matching: NSPredicate(value: true), keysToFetch: keys) {
                let names = contacts.prefix(50).flatMap { contact -> [String] in
                    var n: [String] = []
                    if !contact.givenName.isEmpty { n.append(contact.givenName) }
                    if !contact.familyName.isEmpty { n.append(contact.familyName) }
                    if !contact.nickname.isEmpty { n.append(contact.nickname) }
                    let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    if !full.isEmpty { n.append(full) }
                    return n
                }
                hints += names
            }
        }

        // System command vocabulary
        hints += ["volume", "brightness", "dark mode", "focus mode", "do not disturb",
                  "Wi-Fi", "Bluetooth", "battery", "mute", "unmute",
                  "take a note", "reminder", "calendar", "schedule", "meeting",
                  "summarize", "translate", "clipboard", "terminal",
                  "turn on", "turn off", "night shift"]

        // Site names from browser aliases
        hints += Array(OrbitMacControlCenter.siteAliases.keys.prefix(40))

        // Deduplicate and limit (Apple recommends < 1000)
        let unique = Array(Set(hints)).sorted()
        return Array(unique.prefix(500))
    }
}

// MARK: - Conversation context memory

@MainActor
final class OrbitConversationMemory {
    static let shared = OrbitConversationMemory()
    private init() {}

    struct ContextEntry {
        let type: EntryType
        let value: String
        let timestamp: Date
    }

    enum EntryType {
        case filePath
        case folderPath
        case contactName
        case reminderTitle
        case eventTitle
        case noteTitle
        case searchQuery
        case appName
        /// The last system feature ORBIT toggled — "wifi", "volume", "brightness", …
        /// Lets "turn it back on" resolve without a brain call, so it works offline.
        case systemTarget
        case general
    }

    private var entries: [ContextEntry] = []
    private let maxEntries = 10
    private let ttl: TimeInterval = 300 // 5 minutes

    func record(_ type: EntryType, value: String) {
        entries.insert(ContextEntry(type: type, value: value, timestamp: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast() }
    }

    func lastEntry(of type: EntryType) -> String? {
        let now = Date()
        return entries.first { $0.type == type && now.timeIntervalSince($0.timestamp) < ttl }?.value
    }

    func lastAny() -> ContextEntry? {
        let now = Date()
        return entries.first { now.timeIntervalSince($0.timestamp) < ttl }
    }

    func lastFilePath() -> String? { lastEntry(of: .filePath) }
    func lastContact() -> String? { lastEntry(of: .contactName) }
    func lastNote() -> String? { lastEntry(of: .noteTitle) }
    func lastSystemTarget() -> String? { lastEntry(of: .systemTarget) }

    /// Resolve anaphora: "that", "it", "the last one", "that file", "that note"
    func resolveReference(_ text: String) -> (type: EntryType, value: String)? {
        let lower = text.lowercased()
        let now = Date()
        let active = entries.filter { now.timeIntervalSince($0.timestamp) < ttl }
        guard !active.isEmpty else { return nil }

        // Type-specific references
        if lower.contains("that file") || lower.contains("the file") || lower.contains("that document") {
            if let e = active.first(where: { $0.type == .filePath }) { return (e.type, e.value) }
        }
        if lower.contains("that note") || lower.contains("the note") || lower.contains("that list") {
            if let e = active.first(where: { $0.type == .noteTitle }) { return (e.type, e.value) }
        }
        if lower.contains("that reminder") || lower.contains("the reminder") {
            if let e = active.first(where: { $0.type == .reminderTitle }) { return (e.type, e.value) }
        }
        if lower.contains("that contact") || lower.contains("that person") {
            if let e = active.first(where: { $0.type == .contactName }) { return (e.type, e.value) }
        }
        if lower.contains("that app") || lower.contains("the app") {
            if let e = active.first(where: { $0.type == .appName }) { return (e.type, e.value) }
        }

        // Generic: "that", "it", "the last one" → most recent entry
        if lower == "that" || lower == "it" || lower == "that one" || lower == "the last one"
            || lower == "this" || lower == "this one" {
            let e = active[0]
            return (e.type, e.value)
        }

        return nil
    }

    func clear() { entries.removeAll() }
}
