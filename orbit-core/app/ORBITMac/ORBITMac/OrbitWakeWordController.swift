//
//  OrbitWakeWordController.swift
//  ORBITMac
//
//  Optional always-listening wake phrase (“Hey ORBIT”) using Speech.framework.
//  When detected: posts a notification; optional mic is started by `OrbitWakeVoiceBackstage` (no menu window).
//  Mutually exclusive with push-to-talk / hands-free mic (suspend while user is speaking).
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class OrbitWakeWordController: ObservableObject {
    struct WakeDiagnosticsSnapshot {
        var windowStartedAt: Date = Date()
        var observationCount: Int = 0
        var candidateCount: Int = 0
        var acceptedCount: Int = 0
        var rejectedLowConfidenceCount: Int = 0
        var rejectedCooldownCount: Int = 0
        var restartCount: Int = 0
        var listeningStartCount: Int = 0
        var lastTranscript: String = ""
        var lastAcceptedAt: Date?
        var recentCandidateConfidences: [Double] = []
        /// Which ears are actually in use — the en_IN model or the old en_CA one.
        var engineDescription: String = "starting…"
    }

    static let shared = OrbitWakeWordController()

    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?
    @Published private(set) var diagnostics = WakeDiagnosticsSnapshot()

    private let audioEngine = AVAudioEngine()

    private var speechRecognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var suspendedForUserSpeech = false
    private var lastTriggerAt: Date?
    private let cooldown: TimeInterval = 1.6
    private var resumeWorkItem: DispatchWorkItem?
    private var restartAttempt = 0
    private var powerModeObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var deferredRetryWorkItem: DispatchWorkItem?
    private var healthCheckTimer: Timer?
    private var proactiveRestartWorkItem: DispatchWorkItem?
    private var listeningStartedAt: Date?
    /// Incremented each time a new recognition task is created. Callbacks from old tasks carry
    /// the generation they were born in; if it doesn't match the current generation they are ignored.
    /// This eliminates spurious `restartAfterDelay()` calls from cancelled-task error callbacks.
    private var taskGeneration = 0

    /// The macOS 26 / en_IN recogniser. Nil while the legacy engine is in use.
    private var modernEngine: AnyObject?

    private typealias WakeDecision = OrbitWakePhraseMatcher.Decision

    /// Whether wake listening should use the en_IN SpeechAnalyzer engine.
    ///
    /// Defaults to **on**, but is a user default rather than a constant on purpose: more than a
    /// month of tuning produced the current accuracy, and if the new model ever proves worse in
    /// real use it must be possible to fall back without a rebuild. Set
    /// `orbitMac.wakeUseModernEngine` to false to return to the previous en_CA behaviour exactly.
    var prefersModernEngine: Bool {
        UserDefaults.standard.object(forKey: "orbitMac.wakeUseModernEngine") as? Bool ?? true
    }

    private init() {
        powerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncFromDefaults()
            }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncFromDefaults()
            }
        }
        startHealthChecks()
    }

    deinit {
        healthCheckTimer?.invalidate()
        if let powerModeObserver {
            NotificationCenter.default.removeObserver(powerModeObserver)
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    /// UserDefaults key matches `@AppStorage("orbitMac.listenForHeyOrbit")`.
    var isEnabledInDefaults: Bool {
        UserDefaults.standard.bool(forKey: "orbitMac.listenForHeyOrbit")
    }

    /// Exposed for diagnostics: a stuck suspension is otherwise invisible — no error, just silence.
    var isSuspendedForUserSpeech: Bool { suspendedForUserSpeech }

    func applicationDidFinishLaunching() {
        syncFromDefaults()
    }

    func syncFromDefaults() {
        if isEnabledInDefaults {
            Task { await startWakeListeningIfPossible() }
        } else {
            stopWakeListening()
        }
    }

    func resetDiagnostics() {
        diagnostics = WakeDiagnosticsSnapshot()
    }

    /// Call before starting push-to-talk / hands-free capture so only one pipeline uses the mic.
    func suspendForUserSpeech() {
        suspendedForUserSpeech = true
        suspendedAt = Date()
        stopWakeListening()
    }

    /// When the current suspension began, so a suspension that outlives its voice turn can be
    /// detected and cleared instead of silently deafening ORBIT forever.
    private var suspendedAt: Date?

    /// Call after user speech pipeline ends so wake can resume (if still enabled in Settings).
    func scheduleResumeAfterUserSpeech(delay: TimeInterval = 0.7) {
        resumeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.suspendedForUserSpeech = false
                self?.suspendedAt = nil
                self?.syncFromDefaults()
            }
        }
        resumeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func startWakeListeningIfPossible() async {
        guard isEnabledInDefaults, !suspendedForUserSpeech else { return }
        guard !isListening else { return }
        if shouldThrottleForPower() {
            lastError = ProcessInfo.processInfo.isLowPowerModeEnabled
                ? "Wake listening is paused because Low Power Mode is on. Turn it off, or enable \u{201C}Listen in Low Power Mode\u{201D} in ORBIT\u{2019}s gear menu."
                : "Wake listening paused — your Mac is running hot."
            scheduleDeferredRetry()
            return
        }
        lastError = nil
        do {
            try await requestAuthorization()

            // Preferred path: on-device en_IN via SpeechAnalyzer. Falls through to the legacy
            // en_CA recogniser if the model is missing or the engine refuses to start, so a
            // failure here degrades to the old behaviour instead of leaving ORBIT deaf.
            if #available(macOS 26.0, *), prefersModernEngine, await OrbitWakeSpeechEngine.isUsable() {
                if await startModernWakeListening() { return }
            }

            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                lastError = "Speech recognizer unavailable for wake word."
                return
            }
            stopWakeListening()
            diagnostics.engineDescription = "SFSpeechRecognizer, \(recognizer.locale.identifier)"

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            // On-device recognition has no 60s server timeout and works offline.
            // Fall back to server if on-device is unavailable for this locale.
            req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request = req

            let node = audioEngine.inputNode
            node.removeTap(onBus: 0)
            let format = node.outputFormat(forBus: 0)
            // On macOS 26, if microphone permission is in a transitional state (e.g. after
            // tccutil reset), outputFormat(forBus: 0) can return a zero sample-rate or
            // zero-channel format. Installing a tap with that invalid format causes the audio
            // engine to throw -10877 (kAudioUnitErr_InvalidElement) on start. Guard here so
            // we bail to restartAfterDelay() instead of crashing into the engine.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                // Invalid format signals that the microphone is inaccessible (permission
                // in a transitional state after tccutil reset, or hardware not ready).
                // Use the slow deferred retry (20 s) rather than the rapid backoff so we
                // don't flood the console — the health-check timer at 6 s also recovers.
                lastError = "Microphone format unavailable — check Privacy & Security → Microphone."
                isListening = false
                scheduleDeferredRetry()
                return
            }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            taskGeneration += 1
            let myGeneration = taskGeneration
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.taskGeneration == myGeneration else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.handleRecognitionResult(result, displayText: text)
                        if result.isFinal {
                            // Recycle WITHOUT stopping the audio engine — zero gap between cycles.
                            // Use else-if for error: recycleRecognitionTask resets restartAttempt,
                            // so calling restartAfterDelay immediately after would wipe the backoff
                            // and cause a rapid-fire restart loop on simultaneous result+error.
                            self.recycleRecognitionTask(generation: myGeneration)
                        }
                    } else if error != nil {
                        self.restartAfterDelay()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            restartAttempt = 0
            listeningStartedAt = Date()
            diagnostics.listeningStartCount += 1
            scheduleProactiveRestart()
        } catch let wakeErr as WakeWordError {
            // Permission permanently denied — stop retrying until the user changes settings.
            // Retrying on a denied permission just burns backoff slots without any hope of success.
            lastError = wakeErr.localizedDescription
            isListening = false
        } catch {
            lastError = error.localizedDescription
            isListening = false
            restartAfterDelay()
        }
    }

    /// Starts wake listening on the en_IN SpeechAnalyzer engine.
    /// - Returns: `false` when it could not start, so the caller can fall back to the legacy engine.
    @available(macOS 26.0, *)
    private func startModernWakeListening() async -> Bool {
        stopWakeListening()

        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        // Same guard as the legacy path: a 0 Hz / 0-channel format means the mic is in a
        // transitional permission state, and installing a tap with it throws -10877.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "Microphone format unavailable — check Privacy & Security → Microphone."
            isListening = false
            scheduleDeferredRetry()
            return true  // handled: retry is scheduled, do not also try the legacy engine
        }

        let engine = OrbitWakeSpeechEngine()
        taskGeneration += 1
        let myGeneration = taskGeneration

        do {
            try await engine.start(
                onSample: { [weak self] sample in
                    Task { @MainActor in
                        guard let self, self.taskGeneration == myGeneration else { return }
                        self.processWakeSample(sample)
                    }
                },
                onFailure: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.taskGeneration == myGeneration else { return }
                        self.restartAfterDelay()
                    }
                }
            )
        } catch {
            // Model or format unavailable — let the caller fall back to the legacy recogniser.
            await engine.stop()
            return false
        }

        modernEngine = engine
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak engine] buffer, _ in
            engine?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            lastError = error.localizedDescription
            isListening = false
            await engine.stop()
            modernEngine = nil
            restartAfterDelay()
            return true
        }

        isListening = true
        restartAttempt = 0
        listeningStartedAt = Date()
        diagnostics.listeningStartCount += 1
        diagnostics.engineDescription = "SpeechAnalyzer, \(engine.localeIdentifier)"
        // No 45-second proactive recycle here: SpeechAnalyzer has no server session limit, which
        // is what that timer existed to dodge. One continuous session is both simpler and
        // gapless — and the gap between recycles is where fast utterances used to be lost.
        return true
    }

    func stopWakeListening() {
        // Deliberately does NOT cancel `resumeWorkItem`: that timer is what clears
        // `suspendedForUserSpeech`. Cancelling it here left the flag stuck true with no error,
        // and every later start attempt exited silently at the guard — ORBIT went permanently
        // deaf while reporting "not listening, no error".
        deferredRetryWorkItem?.cancel()
        deferredRetryWorkItem = nil
        proactiveRestartWorkItem?.cancel()
        proactiveRestartWorkItem = nil
        listeningStartedAt = nil
        // Always stop — even when isRunning is false, audioEngine.prepare() may have
        // allocated an IO thread. Skipping stop() leaves that thread alive, causing
        // "there already is a thread" on the next start attempt.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        taskGeneration += 1  // invalidate any callbacks already dispatched from the cancelled task
        isListening = false

        // The mic itself is already released above — audioEngine.stop() and removeTap are
        // synchronous, so a voice turn can claim it immediately. Only the analyzer teardown is
        // async, and the generation bump above has already orphaned its callbacks.
        if #available(macOS 26.0, *), let engine = modernEngine as? OrbitWakeSpeechEngine {
            modernEngine = nil
            Task { await engine.stop() }
        }
    }

    private func restartAfterDelay() {
        // If the session ran for 20+ seconds before failing, treat it as a normal Apple timeout
        // and reset the backoff counter. Only keep penalizing rapid consecutive failures.
        let sessionAge = listeningStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if sessionAge >= 20 {
            restartAttempt = 0
        }
        stopWakeListening()
        guard isEnabledInDefaults, !suspendedForUserSpeech else { return }
        restartAttempt = min(restartAttempt + 1, 4)
        diagnostics.restartCount += 1
        let backoff = min(3.0, 0.3 * pow(1.6, Double(restartAttempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff) { [weak self] in
            Task { await self?.startWakeListeningIfPossible() }
        }
    }

    /// Swaps out the SFSpeechRecognitionTask and request without stopping the AVAudioEngine.
    /// The audio tap keeps running continuously — the only thing that changes is which request
    /// receives the next audio buffer. This eliminates the ~300ms restart gap that caused fast
    /// "wake up orbit" utterances to be missed between recognition cycles.
    private func recycleRecognitionTask(generation: Int) {
        guard generation == taskGeneration else { return }
        guard isListening, !suspendedForUserSpeech, isEnabledInDefaults else {
            stopWakeListening()
            return
        }
        proactiveRestartWorkItem?.cancel()
        proactiveRestartWorkItem = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            stopWakeListening()
            Task { await startWakeListeningIfPossible() }
            return
        }

        let oldRequest = request
        let oldTask = task

        taskGeneration += 1
        let newGeneration = taskGeneration

        let newReq = SFSpeechAudioBufferRecognitionRequest()
        newReq.shouldReportPartialResults = true
        newReq.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        // Route the tap to the new request BEFORE cancelling the old one — zero audio lost.
        request = newReq
        oldRequest?.endAudio()
        oldTask?.cancel()

        task = recognizer.recognitionTask(with: newReq) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.taskGeneration == newGeneration else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.handleRecognitionResult(result, displayText: text)
                    if result.isFinal {
                        self.recycleRecognitionTask(generation: newGeneration)
                    }
                } else if error != nil {
                    // else-if: don't restart when we already recycled on isFinal.
                    // Simultaneous result+error would reset restartAttempt via recycle
                    // and then call restartAfterDelay with backoff=0 — causing a flood.
                    self.restartAfterDelay()
                }
            }
        }

        restartAttempt = 0
        listeningStartedAt = Date()
        diagnostics.listeningStartCount += 1
        scheduleProactiveRestart()
    }

    /// Proactively recycles the recognition task every 45s, before Apple's ~60s server limit.
    /// Uses recycleRecognitionTask so the audio engine never stops mid-cycle.
    private func scheduleProactiveRestart() {
        proactiveRestartWorkItem?.cancel()
        let capturedGeneration = taskGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.recycleRecognitionTask(generation: capturedGeneration)
            }
        }
        proactiveRestartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    /// Whether wake listening should stand down to protect battery or hardware.
    ///
    /// The Low Power Mode pause is opt-out via `orbitMac.listenInLowPowerMode` (default off, so
    /// the original battery-saving behaviour is unchanged unless the user asks otherwise).
    /// Thermal throttling is never bypassed — that one protects the machine, not the battery.
    private func shouldThrottleForPower() -> Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled,
           !UserDefaults.standard.bool(forKey: "orbitMac.listenInLowPowerMode")
        {
            return true
        }
        if info.thermalState == .serious || info.thermalState == .critical {
            return true
        }
        return false
    }

    private func scheduleDeferredRetry() {
        deferredRetryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isEnabledInDefaults, !self.suspendedForUserSpeech else { return }
                await self.startWakeListeningIfPossible()
            }
        }
        deferredRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func startHealthChecks() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureWakePipelineHealthy()
            }
        }
    }

    private func ensureWakePipelineHealthy() {
        guard isEnabledInDefaults else { return }
        // Watchdog: a suspension only ever covers one voice turn. If it has outlived that turn
        // — nothing speaking, nothing listening — clear it so a lost resume can't deafen ORBIT.
        if suspendedForUserSpeech,
           !OrbitVoiceKit.shared.speechInput.isListening,
           !OrbitVoiceKit.shared.speech.isSpeaking,
           let since = suspendedAt,
           Date().timeIntervalSince(since) > 12
        {
            suspendedForUserSpeech = false
            suspendedAt = nil
        }
        guard !suspendedForUserSpeech else { return }
        guard !isListening else { return }
        guard !shouldThrottleForPower() else { return }
        Task { await startWakeListeningIfPossible() }
    }

    /// Legacy-engine adapter: turns an SFSpeechRecognitionResult into the engine-neutral sample
    /// both recognisers are judged by.
    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult, displayText: String) {
        let tokens = result.bestTranscription.segments.map {
            OrbitWakeToken(text: $0.substring, confidence: Double($0.confidence))
        }
        processWakeSample(OrbitWakeSample(text: displayText, isFinal: result.isFinal, tokens: tokens))
    }

    /// The one place a wake decision is acted on, whichever engine produced the transcript.
    private func processWakeSample(_ sample: OrbitWakeSample) {
        let decision = OrbitWakePhraseMatcher.evaluate(sample)
        recordWakeObservation(decision: decision, transcript: sample.text)
        guard decision.acceptedByPattern else { return }
        if let last = lastTriggerAt, Date().timeIntervalSince(last) < cooldown {
            diagnostics.rejectedCooldownCount += 1
            return
        }
        lastTriggerAt = Date()
        diagnostics.acceptedCount += 1
        diagnostics.lastAcceptedAt = lastTriggerAt
        stopWakeListening()

        let startVoice = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            || UserDefaults.standard.bool(forKey: "orbitMac.wakeWordAutoListen")
        NotificationCenter.default.post(
            name: .orbitWakeWordDetected,
            object: nil,
            userInfo: [
                "startVoice": startVoice,
                // "Are you there ORBIT?" is a question as well as a summons; the listener
                // answers it out loud before opening the mic.
                "presenceQuestion": decision.isPresenceQuestion,
            ]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { await self?.startWakeListeningIfPossible() }
        }
    }

    private func recordWakeObservation(decision: WakeDecision, transcript: String) {
        // Record EVERY transcript, not just wake candidates. Previously only candidates were
        // stored, so "the recogniser hears nothing" and "it hears fine but the phrase doesn't
        // match" produced identical diagnostics — the one distinction that matters when the
        // wake word stops responding.
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            diagnostics.observationCount += 1
            diagnostics.lastTranscript = cleaned.count > 84 ? String(cleaned.prefix(84)) + "…" : cleaned
        }
        if decision.isCandidate {
            diagnostics.candidateCount += 1
            if let c = decision.avgConfidence {
                diagnostics.recentCandidateConfidences.append(c)
                if diagnostics.recentCandidateConfidences.count > 12 {
                    diagnostics.recentCandidateConfidences.removeFirst(diagnostics.recentCandidateConfidences.count - 12)
                }
            }
            if decision.rejectedForLowConfidence {
                diagnostics.rejectedLowConfidenceCount += 1
            }
        }
    }

    private func requestAuthorization() async throws {
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        switch speechAuth {
        case .authorized:
            break
        case .notDetermined:
            // The prompt is only shown to an active app; wake listening starts at launch when
            // ORBIT has no focused window, so ask for focus first or the request silently no-ops.
            NSApplication.shared.activate(ignoringOtherApps: true)
            let speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard speechStatus == .authorized else {
                throw WakeWordError.speechNotAuthorized
            }
        case .denied, .restricted:
            throw WakeWordError.speechNotAuthorized
        @unknown default:
            throw WakeWordError.speechNotAuthorized
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
                throw WakeWordError.microphoneNotAuthorized
            }
        case .denied, .restricted:
            throw WakeWordError.microphoneNotAuthorized
        @unknown default:
            throw WakeWordError.microphoneNotAuthorized
        }
    }
}

private enum WakeWordError: LocalizedError {
    case speechNotAuthorized
    case microphoneNotAuthorized

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            return "Speech recognition is not authorized."
        case .microphoneNotAuthorized:
            return "Microphone is not authorized."
        }
    }
}
