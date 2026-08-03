//
//  OrbitSpeechInputController.swift
//  ORBITMac
//
//  Push-to-talk speech recognition (Speech + AVAudioEngine).
//  Keeps text + voice side by side: transcript fills the normal composer.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class OrbitSpeechInputController: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String? {
        didSet { if let e = lastError { print("[ORBIT-MIC] Recognition error: \(e)") } }
    }

    private let audioEngine = AVAudioEngine()
    // Computed so each session gets a fresh recognizer — stale instances error immediately
    // when macOS restarts the Speech service (e.g. after entitlement changes or first launch).
    private var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onPartial: ((String) -> Void)?
    private var onCommit: ((String) -> Void)?
    private var latestTranscript = ""
    private var didCommit = false
    private var silenceWorkItem: DispatchWorkItem?
    private var silenceAfterSeconds: TimeInterval = 1.25

    /// macOS 26 SpeechAnalyzer path. Preferred because it has an `en_IN` acoustic model matched to
    /// Ayush's accent, and no 60-second server timeout. Falls back to SFSpeechRecognizer when the
    /// OS is older, no model is installed, or the toggle is off.
    private var modernTranscriber: Any?
    private var usingModernEngine = false

    static var modernEngineEnabled: Bool {
        UserDefaults.standard.object(forKey: "orbitMac.useModernSpeech") as? Bool ?? true
    }

    func startListening(
        onPartial: @escaping (String) -> Void,
        onCommit: @escaping (String) -> Void,
        silenceAfterSeconds: TimeInterval = 1.25
    ) async throws {
        try await requestAuthorization()
        stopListening()
        self.onPartial = onPartial
        self.onCommit = onCommit
        latestTranscript = ""
        didCommit = false
        self.silenceAfterSeconds = max(0.7, min(2.4, silenceAfterSeconds))

        if #available(macOS 26.0, *), Self.modernEngineEnabled,
           await OrbitSpeechTranscriber.isUsable() {
            try await startModernListening()
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            throw SpeechInputError.recognizerUnavailable
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = OrbitSpeechContextProvider.contextualStrings()
        request = req

        let node = audioEngine.inputNode
        ensureVoiceProcessingDisabled(on: node)
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        // A zero sample-rate/channel format means the mic isn't actually available (permission
        // not yet granted, or in a transitional state). Installing a tap with it makes the
        // engine throw -10877 instead of surfacing the real cause.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stopListening()
            throw SpeechInputError.microphoneNotAuthorized
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.handleTranscriptUpdate(text, isFinal: result.isFinal)
                }
                if let error {
                    self.lastError = "SFSpeechRecognitionTask error: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]"
                    self.stopListening(commitIfPossible: true)
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            OrbitListeningPresence.shared.setUserVoiceListening(true)
        } catch {
            stopListening()
            throw SpeechInputError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Starts the macOS 26 engine. Silence-based committing is unchanged — only the recogniser
    /// underneath differs, so every downstream behaviour (partials, endpointing, commit) is the same.
    @available(macOS 26.0, *)
    private func startModernListening() async throws {
        let engine = OrbitSpeechTranscriber()
        modernTranscriber = engine
        usingModernEngine = true

        try await engine.start(
            onVolatile: { [weak self] text in
                Task { @MainActor in self?.handleTranscriptUpdate(text, isFinal: false) }
            },
            onFinalized: { [weak self] text in
                // The engine has no server timeout, so a finalized segment is genuinely settled —
                // append it rather than treating it as end-of-turn the way SFSpeechRecognizer needed.
                Task { @MainActor in self?.handleTranscriptUpdate(text, isFinal: false) }
            }
        )

        let node = audioEngine.inputNode
        // Both engine paths must clear voice processing — the SpeechAnalyzer path returns
        // before the legacy setup below, so a repair placed only there would never run.
        ensureVoiceProcessingDisabled(on: node)
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stopListening()
            throw SpeechInputError.microphoneNotAuthorized
        }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            engine.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            OrbitListeningPresence.shared.setUserVoiceListening(true)
        } catch {
            stopListening()
            throw SpeechInputError.engineStartFailed(error.localizedDescription)
        }
    }

    func stopListening(commitIfPossible: Bool = false) {
        if commitIfPossible, !didCommit {
            let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Filler-only means he was thinking, not talking — nothing worth sending ever
            // arrived, so end the session the same way pure silence does. (The 3 PM
            // briefing case: a committed "Um" became a memory recital.)
            if !text.isEmpty, !OrbitUtteranceCleanup.isFillerOnly(text) {
                didCommit = true
                onCommit?(text)
            }
        }
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        if #available(macOS 26.0, *), let engine = modernTranscriber as? OrbitSpeechTranscriber {
            Task { await engine.stop() }
        }
        modernTranscriber = nil
        usingModernEngine = false
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onPartial = nil
        onCommit = nil
        latestTranscript = ""
        isListening = false
        OrbitListeningPresence.shared.setUserVoiceListening(false)
    }

    private func handleTranscriptUpdate(_ text: String, isFinal: Bool) {
        latestTranscript = text
        onPartial?(text)
        if isFinal {
            // Apple sends isFinal when it detects end-of-speech — but this can fire mid-sentence.
            // Restart the recognition task so the user can keep speaking; the silence timer
            // handles the actual commit when they genuinely stop.
            recycleRecognitionTask()
            return
        }
        scheduleSilenceCommit()
    }

    private func recycleRecognitionTask() {
        guard isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            stopListening(commitIfPossible: true)
            return
        }
        // Tear down old task/request but keep the audio engine running
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = OrbitSpeechContextProvider.contextualStrings()
        request = req

        // Rebind the audio tap to the new request
        let node = audioEngine.inputNode
        node.removeTap(onBus: 0)
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        // Capture prefix so the closure below can prepend it to new words
        let prefix = latestTranscript
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let newWords = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let combined = prefix.isEmpty ? newWords
                        : newWords.isEmpty ? prefix
                        : "\(prefix) \(newWords)"
                    self.handleTranscriptUpdate(combined, isFinal: result.isFinal)
                }
                if let error {
                    self.lastError = "SFSpeechRecognitionTask error: \(error.localizedDescription)"
                    self.stopListening(commitIfPossible: true)
                }
            }
        }

        // Keep the silence commit ticking — fires if the user has genuinely stopped
        scheduleSilenceCommit()
    }

    /// Turns on macOS voice processing (echo cancellation) so the mic can stay open while
    /// ORBIT is speaking, without hearing itself.
    ///
    /// Applied ONLY to this controller's engine. `OrbitWakeWordController` owns a separate
    /// `AVAudioEngine`, so the wake path — a month of tuning — is untouched either way.
    /// Behind `orbitMac.allowBargeIn`, default off: if it degrades anything, one toggle
    /// returns to the previous behaviour with no rebuild.
    /// Guarantees macOS voice processing is OFF on this engine, and repairs it if a previous
    /// build left it on.
    ///
    /// **This is a rollback, and the reason is recorded so it is never tried this way again.**
    /// Enabling `setVoiceProcessingEnabled(true)` for barge-in (Phase 3.27) broke audio input
    /// completely — the mic opened, the orange indicator appeared, and nothing was ever heard.
    /// The console said exactly why, repeating continuously:
    ///
    ///     vp::vx::Voice_Processor … failed to process downlink voice proc …
    ///     "audio time stamp does not have valid sample time"
    ///     vp::vx::Voice_Processor_Interface_Adapter … failed to run downlink DSP (I/O fault)
    ///
    /// The Voice Processing I/O unit is a **duplex** unit: it cancels echo by comparing the
    /// mic against the *downlink* — the audio the same engine is playing. This engine only
    /// ever captures; it has no output. So the downlink has no valid timestamps, the DSP
    /// faults every buffer, and the capture path dies with it. TTS also plays through
    /// AVSpeechSynthesizer on a separate path, so it was never a reference signal VPIO could
    /// have used anyway. Input-only engines cannot use VPIO — that is a design constraint,
    /// not a tuning problem.
    ///
    /// The flag lives on the node, so a single enable persisted for the whole app lifetime;
    /// clearing it here recovers an app that was already poisoned.
    private func ensureVoiceProcessingDisabled(on node: AVAudioInputNode) {
        guard node.isVoiceProcessingEnabled else { return }
        do {
            try node.setVoiceProcessingEnabled(false)
            OrbitBargeIn.log("voice processing force-disabled (recovering audio input)")
        } catch {
            OrbitBargeIn.log("could not disable voice processing: \(error.localizedDescription)")
        }
    }

    /// Opens the mic while ORBIT is speaking, so he can be interrupted.
    ///
    /// The commit path is deliberately not reused: mid-speech audio is noisy and echo-prone,
    /// so nothing is committed as a message here. Partials are judged by `OrbitBargeIn`, and
    /// the only outcome is "he started talking" — the real listening session takes over.
    func startBargeInListening(spokenText: @escaping () -> String,
                               onInterrupt: @escaping (String) -> Void) async {
        guard OrbitBargeIn.isEnabled else { return }
        guard !isListening else {
            OrbitBargeIn.log("NOT ARMED — mic already in use")
            return
        }
        do {
            try await requestAuthorization()
        } catch {
            OrbitBargeIn.log("NOT ARMED — permission: \(error.localizedDescription)")
            return
        }
        var fired = false
        do {
            try await startListening(
                onPartial: { [weak self] text in
                    guard !fired, self != nil else { return }
                    let said = spokenText()
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if OrbitBargeIn.shouldInterrupt(transcript: trimmed, spokenText: said) {
                        fired = true
                        OrbitBargeIn.log("INTERRUPT ← heard \"\(trimmed)\"")
                        onInterrupt(trimmed)
                    } else {
                        OrbitBargeIn.log("ignored \"\(trimmed)\" (echo/filler/too short)")
                    }
                },
                onCommit: { _ in },
                silenceAfterSeconds: 2.4
            )
            let engineName = usingModernEngine ? "SpeechAnalyzer" : "SFSpeech"
            OrbitBargeIn.log("armed — \(engineName), content-based echo rejection")
        } catch {
            OrbitBargeIn.log("NOT ARMED — \(error.localizedDescription)")
        }
    }

    private func scheduleSilenceCommit() {
        silenceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.stopListening(commitIfPossible: true)
            }
        }
        silenceWorkItem = work
        let pause = endpointPauseSeconds(for: latestTranscript)
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
    }

    /// Silence alone was deciding when he had finished, so "remind me to…" and a thinking pause
    /// were treated the same as a finished sentence. The decision now also reads what was said —
    /// see `OrbitUtteranceCompleteness`, where it lives as a pure function so the corpus can
    /// exercise it without an audio engine.
    private func endpointPauseSeconds(for transcript: String) -> TimeInterval {
        OrbitUtteranceCompleteness.endpointPause(for: transcript, base: silenceAfterSeconds)
    }

    private func requestAuthorization() async throws {
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        switch speechAuth {
        case .authorized:
            break
        case .notDetermined:
            // macOS only presents the Speech prompt to an active app. ORBIT lives in a menu-bar
            // panel that resigns focus the moment the request fires, so without this the status
            // stays stuck at notDetermined forever and the mic never opens.
            NSApplication.shared.activate(ignoringOtherApps: true)
            let speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard speechStatus == .authorized else {
                throw SpeechInputError.speechNotAuthorized
            }
        case .denied, .restricted:
            throw SpeechInputError.speechNotAuthorized
        @unknown default:
            throw SpeechInputError.speechNotAuthorized
        }

        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micAuth {
        case .authorized:
            return
        case .notDetermined:
            let micOK = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard micOK else {
                throw SpeechInputError.microphoneNotAuthorized
            }
        case .denied, .restricted:
            throw SpeechInputError.microphoneNotAuthorized
        @unknown default:
            throw SpeechInputError.microphoneNotAuthorized
        }
    }
}

extension OrbitSpeechInputController {
    /// Explicitly asks macOS for Speech Recognition and Microphone access with ORBIT brought to
    /// the front, then reports what the system actually answered.
    ///
    /// Needed because the automatic request happens while wake listening starts at launch, when
    /// ORBIT has no focused window — macOS then declines to present the prompt and the status
    /// stays at `notDetermined` forever, which looks exactly like a broken microphone.
    static func requestPermissionsAndReport() async -> String {
        NSApplication.shared.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 400_000_000)

        var lines: [String] = []

        let speechBefore = SFSpeechRecognizer.authorizationStatus()
        if speechBefore == .notDetermined {
            let granted = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            lines.append("Speech recognition: \(describe(granted))")
        } else {
            lines.append("Speech recognition: \(describe(speechBefore)) (already answered)")
        }

        let micBefore = AVCaptureDevice.authorizationStatus(for: .audio)
        if micBefore == .notDetermined {
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
            lines.append("Microphone: \(ok ? "granted" : "denied")")
        } else {
            lines.append("Microphone: \(micBefore == .authorized ? "granted" : "not granted") (already answered)")
        }

        let stillBlocked = SFSpeechRecognizer.authorizationStatus() != .authorized
        if stillBlocked {
            lines.append(
                "macOS did not grant Speech Recognition. If no dialog appeared, open System Settings "
                + "→ Privacy & Security → Speech Recognition and switch ORBITMac on there."
            )
        } else {
            lines.append("All set — say \u{201C}Hey ORBIT\u{201D} and I should hear you.")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "still not asked — no dialog appeared"
        @unknown default: return "unknown"
        }
    }
}

enum SpeechInputError: LocalizedError {
    case speechNotAuthorized
    case microphoneNotAuthorized
    case recognizerUnavailable
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            return "Speech Recognition permission is off. Go to System Settings → Privacy & Security → Speech Recognition and enable ORBIT."
        case .microphoneNotAuthorized:
            return "Microphone permission is off. Go to System Settings → Privacy & Security → Microphone and enable ORBIT."
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable right now — try again in a moment."
        case .engineStartFailed(let detail):
            return "Could not start voice input: \(detail)"
        }
    }
}
