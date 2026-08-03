//
//  OrbitMacControlCenter+Queries.swift
//  ORBITMac
//
//  List queries: upcoming reminders, upcoming events, files in folder, shutdown.
//

import Foundation

extension OrbitMacControlCenter {

    // MARK: - List reminders intent

    static func isListRemindersIntent(_ normalized: String) -> Bool {
        let phrases = [
            "my reminders", "my upcoming reminders", "upcoming reminders",
            "my upcoming reminder", "upcoming reminder",
            "list reminders", "show reminders", "show my reminders",
            "what reminders", "any reminders", "pending reminders",
            "check reminders", "all reminders", "see my reminders",
            "view reminders", "view my reminders",
            "what are my reminders", "what are my upcoming reminders",
            "do i have any reminders", "do i have reminders",
            "do i have any upcoming reminder", "do i have upcoming reminder",
            "how many reminders", "any pending reminders",
            // Past / completed reminders
            "past reminders", "past reminder", "old reminders", "old reminder",
            "previous reminders", "previous reminder",
            "what were my reminders", "what are my past reminders",
        ]
        if phrases.contains(where: { normalized.contains($0) }) { return true }
        // Regex catch-all: handles STT variation in phrasing and word order
        return normalized.range(
            of: #"\b(show|list|what are|what were|see|check|view|any|do i have)\b.{0,30}\breminders?\b"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - List events intent

    static func isListEventsIntent(_ normalized: String) -> Bool {
        let phrases = [
            "my events", "my upcoming events", "upcoming events",
            "my calendar events", "calendar events",
            "what's on my calendar", "whats on my calendar", "what is on my calendar",
            "what's on my schedule", "whats on my schedule", "what is on my schedule",
            "what's on today", "whats on today", "what is on today",
            "what's on this week", "whats on this week",
            "show my events", "show my calendar", "show events",
            "list events", "list my events",
            "what are my events", "what are my upcoming events",
            "do i have any events", "do i have any upcoming",
            "do i have any upcoming event", "do i have upcoming",
            "do i have events", "any events", "any upcoming events",
            "what do i have today", "what do i have this week",
            "what's my schedule", "whats my schedule", "my schedule",
            "anything on my calendar", "anything coming up",
            "what's coming up", "whats coming up",
            "free today", "busy today", "am i free",
            // Phonetic aliases — STT mishears of "events" with Indian accent
            "show me intense", "show my intense", "my intense", "show intense",
            "show me in tense", "intense today", "intense this week",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    // MARK: - List files in folder

    static func handleListFilesIntent(_ normalized: String) -> Outcome? {
        let phrases = [
            "what files", "what folders", "list files", "list folders",
            "show files", "show folders", "show me files", "show me folders",
            "what do i have in", "what's in my", "whats in my",
            "files in my", "folders in my", "files on my", "folders on my",
            "what documents", "list documents",
        ]
        guard phrases.contains(where: { normalized.contains($0) }) else { return nil }

        let location: String
        let locationLabel: String
        if normalized.contains("desktop") {
            location = "Desktop"; locationLabel = "Desktop"
        } else if normalized.contains("download") {
            location = "Downloads"; locationLabel = "Downloads"
        } else {
            location = "Documents"; locationLabel = "Documents"
        }

        let home = realUserHomeForFiles()
        let folderURL = home.appendingPathComponent(location)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) else {
            return Outcome(handled: true, reply: "I couldn\u{2019}t access your \(locationLabel) folder.", appendWakeConversationPrompt: false)
        }

        let items = contents
            .filter { !$0.hasPrefix(".") }
            .sorted()

        if items.isEmpty {
            return Outcome(handled: true, reply: "Your \(locationLabel) folder is empty.", appendWakeConversationPrompt: false)
        }

        // Separate folders and files
        let fm = FileManager.default
        var folders: [String] = []
        var files: [String] = []
        for item in items {
            let path = folderURL.appendingPathComponent(item).path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                if isDir.boolValue { folders.append(item) } else { files.append(item) }
            }
        }

        var parts: [String] = []
        parts.append("Your \(locationLabel) folder has \(folders.count) folder\(folders.count == 1 ? "" : "s") and \(files.count) file\(files.count == 1 ? "" : "s").")
        if !folders.isEmpty {
            parts.append("\nFolders: " + folders.prefix(15).joined(separator: ", ")
                + (folders.count > 15 ? " (+\(folders.count - 15) more)" : ""))
        }
        if !files.isEmpty {
            parts.append("\nFiles: " + files.prefix(15).joined(separator: ", ")
                + (files.count > 15 ? " (+\(files.count - 15) more)" : ""))
        }

        let reply = parts.joined()
        return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
    }

    // MARK: - Shutdown intent

    static func isShutdownIntent(_ normalized: String) -> Bool {
        let phrases = [
            "shut down", "shutdown", "restart", "reboot",
            "turn off my mac", "turn off my computer", "turn off the computer",
            "power off", "power down",
        ]
        return phrases.contains { normalized.contains($0) }
    }
}
