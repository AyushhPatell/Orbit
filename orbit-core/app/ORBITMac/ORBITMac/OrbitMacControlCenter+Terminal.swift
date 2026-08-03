//
//  OrbitMacControlCenter+Terminal.swift
//  ORBITMac
//
//  Voice-triggered shell command execution with smart working-directory detection.
//  Detects the frontmost Terminal window's folder and runs commands THERE.
//

import AppKit
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Intent detection

    static func extractTerminalCommand(from normalized: String) -> String? {
        // Explicit prefix: "run git status", "execute npm install"
        // When the user explicitly says "run X", trust that X is a command — don't require
        // it to match a known tool (STT might transcribe "git" as "gate", "get", etc.).
        let explicitPrefixes = [
            "run the command ", "run command ",
            "execute the command ", "execute command ",
            "can you run ", "could you run ", "would you run ", "please run ",
            "can you execute ", "could you execute ", "please execute ",
            "i want to run ", "i need to run ", "i want you to run ",
        ]
        for prefix in explicitPrefixes {
            if normalized.hasPrefix(prefix) {
                let cmd = cleanCommand(String(normalized.dropFirst(prefix.count)))
                if !cmd.isEmpty, cmd.split(separator: " ").count <= 12 { return correctCommonMishearings(cmd) }
            }
        }
        // "run X" / "execute X" — correct STT mishearings first, then check plausibility
        for prefix in ["run ", "execute "] {
            if normalized.hasPrefix(prefix) {
                let raw = cleanCommand(String(normalized.dropFirst(prefix.count)))
                let cmd = correctCommonMishearings(raw)
                if isPlausibleCommand(cmd) { return cmd }
                // Even if the tool isn't recognized, if it's short (1-4 words) and
                // the user explicitly said "run", treat it as a command attempt.
                if !cmd.isEmpty, cmd.split(separator: " ").count <= 6 { return cmd }
            }
        }
        // Suffix-based: "git status in terminal"
        let suffixes = [" in terminal", " in the terminal", " on terminal", " on the terminal"]
        for suffix in suffixes where normalized.hasSuffix(suffix) {
            var cmd = String(normalized.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if cmd.hasPrefix("run ") { cmd = String(cmd.dropFirst(4)) }
            else if cmd.hasPrefix("execute ") { cmd = String(cmd.dropFirst(8)) }
            let cleaned = cleanCommand(cmd)
            if !cleaned.isEmpty { return correctCommonMishearings(cleaned) }
        }
        return nil
    }

    static func correctCommonMishearings(_ command: String) -> String {
        var cmd = command
        // Strip trailing "command" — user says "run git status command"
        let trailingStrip = [" command", " please", " for me"]
        for t in trailingStrip where cmd.lowercased().hasSuffix(t) {
            cmd = String(cmd.dropLast(t.count))
            break
        }
        // STT frequently mishears developer tool names (Indian accent)
        let corrections: [(wrong: String, right: String)] = [
            // git variants
            ("gate ", "git "), ("gait ", "git "), ("geet ", "git "), ("geett ", "git "),
            ("get status", "git status"), ("get pull", "git pull"), ("get push", "git push"),
            ("get log", "git log"), ("get commit", "git commit"), ("get clone", "git clone"),
            ("get add", "git add"), ("get branch", "git branch"), ("get diff", "git diff"),
            ("get checkout", "git checkout"), ("get merge", "git merge"), ("get fetch", "git fetch"),
            ("kit ", "git "), ("grit ", "git "),
            // npm variants
            ("in pm ", "npm "), ("and pm ", "npm "), ("mpm ", "npm "),
            // node variants
            ("no js", "node"), ("notes ", "node "),
            // brew
            ("brew install", "brew install"),
            // python
            ("fighton ", "python "), ("bython ", "python "),
            // pip
            ("peep ", "pip "), ("pip three ", "pip3 "),
        ]
        let lower = cmd.lowercased()
        for (wrong, right) in corrections {
            if lower.hasPrefix(wrong) {
                cmd = right + String(cmd.dropFirst(wrong.count))
                break
            }
        }
        return cmd.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Smart working directory detection

    struct TerminalContext {
        let path: String
        let folderName: String
        let windowTitle: String?
    }

    static func detectFrontmostTerminalDirectory() -> TerminalContext? {
        // Get Terminal's front window title via osascript (command-line).
        // NSAppleScript may be blocked by sandbox, but osascript via Process works
        // because the entitlement grants apple-events to com.apple.Terminal.
        let result = try? runCommand("/usr/bin/osascript",
            ["-e", "tell application \"Terminal\" to name of front window"],
            failOnNonZero: false)
        guard let title = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        // Parse: "Screen-Saver — -zsh — 122×30" → folder = "Screen-Saver"
        let parts = title.components(separatedBy: " \u{2014} ")
        guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != "~" else { return nil }
        guard let path = resolveTerminalFolder(name) else {
            return nil
        }
        return TerminalContext(path: path, folderName: name, windowTitle: title)
    }

    private static func resolveTerminalFolder(_ name: String) -> String? {
        let home = realUserHomeForFiles()
        // Direct home subfolder
        let homeSub = home.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: homeSub.path) { return homeSub.path }
        // Search Desktop, Documents, Downloads and their immediate subfolders
        let locations = ["Documents", "Desktop", "Downloads"]
        for loc in locations {
            let direct = home.appendingPathComponent(loc).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: direct.path) { return direct.path }
        }
        // Search one level deeper (Documents/PJ/Screen-Saver)
        for loc in locations {
            let locPath = home.appendingPathComponent(loc)
            guard let subs = try? FileManager.default.contentsOfDirectory(atPath: locPath.path) else { continue }
            for sub in subs {
                let deep = locPath.appendingPathComponent(sub).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: deep.path) { return deep.path }
            }
        }
        return nil
    }

    // MARK: - Proposal (with directory context)

    static func proposeTerminalCommand(_ command: String) -> String {
        // Check if Terminal is RUNNING (not necessarily frontmost — ORBIT's panel may be in front)
        let context = isTerminalRunning() ? detectFrontmostTerminalDirectory() : nil
        if let ctx = context {
            let display = ctx.path.replacingOccurrences(of: realUserHomeForFiles().path, with: "~")
            OrbitLocalActionPendingStore.shared.setTerminalCommandPending(command, directory: ctx.path)
            return "You\u{2019}re in \(ctx.folderName) (`\(display)`). I\u{2019}ll run `\(command)` there. Say yes to run, or cancel."
        }
        OrbitLocalActionPendingStore.shared.setTerminalCommandPending(command, directory: nil)
        return "I\u{2019}ll run `\(command)` from your home folder. Say yes to run, or cancel."
    }

    private static func isTerminalRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Terminal"
                || $0.bundleIdentifier == "com.googlecode.iterm2"
        }
    }

    // MARK: - Execution

    static func executeTerminalCommand(_ command: String, directory: String?) -> String {
        let workDir: URL
        if let dir = directory {
            workDir = URL(fileURLWithPath: dir)
        } else {
            workDir = realUserHomeForFiles()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell so PATH includes brew, npm, etc.
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = workDir

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Failed to run command: \(error.localizedDescription)"
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exitCode = process.terminationStatus
        let dirLabel = (directory ?? "~").replacingOccurrences(of: realUserHomeForFiles().path, with: "~")

        if exitCode == 0 {
            if outStr.isEmpty {
                return "Command completed in \(dirLabel) (no output)."
            }
            let truncated = outStr.count > 2000 ? String(outStr.prefix(2000)) + "\n\n[Truncated]" : outStr
            return "\(truncated)"
        } else {
            let detail = errStr.isEmpty ? outStr : errStr
            let truncated = detail.count > 1000 ? String(detail.prefix(1000)) + "\n[Truncated]" : detail
            if truncated.isEmpty {
                return "Command exited with code \(exitCode) in \(dirLabel)."
            }
            return "Exit code \(exitCode):\n\(truncated)"
        }
    }

    // MARK: - Blocklist

    private static let blockedPatterns: [String] = [
        "rm -rf /", "rm -rf ~", "rm -rf /*",
        "sudo rm -rf", "mkfs", "dd if=",
        ":(){:|:&};:", "fork bomb",
        "> /dev/sda", "chmod -R 777 /",
        "sudo shutdown", "sudo reboot", "sudo halt",
    ]

    static func isBlockedCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return blockedPatterns.contains { lower.contains($0) }
    }

    // MARK: - Helpers

    private static func isPlausibleCommand(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let knownTools = [
            "npm", "npx", "node", "python", "python3", "pip", "pip3",
            "git", "brew", "swift", "swiftc", "xcodebuild", "xed",
            "ls", "cd", "pwd", "cat", "echo", "grep", "find", "mkdir", "touch",
            "cp", "mv", "rm", "chmod", "chown", "curl", "wget",
            "docker", "kubectl", "terraform", "aws", "gcloud", "az",
            "ruby", "gem", "bundler", "rails", "cargo", "rustc", "go",
            "java", "javac", "mvn", "gradle", "make", "cmake",
            "code", "vim", "nano", "which", "whoami", "hostname",
            "top", "htop", "ps", "kill", "df", "du", "tar", "zip", "unzip",
            "ssh", "scp", "rsync", "ping", "traceroute", "nslookup", "dig",
            "open", "say", "pbcopy", "pbpaste", "defaults", "networksetup",
            "softwareupdate", "diskutil", "system_profiler",
            "flutter", "dart", "pod", "cocoapods", "fastlane",
            "yarn", "pnpm", "bun", "deno",
        ]
        let firstWord = text.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        if knownTools.contains(firstWord) { return true }
        if text.contains("|") || text.contains("&&") || text.contains(">>") { return true }
        if text.hasPrefix("./") || text.hasPrefix("~/") || text.hasPrefix("/") { return true }
        return false
    }

    private static func cleanCommand(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(the command |command )"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
