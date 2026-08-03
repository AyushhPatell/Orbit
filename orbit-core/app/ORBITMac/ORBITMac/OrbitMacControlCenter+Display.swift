//
//  OrbitMacControlCenter+Display.swift
//  ORBITMac
//
//  Screen brightness and Night Shift via external CLI tools.
//  brightness: brew install brightness
//  nightlight: brew install smudge/smudge/nightlight
//

import Foundation

extension OrbitMacControlCenter {

    // MARK: - Tool path resolution

    static func brightnessPath() -> String? {
        // Check next to app binary first (bundled), then Homebrew ARM/Intel paths
        let appDir = Bundle.main.bundlePath + "/Contents/MacOS/brightness"
        if FileManager.default.fileExists(atPath: appDir) { return appDir }
        let candidates = ["/opt/homebrew/bin/brightness", "/usr/local/bin/brightness"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func nightlightPath() -> String? {
        let appDir = Bundle.main.bundlePath + "/Contents/MacOS/nightlight"
        if FileManager.default.fileExists(atPath: appDir) { return appDir }
        let candidates = ["/opt/homebrew/bin/nightlight", "/usr/local/bin/nightlight"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Intent detection — brightness

    static func isBrightnessUpIntent(_ normalized: String) -> Bool {
        let triggers = [
            "brightness up", "brighter", "increase brightness", "turn up brightness",
            "make it brighter", "make screen brighter", "more brightness",
            "raise brightness", "bump up brightness",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    static func isBrightnessDownIntent(_ normalized: String) -> Bool {
        let triggers = [
            "brightness down", "dimmer", "decrease brightness", "turn down brightness",
            "make it dimmer", "make screen dimmer", "lower brightness",
            "reduce brightness", "dim the screen", "dim screen",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    static func extractBrightnessLevel(from normalized: String) -> Int? {
        let resolved = resolveSpokenNumbers(in: normalized)
        // "set brightness to 70%", "brightness 50", "brightness to 80 percent"
        let patterns = [
            #"brightness\s+(?:to\s+)?(\d{1,3})\s*(?:%|percent)?"#,
            #"set\s+brightness\s+(?:to\s+)?(\d{1,3})\s*(?:%|percent)?"#,
            #"screen\s+brightness\s+(?:to\s+)?(\d{1,3})\s*(?:%|percent)?"#,
        ]
        for pattern in patterns {
            if let capture = firstCapture(in: resolved, pattern: pattern), let n = Int(capture) {
                return max(0, min(100, n))
            }
        }
        return nil
    }

    // MARK: - Intent detection — Night Shift

    static func isNightShiftOnIntent(_ normalized: String) -> Bool {
        let triggers = [
            "night shift on", "turn on night shift", "enable night shift",
            "turn night shift on", "activate night shift", "switch on night shift",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    static func isNightShiftOffIntent(_ normalized: String) -> Bool {
        let triggers = [
            "night shift off", "turn off night shift", "disable night shift",
            "turn night shift off", "deactivate night shift", "switch off night shift",
        ]
        return triggers.contains(where: { normalized.contains($0) })
    }

    // MARK: - Execution — brightness

    /// Reads brightness via DisplayServices, falling back to the CLI on Intel Macs.
    static func currentBrightnessLevel() -> Float? {
        if let live = OrbitDisplayBrightness.current() { return live }
        guard let path = brightnessPath(),
              let result = try? runCommand(path, ["-l"], failOnNonZero: false)
        else { return nil }
        // Output example: "display 0: brightness 0.750000"
        if let match = result.stdout.range(of: #"brightness (\d+\.?\d*)"#, options: .regularExpression) {
            let numStr = result.stdout[match].replacingOccurrences(of: "brightness ", with: "")
            return Float(numStr)
        }
        return nil
    }

    /// Raises the system Accessibility prompt, which also registers the *current* binary.
    /// Ad-hoc signed builds get a new code hash on every rebuild, so an existing entry in
    /// System Settings can look enabled while pointing at an older binary.
    private static func brightnessFailure() -> ControlError {
        _ = OrbitUIAssist.ensureTrusted(prompt: true)
        return ControlError.actionFailed(
            "macOS isn\u{2019}t letting me send display keys, so I can\u{2019}t change the brightness. "
            + "I\u{2019}ve asked for Accessibility access \u{2014} approve that dialog. If ORBITMac is already "
            + "listed under Privacy & Security \u{2192} Accessibility, select it, remove it with the minus "
            + "button, then approve again."
        )
    }

    static func setBrightnessLevel(_ percent: Int) throws -> String {
        let clamped = max(0, min(100, percent))

        // Preferred when the framework is genuinely usable (Intel, or unsandboxed builds):
        // it verifies by read-back and reports an exact level.
        if let verified = OrbitDisplayBrightness.set(Float(clamped) / 100.0) {
            return "Brightness set to \(Int((verified * 100).rounded()))%."
        }

        // Sandbox path: brightness is unreadable here, so drive to a known floor and step up.
        // A full run of "down" presses lands at minimum regardless of the starting point.
        guard OrbitDisplayBrightness.canPostKeys else { throw brightnessFailure() }
        let steps = OrbitDisplayBrightness.keySteps
        let upPresses = Int((Double(clamped) / 100.0 * Double(steps)).rounded())
        OrbitDisplayBrightness.pressKey(up: false, times: steps)
        if upPresses > 0 {
            OrbitDisplayBrightness.pressKey(up: true, times: upPresses)
        }
        let landed = Int((Double(upPresses) / Double(steps) * 100).rounded())
        return "Brightness set to about \(landed)%."
    }

    /// Adjusts brightness by `step` percentage points (default 20).
    static func adjustBrightness(up: Bool, step: Int = 20) throws -> String {
        let clampedStep = max(1, min(100, step))

        // Relative math needs a reading in the framework's own scale; mixing scales set the
        // wrong level. When that reading exists, it reports an exact result.
        if let current = OrbitDisplayBrightness.current() {
            let delta = Float(clampedStep) / 100.0
            let next = up ? min(1.0, current + delta) : max(0.0, current - delta)
            if let verified = OrbitDisplayBrightness.set(next) {
                let pct = Int((verified * 100).rounded())
                return up ? "Brightness up \u{2014} now \(pct)%." : "Brightness down \u{2014} now \(pct)%."
            }
        }

        // Sandbox path: the keys are inherently relative, so no reading is needed.
        guard OrbitDisplayBrightness.canPostKeys else { throw brightnessFailure() }
        let presses = max(1, Int((Double(clampedStep) / 100.0 * Double(OrbitDisplayBrightness.keySteps)).rounded()))
        OrbitDisplayBrightness.pressKey(up: up, times: presses)
        return up ? "Brightness up." : "Brightness down."
    }

    // MARK: - Execution — Night Shift

    static func setNightShift(enabled: Bool) throws -> String {
        if let path = nightlightPath() {
            _ = try runCommand(path, [enabled ? "on" : "off"], failOnNonZero: false)
            return "Night Shift \(enabled ? "on" : "off")."
        }
        // Fallback: AppleScript to open the Night Shift settings pane
        // (Can't toggle Night Shift without nightlight or private framework)
        throw ControlError.actionFailed(
            "The `nightlight` tool isn\u{2019}t installed. Run `brew install smudge/smudge/nightlight` to enable Night Shift control."
        )
    }
}
