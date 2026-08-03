//
//  OrbitMacControlCenter+Network.swift
//  ORBITMac
//
//  Wi-Fi and Bluetooth intent detection + execution helpers.
//

import CoreWLAN
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Wi-Fi intent detection

    static func isWifiOnIntent(_ normalized: String) -> Bool {
        if normalized == "wifi on" || normalized == "wi fi on" { return true }
        let hasWifi = normalized.contains("wifi") || normalized.contains("wi fi")
        if hasWifi, (normalized.contains("turn on") || normalized.contains("enable") || normalized.contains("switch on")) {
            return true
        }
        let snippets = [
            "turn wifi on", "turn wi fi on", "turn the wifi on", "turn the wi fi on",
            "switch wifi on", "switch wi fi on", "enable wifi", "enable wi fi",
            "connect wifi", "connect wi fi", "start wifi", "start wi fi", "put wifi on",
            "turn my wifi on", "turn on my wifi", "turn on the wifi", "turn on the wi fi",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isWifiOffIntent(_ normalized: String) -> Bool {
        if normalized == "wifi off" || normalized == "wi fi off" { return true }
        let hasWifi = normalized.contains("wifi") || normalized.contains("wi fi")
        if hasWifi, (normalized.contains("turn off") || normalized.contains("disable") || normalized.contains("switch off")) {
            return true
        }
        let snippets = [
            "turn wifi off", "turn wi fi off", "turn the wifi off", "turn the wi fi off",
            "switch wifi off", "switch wi fi off", "disable wifi", "disable wi fi",
            "disconnect wifi", "disconnect wi fi", "stop wifi", "stop wi fi", "put wifi off",
            "turn my wifi off", "turn off my wifi", "turn off the wifi", "turn off the wi fi",
            "please turn off wifi", "please turn off the wifi", "wifi off now",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isWifiStatusIntent(_ normalized: String) -> Bool {
        let hasWifi = normalized.contains("wifi") || normalized.contains("wi fi")
        let snippets = [
            "wifi status", "wi fi status", "is wifi on", "is wi fi on", "is wifi off", "is wi fi off",
            "if wifi is on", "if wi fi is on", "whether wifi is on", "whether wi fi is on",
            "check wifi", "check wi fi", "wifi on or off", "wi fi on or off",
            "what is the status of wifi", "what is the status of wi fi", "status of wifi", "status of wi fi",
            "how is wifi", "wifi working", "is my wifi on", "is my wi fi on",
        ]
        if snippets.contains(where: { normalized.contains($0) }) { return true }
        if hasWifi, normalized.contains("status") { return true }
        if hasWifi, normalized.contains("whether") { return true }
        if hasWifi, normalized.contains("check ") { return true }
        if hasWifi, normalized.contains("what ") && (normalized.contains("wifi") || normalized.contains("wi fi")) { return true }
        return false
    }

    // MARK: - Bluetooth intent detection

    static func isBluetoothToolingCheckIntent(_ normalized: String) -> Bool {
        if normalized.contains("blueutil") { return true }
        let snippets = [
            "check bluetooth tooling", "bluetooth tooling", "bluetooth tool check",
            "check bluetooth tool", "is bluetooth tooling installed", "do i have bluetooth tooling",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isBluetoothOnIntent(_ normalized: String) -> Bool {
        if normalized == "bluetooth on" { return true }
        if normalized.contains("bluetooth"), (normalized.contains("turn on") || normalized.contains("enable") || normalized.contains("switch on")) {
            return true
        }
        let snippets = [
            "turn bluetooth on", "turn on bluetooth", "turn the bluetooth on", "turn on the bluetooth",
            "enable bluetooth", "bluetooth on", "switch bluetooth on", "please turn on bluetooth",
            "turn my bluetooth on", "bluetooth power on",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isBluetoothOffIntent(_ normalized: String) -> Bool {
        if normalized == "bluetooth off" { return true }
        if normalized.contains("bluetooth"), (normalized.contains("turn off") || normalized.contains("disable") || normalized.contains("switch off")) {
            return true
        }
        let snippets = [
            "turn bluetooth off", "turn off bluetooth", "turn the bluetooth off", "turn off the bluetooth",
            "disable bluetooth", "bluetooth off", "switch bluetooth off", "please turn off bluetooth",
            "shut off bluetooth", "bluetooth power off",
        ]
        return snippets.contains(where: { normalized.contains($0) })
    }

    static func isBluetoothStatusIntent(_ normalized: String) -> Bool {
        let snippets = [
            "bluetooth status", "is bluetooth on", "is bluetooth off", "check bluetooth",
            "whether bluetooth is on", "whether bluetooth is off", "if bluetooth is on", "if bluetooth is off",
            "what is the status of bluetooth", "status of bluetooth", "bluetooth on or off",
        ]
        if snippets.contains(where: { normalized.contains($0) }) { return true }
        if normalized.contains("bluetooth"), normalized.contains("status") { return true }
        if normalized.contains("bluetooth"), normalized.contains("whether") { return true }
        if normalized.contains("bluetooth"), normalized.contains("check ") { return true }
        if normalized.contains("bluetooth"), normalized.contains("what ") { return true }
        return false
    }

    // MARK: - Wi-Fi execution helpers

    static func wifiInterfaceObject() throws -> CWInterface {
        if let iface = CWWiFiClient.shared().interface() {
            return iface
        }
        throw ControlError.actionFailed("Couldn't find your Wi-Fi interface.")
    }

    static func wifiPowerStatus() throws -> Bool? {
        guard let iface = CWWiFiClient.shared().interface(),
              let ifName = iface.interfaceName
        else {
            return nil
        }
        let result = try runCommand("/usr/sbin/networksetup", ["-getairportpower", ifName], failOnNonZero: false)
        let out = result.stdout.lowercased()
        if out.contains(": on") { return true }
        if out.contains(": off") { return false }
        return nil
    }

    // MARK: - Bluetooth execution helpers

    static func blueutilPath() -> String? {
        if let exe = Bundle.main.executableURL {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("blueutil").path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "blueutil"),
           FileManager.default.isExecutableFile(atPath: bundled) || FileManager.default.fileExists(atPath: bundled)
        {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/blueutil",
            "/usr/local/bin/blueutil",
        ]
        for path in candidates {
            // Do NOT resolve symlinks to Cellar. Sandbox file exceptions list the Homebrew shim
            // paths; resolving breaks exec with "file doesn't exist" / not permitted.
            if FileManager.default.isExecutableFile(atPath: path) { return path }
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Runs blueutil via Process first, then do shell script (often succeeds when the sandbox blocks direct exec).
    static func invokeBlueutil(arguments: [String]) throws -> String {
        guard let exe = blueutilPath() else {
            throw ControlError.actionFailed(
                "Bluetooth control needs `blueutil`. Install with `brew install blueutil` and rebuild ORBITMac (the Xcode target runs a build phase that copies it next to the app). See orbit-core README."
            )
        }
        var processError: String?
        do {
            let r = try runCommand(exe, arguments, failOnNonZero: false)
            if r.status == 0 {
                return r.stdout
            }
            let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // blueutil aborts (signal 6) when the calling app lacks the Bluetooth TCC grant.
            // That is a permission problem with an exact fix, not a broken tool — say so.
            if detail.lowercased().contains("bluetooth api") || detail.lowercased().contains("abort signal") || r.status == 134 {
                throw ControlError.actionFailed(
                    "macOS is blocking Bluetooth access for ORBIT. Open System Settings \u{2192} Privacy & Security \u{2192} Bluetooth and turn on ORBITMac, then ask me again."
                )
            }
            processError = detail.isEmpty ? "exit \(r.status)" : detail
        } catch let ctrl as ControlError {
            throw ctrl
        } catch {
            processError = (error as NSError).localizedDescription
        }
        do {
            return try runBlueutilViaAppleScript(exe: exe, arguments: arguments)
        } catch {
            let hint = processError.map { " (\($0))" } ?? ""
            let ns = error as NSError
            let fallbackDetail = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            let combined = "\(hint) \(fallbackDetail)".lowercased()
            let bundleHint: String =
                combined.contains("not permitted") || combined.contains("doesn") || combined.contains("nscocoaerrordomain 4")
                ? " Bundle `blueutil` inside ORBITMac.app/Contents/MacOS (see orbit-core README) so ORBIT runs a copy next to the main executable, or install with `brew install blueutil`."
                : ""
            throw ControlError.actionFailed(
                "Could not run blueutil\(hint). AppleScript fallback: \(fallbackDetail).\(bundleHint)"
            )
        }
    }

    static func runBlueutilViaAppleScript(exe: String, arguments: [String]) throws -> String {
        let fullCommand = ([exe] + arguments).joined(separator: " ")
        var escaped = ""
        for ch in fullCommand {
            switch ch {
            case "\\", "\"", "$", "`":
                escaped.append("\\")
                escaped.append(ch)
            default:
                escaped.append(ch)
            }
        }
        let source = "do shell script \"\(escaped)\""
        return try runAppleScriptReturningString(source)
    }

    static func setBluetooth(enabled: Bool) throws {
        let target = enabled ? "1" : "0"
        _ = try invokeBlueutil(arguments: ["--power", target])
    }

    static func bluetoothPowerStatusFromSystemProfiler() -> Bool? {
        guard let result = try? runCommand(
            "/usr/sbin/system_profiler",
            ["SPBluetoothDataType", "-detailLevel", "mini"],
            failOnNonZero: false
        ) else { return nil }
        let lines = result.stdout
            .lowercased()
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            if line.hasPrefix("state:") || line.hasPrefix("bluetooth power:") {
                if line.contains("on") { return true }
                if line.contains("off") { return false }
            }
        }
        return nil
    }

    static func bluetoothStatus() throws -> Bool? {
        if let status = bluetoothPowerStatusFromSystemProfiler() {
            return status
        }
        guard blueutilPath() != nil else { return nil }
        let raw = try invokeBlueutil(arguments: ["--power"])
        let out = raw.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "1" { return true }
        if out == "0" { return false }
        return nil
    }
}
