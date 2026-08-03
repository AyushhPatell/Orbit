//
//  OrbitMacControlCenter+Music.swift
//  ORBITMac
//
//  Music control via AppleScript — supports Apple Music and Spotify.
//

import AppKit
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Running music app detection

    static func activeMusicAppName() -> String? {
        let running = NSWorkspace.shared.runningApplications
        if running.contains(where: { $0.localizedName == "Music" }) { return "Music" }
        if running.contains(where: { $0.localizedName == "Spotify" }) { return "Spotify" }
        return nil
    }

    // MARK: - Intent detection

    static func isMusicPlayIntent(_ normalized: String) -> Bool {
        let triggers = [
            "play music", "play some music", "play a song", "play something",
            "resume music", "resume playing", "resume song", "start music", "start playing",
            "put on some music", "put on music", "turn on music",
        ]
        if triggers.contains(where: { normalized.contains($0) }) { return true }
        // "play spotify", "play apple music" — launch and play
        if normalized.hasPrefix("play ") && (normalized.contains("spotify") || normalized.contains("apple music")) {
            return true
        }
        return false
    }

    static func isMusicPauseIntent(_ normalized: String) -> Bool {
        let triggers = [
            "pause music", "pause the music", "pause the song", "pause this song",
            "stop the music", "stop the song", "stop music",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    static func isMusicNextIntent(_ normalized: String) -> Bool {
        let triggers = [
            "next song", "next track", "skip song", "skip this song",
            "skip track", "skip this track", "next one", "play next",
            "forward song", "go to next",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    static func isMusicPreviousIntent(_ normalized: String) -> Bool {
        let triggers = [
            "previous song", "previous track", "last song", "last track",
            "go back song", "play previous", "play that again", "replay this",
            "replay song", "replay track",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    static func isMusicNowPlayingIntent(_ normalized: String) -> Bool {
        let triggers = [
            "what's playing", "whats playing", "what is playing",
            "what song is this", "what song is playing", "what's this song",
            "whats this song", "current song", "current track", "now playing",
            "what track is this", "who is this", "who is this artist",
            "what music is this", "name of this song",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    // MARK: - Execution

    static func musicPlay() throws -> String {
        if let app = activeMusicAppName() {
            try runAppleScript("tell application \"\(app)\" to play")
            return "Playing."
        }
        // No music app running — open and play Apple Music
        guard let musicURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else {
            throw ControlError.actionFailed("Apple Music isn\u{2019}t installed on this Mac.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: musicURL, configuration: config) { _, _ in }
        return "Opening Apple Music."
    }

    static func musicPause() throws -> String {
        guard let app = activeMusicAppName() else {
            return "No music is playing."
        }
        try runAppleScript("tell application \"\(app)\" to pause")
        return "Paused."
    }

    static func musicNext() throws -> String {
        guard let app = activeMusicAppName() else {
            return "No music app is running."
        }
        try runAppleScript("tell application \"\(app)\" to next track")
        return "Skipping to next track."
    }

    static func musicPrevious() throws -> String {
        guard let app = activeMusicAppName() else {
            return "No music app is running."
        }
        try runAppleScript("tell application \"\(app)\" to previous track")
        return "Going back to previous track."
    }

    static func musicNowPlaying() throws -> String {
        guard let app = activeMusicAppName() else {
            return "No music app is running."
        }
        let script = """
        tell application "\(app)"
            if player state is playing or player state is paused then
                set t to name of current track
                set a to artist of current track
                return t & " by " & a
            else
                return ""
            end if
        end tell
        """
        let result = (try? runAppleScriptReturningString(script)) ?? ""
        if result.isEmpty {
            return "Nothing is playing right now."
        }
        return "Now playing: \(result)."
    }
}
