//
//  OrbitIntentClassifier.swift
//  ORBITMac
//
//  Semantic fallback intent classifier. When exact phrase matching in performIfCommand
//  returns handled:false, this classifier checks for CONCEPTUAL keywords to catch
//  commands that were phrased differently than the trigger lists expect.
//
//  Example: "Could you check what the weather is like?" → phrase matching fails
//  (too many words), but classifier sees "weather" → routes to weather handler.
//

import Foundation

enum OrbitClassifiedIntent {
    case weather
    case noteCreate(body: String?)
    case noteAppend(content: String?)
    case reminder
    case calendar
    case terminal(command: String?)
    case document
    case smartHome
    case email
    case openApp(name: String)
    case closeApp(name: String)
    case musicPlay
    case musicPause
    case musicNext
    case volumeUp
    case volumeDown
    case mute
    case unmute
    case darkModeOn
    case darkModeOff
    case focusOn
    case focusOff
    case batteryStatus
    case lockScreen
    case brightness
}

enum OrbitIntentClassifier {

    static func classify(_ normalized: String) -> OrbitClassifiedIntent? {
        let words = Set(normalized.split(separator: " ").map(String.init))
        let text = normalized

        // Weather — strong signal: "weather" keyword almost never means anything else
        if words.contains("weather") || words.contains("temperature") || words.contains("forecast")
            || text.contains("how hot") || text.contains("how cold") || text.contains("is it raining")
            || text.contains("whats it like outside") || text.contains("what's it like outside") {
            return .weather
        }

        // Email — "email", "inbox", "mail" in a query context
        if (words.contains("email") || words.contains("emails") || words.contains("inbox")
            || words.contains("mail") || words.contains("mails"))
            && (text.contains("check") || text.contains("read") || text.contains("show")
                || text.contains("any") || text.contains("new") || text.contains("unread")
                || text.contains("do i have") || text.contains("what")) {
            return .email
        }

        // Note — "note" + action context, but NOT "remind"
        if !text.contains("remind") && !text.contains("reminder") {
            if (words.contains("note") || words.contains("notes"))
                && (text.contains("take") || text.contains("make") || text.contains("create")
                    || text.contains("write") || text.contains("jot") || text.contains("add to")) {
                return .noteCreate(body: nil)
            }
        }

        // Reminder — "remind" keyword is very strong signal
        if words.contains("remind") || words.contains("reminder") || words.contains("reminders") {
            return .reminder
        }

        // Calendar/meeting — scheduling keywords
        if (words.contains("meeting") || words.contains("event") || words.contains("appointment")
            || words.contains("schedule") || words.contains("calendar"))
            && (text.contains("schedule") || text.contains("book") || text.contains("create")
                || text.contains("add") || text.contains("set up") || text.contains("i have")
                || text.contains("meeting with") || text.contains("meeting at")) {
            return .calendar
        }

        // Terminal — "run"/"execute" + something that looks like a command
        if (text.hasPrefix("run ") || text.hasPrefix("execute ")) && text.count > 6 {
            let cmd = text.hasPrefix("run ") ? String(text.dropFirst(4)) : String(text.dropFirst(8))
            return .terminal(command: cmd.trimmingCharacters(in: .whitespaces))
        }

        // Document — "summarize"/"read"/"explain" + "document"/"pdf"/"file"
        if (words.contains("pdf") || words.contains("document") || words.contains("file"))
            && (text.contains("summarize") || text.contains("summarise") || text.contains("read")
                || text.contains("explain") || text.contains("what's in") || text.contains("what is in")) {
            return .document
        }

        // Smart home — "turn on/off" + device/room words
        if text.contains("turn on") || text.contains("turn off") || text.contains("switch on") || text.contains("switch off") {
            let homeWords = ["light", "lights", "bulb", "bulbs", "lamp", "fan",
                             "bedroom", "hall", "kitchen", "living room", "bathroom"]
            if homeWords.contains(where: { text.contains($0) }) {
                return .smartHome
            }
        }

        // Music — play/pause/next/previous + music context
        if text.contains("play music") || text.contains("play song") || text.contains("play my")
            || text.contains("start music") || text.contains("resume music") {
            return .musicPlay
        }
        if text.contains("pause music") || text.contains("stop music") || text.contains("pause the music")
            || text.contains("stop the music") || text.contains("pause song") {
            return .musicPause
        }
        if text.contains("next song") || text.contains("next track") || text.contains("skip song")
            || text.contains("skip track") || text.contains("skip this") {
            return .musicNext
        }

        // Volume
        if text.contains("volume up") || text.contains("louder") || text.contains("increase volume")
            || text.contains("turn up the volume") || text.contains("raise the volume") {
            return .volumeUp
        }
        if text.contains("volume down") || text.contains("quieter") || text.contains("decrease volume")
            || text.contains("lower the volume") || text.contains("turn down the volume") {
            return .volumeDown
        }
        if text.contains("mute") && !text.contains("unmute") { return .mute }
        if text.contains("unmute") { return .unmute }

        // Dark mode
        if (text.contains("dark mode") || text.contains("dark theme"))
            && (text.contains("turn on") || text.contains("enable") || text.contains("switch to") || text.contains("activate")) {
            return .darkModeOn
        }
        if (text.contains("dark mode") || text.contains("dark theme"))
            && (text.contains("turn off") || text.contains("disable") || text.contains("switch off")) {
            return .darkModeOff
        }
        if (text.contains("light mode") || text.contains("light theme"))
            && (text.contains("turn on") || text.contains("enable") || text.contains("switch to")) {
            return .darkModeOff
        }

        // Focus/DND
        if (text.contains("focus") || text.contains("do not disturb") || text.contains("dnd")) {
            if text.contains("turn on") || text.contains("enable") || text.contains("activate") { return .focusOn }
            if text.contains("turn off") || text.contains("disable") || text.contains("deactivate") { return .focusOff }
        }

        // Battery
        if words.contains("battery") || text.contains("battery level") || text.contains("charge level")
            || text.contains("how much charge") || text.contains("how much battery") {
            return .batteryStatus
        }

        // Lock screen
        if text.contains("lock screen") || text.contains("lock my screen") || text.contains("lock the screen")
            || text.contains("lock my mac") || text.contains("lock my computer") {
            return .lockScreen
        }

        // Brightness
        if words.contains("brightness") || text.contains("screen brightness") || text.contains("brighter")
            || text.contains("dimmer") || text.contains("dim the screen") {
            return .brightness
        }

        // Open app — very broad, check last: "open X", "launch X", "start X"
        if let appName = extractAppNameFromLoose(text) {
            if text.contains("close") || text.contains("quit") || text.contains("exit") || text.contains("kill") {
                return .closeApp(name: appName)
            }
            return .openApp(name: appName)
        }

        return nil
    }

    private static func extractAppNameFromLoose(_ text: String) -> String? {
        let openers = ["open ", "launch ", "start ", "close ", "quit ", "exit ", "kill "]
        for opener in openers {
            if text.contains(opener) {
                if let range = text.range(of: opener) {
                    let after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    // Strip trailing filler
                    let cleaned = after
                        .replacingOccurrences(of: #"\s+(please|for me|app|application)$"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty, cleaned.count <= 30 { return cleaned }
                }
            }
        }
        return nil
    }
}
