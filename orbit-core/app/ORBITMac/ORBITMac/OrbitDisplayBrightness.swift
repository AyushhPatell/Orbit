//
//  OrbitDisplayBrightness.swift
//  ORBITMac
//
//  Brightness control that actually works on Apple Silicon.
//
//  The Homebrew `brightness` CLI fails on M-series Macs (kIOReturnUnsupported, -536870201)
//  but still exits with status 0 — so ORBIT reported "Brightness at 30%" while the screen
//  stayed at 100%. DisplayServices is the private framework macOS itself drives brightness
//  with; it works on Apple Silicon. Every write here is verified by reading the value back,
//  so a failure can never be reported as success.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Speech

enum OrbitDisplayBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )

    private static var getFn: GetFn? {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetFn.self)
    }

    private static var setFn: SetFn? {
        guard let h = handle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetFn.self)
    }

    static var isAvailable: Bool { getFn != nil && setFn != nil }

    /// Current brightness of the main display as 0.0–1.0, or nil when unreadable.
    static func current() -> Float? {
        guard let get = getFn else { return nil }
        var value: Float = 0
        guard get(CGMainDisplayID(), &value) == 0 else { return nil }
        return value
    }

    /// Sets brightness, returning the confirmed level, or nil when it cannot be confirmed.
    ///
    /// Read-back is **mandatory**. Inside the app sandbox this framework accepts the call and
    /// returns 0 while changing nothing, and `current()` yields nil — so its status code alone
    /// proved worthless as evidence ("Brightness set to 100%" with an unchanged screen).
    /// A nil result here means "unconfirmed", and the caller must fall back to the F1/F2 keys.
    ///
    /// (IOKit's `AppleARMBacklight` value was also tried and rejected: it reads 0.5 while this
    /// reads 1.0 and never moves when brightness changes.)
    static func set(_ fraction: Float) -> Float? {
        guard let setter = setFn, let before = current() else { return nil }
        let target = max(0, min(1, fraction))

        guard setter(CGMainDisplayID(), target) == 0 else { return nil }
        usleep(200_000)

        guard let after = current() else { return nil }
        if abs(after - target) <= 0.08 { return after }
        return abs(after - before) > 0.01 ? after : nil
    }

    // MARK: - Hardware brightness keys

    /// Number of presses that spans the full range (each press is 1/16, measured on-device).
    static let keySteps = 16

    /// True when macOS will let this process post HID events.
    static var canPostKeys: Bool { AXIsProcessTrusted() }

    /// Posts the display's brightness key as a system-defined HID event.
    ///
    /// This is the mechanism that works inside the app sandbox. It deliberately avoids
    /// AppleScript/System Events, which would additionally require Automation permission —
    /// that missing second grant is what made brightness fail while Accessibility was enabled.
    /// Verified on-device: two presses moved brightness 0.562 → 0.438.
    static func pressKey(up: Bool) {
        let keyCode: Int32 = up ? 2 : 3  // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        func send(down: Bool) {
            let raw = down ? 0xa00 : 0xb00
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(raw)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((keyCode << 16) | Int32(raw)),
                data2: -1
            ) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        send(down: true)
        send(down: false)
    }

    /// Presses a brightness key `count` times, pacing them so macOS registers each one.
    static func pressKey(up: Bool, times count: Int) {
        for _ in 0 ..< max(1, count) {
            pressKey(up: up)
            usleep(25_000)
        }
    }

    // MARK: - Self diagnostics

    /// True when running inside the App Sandbox, which forbids Accessibility clients outright —
    /// `AXIsProcessTrusted()` stays false no matter what the Privacy list shows.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Human-readable report of every gate ORBIT's system control depends on, so a failure can
    /// be diagnosed from one typed command instead of a round of guesswork.
    @MainActor
    static func diagnosticsReport() async -> String {
        var lines = ["ORBIT diagnostics:"]
        lines.append("• Sandboxed: \(isSandboxed ? "YES — blocks mic, Accessibility, DisplayServices" : "no")")
        lines.append("• Microphone: \(micStatusText)")
        lines.append("• Speech recognition: \(speechStatusText)")
        lines.append("• Audio input: \(audioInputText)")
        lines.append("• Speech engine: \(await speechEngineText)")
        lines.append("• Speech recognizer: \(recognizerText)")
        let wake = OrbitWakeWordController.shared
        lines.append("• Wake enabled: \(wake.isEnabledInDefaults ? "yes" : "NO — turn on Listen for Hey ORBIT")")
        lines.append("• Wake suspended: \(wake.isSuspendedForUserSpeech ? "YES — mic handed to a voice turn" : "no")")
        lines.append("• Wake listening: \(wake.isListening ? "yes" : "NO")")
        lines.append("• Wake error: \(wake.lastError ?? "none")")
        // Detailed wake counters live in the Wake Diagnostics panel in the menu bar, not here.
        lines.append("• Accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "NO — cannot send display keys")")
        lines.append("• DisplayServices loaded: \(handle != nil ? "yes" : "NO")")
        lines.append("• Brightness readable: \(current().map { "yes (\(Int(($0 * 100).rounded()))%)" } ?? "NO")")

        if let start = current() {
            let probe = start > 0.15 ? start - 0.06 : start + 0.06
            let landed = set(probe)
            lines.append("• DisplayServices write: \(landed != nil ? "works" : "refused")")
            _ = set(start)
        } else {
            lines.append("• DisplayServices write: untestable (no read-back)")
        }
        return lines.joined(separator: "\n")
    }

    /// The format ORBIT's audio engine actually gets. A 0 Hz / 0-channel format is why the mic
    /// silently refuses to open and the engine throws -10877.
    private static var audioInputText: String {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        let rate = Int(format.sampleRate)
        let channels = format.channelCount
        guard rate > 0, channels > 0 else {
            return "INVALID (\(rate) Hz, \(channels) ch) — engine cannot open the mic"
        }
        return "\(rate) Hz, \(channels) ch"
    }

    /// Which recogniser is actually in use, and with which accent model — the difference between
    /// an en_IN and an en_CA model is the whole mishearing problem.
    private static var speechEngineText: String {
        get async {
            guard #available(macOS 26.0, *) else { return "SFSpeechRecognizer (macOS 25 or older)" }
            guard OrbitSpeechInputController.modernEngineEnabled else {
                return "SFSpeechRecognizer (modern engine turned off)"
            }
            guard let locale = await OrbitSpeechTranscriber.bestInstalledLocale() else {
                return "SFSpeechRecognizer (no SpeechAnalyzer model installed)"
            }
            return "SpeechAnalyzer, \(locale.identifier)"
        }
    }

    private static var recognizerText: String {
        guard let r = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US")) else {
            return "UNAVAILABLE — could not create a recognizer for this locale"
        }
        return r.isAvailable
            ? "available (\(r.locale.identifier), on-device \(r.supportsOnDeviceRecognition ? "yes" : "no"))"
            : "NOT AVAILABLE right now (\(r.locale.identifier))"
    }

    private static var micStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .notDetermined: return "NOT ASKED YET — press the mic button to trigger the prompt"
        case .denied: return "DENIED — enable ORBITMac in Privacy & Security → Microphone"
        case .restricted: return "restricted by policy"
        @unknown default: return "unknown"
        }
    }

    private static var speechStatusText: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "granted"
        case .notDetermined: return "NOT ASKED YET"
        case .denied: return "DENIED — enable ORBITMac in Privacy & Security → Speech Recognition"
        case .restricted: return "restricted by policy"
        @unknown default: return "unknown"
        }
    }
}
