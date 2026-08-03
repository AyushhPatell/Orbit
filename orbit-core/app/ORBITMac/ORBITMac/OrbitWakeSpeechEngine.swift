//
//  OrbitWakeSpeechEngine.swift
//  ORBITMac
//
//  The wake word's ears, on macOS 26's SpeechAnalyzer with the **en_IN** acoustic model.
//
//  Why this file exists at all:
//
//  Wake listening ran on `SFSpeechRecognizer(locale: Locale.current)` — en_CA — a Canadian
//  English model listening to an Indian accent. That is the root cause of "orbit" arriving as
//  "or bit" / "are bit", which the phrase matcher had to paper over with hand-written accent
//  spellings, one observed mishearing at a time.
//
//  The obvious fix — point SFSpeechRecognizer at en_IN — is a trap, and was measured before
//  being rejected: en_IN reports `supportsOnDeviceRecognition == false` ("No Assistant asset for
//  language en-IN"). Wake listening would have silently become a **server** recogniser: audio
//  streamed to Apple 24/7, dead the moment the network drops, and subject to the 60-second
//  session limit. Offline capability is the one thing ORBIT cannot trade away.
//
//  SpeechAnalyzer is the only way to get en_IN *on-device*. Its model is already installed here
//  (push-to-talk uses it), it has no server timeout, and it exists on iOS 26 too, so this ports
//  to iPhone/iPad unchanged.
//
//  Two extras this engine gets that the old one could not:
//    • **Contextual biasing** — the analyzer is told to expect the word "ORBIT", so the decoder
//      weights it ahead of acoustically similar everyday words instead of guessing blind.
//    • **Per-token confidence**, which the tuned confidence gates in OrbitWakePhraseMatcher need.
//
//  The audio conversion below deliberately duplicates OrbitSpeechTranscriber's rather than
//  sharing it: push-to-talk is working and under field test, and this change must not be able
//  to reach it.
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class OrbitWakeSpeechEngine {

    /// Words and phrases the decoder should expect. This is the whole point of the exercise:
    /// "orbit" is a rare word in ordinary speech, so an unbiased decoder prefers common
    /// neighbours ("or bit", "arbit", "a bit"). Naming it here moves the odds back.
    private static let contextualPhrases = [
        "ORBIT",
        "Hey ORBIT",
        "wake up ORBIT",
        "are you there ORBIT",
        "are you awake ORBIT",
        "good morning ORBIT",
        "listen ORBIT",
        "ORBIT are you there",
    ]

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private(set) var isRunning = false
    private(set) var localeIdentifier = "—"

    /// The locale wake listening will actually use, or nil when no model is installed.
    static func bestInstalledLocale() async -> Locale? {
        await OrbitSpeechTranscriber.bestInstalledLocale()
    }

    static func isUsable() async -> Bool { await bestInstalledLocale() != nil }

    /// Starts continuous recognition.
    /// - Parameters:
    ///   - onSample: every transcript revision, volatile or settled, with per-word confidence.
    ///   - onFailure: the recognition stream ended unexpectedly; the caller should restart.
    func start(
        onSample: @escaping @Sendable (OrbitWakeSample) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) async throws {
        guard let locale = await Self.bestInstalledLocale() else {
            throw OrbitSpeechTranscriber.TranscriberError.noInstalledLocale
        }
        localeIdentifier = locale.identifier

        // `.volatileResults` is what makes wake detection fast — the phrase is matched while it is
        // still being spoken, rather than after the engine settles. `.transcriptionConfidence`
        // feeds the tuned confidence gates in the matcher.
        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
        transcriber = module

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw OrbitSpeechTranscriber.TranscriberError.noCompatibleAudioFormat
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Module-only initializer, then an explicit start(inputSequence:). The
        // `SpeechAnalyzer(inputSequence:modules:)` form begins analyzing immediately, and pairing
        // it with start() trips "cannot simultaneously analyze multiple input sequences" — a
        // crash this project has already paid for once.
        let session = SpeechAnalyzer(modules: [module])
        analyzer = session

        let context = AnalysisContext()
        context.contextualStrings[.general] = Self.contextualPhrases
        // Biasing is an optimisation, not a requirement: if the OS refuses the context the
        // engine still recognises normally, so a failure here must not abort wake listening.
        try? await session.setContext(context)

        resultsTask = Task {
            do {
                for try await result in module.results {
                    let attributed = result.text
                    let text = String(attributed.characters)
                    guard !text.isEmpty else { continue }

                    // One token per attributed run, carrying that run's confidence.
                    var tokens: [OrbitWakeToken] = []
                    for run in attributed.runs {
                        let piece = String(attributed[run.range].characters)
                        // Absent confidence means the engine did not score this run; treating
                        // that as 1.0 keeps the tuned gates from rejecting a clean transcript.
                        let confidence: Double = run.transcriptionConfidence ?? 1.0
                        for word in piece.split(whereSeparator: { $0.isWhitespace }) {
                            tokens.append(OrbitWakeToken(text: String(word), confidence: confidence))
                        }
                    }

                    let settled = result.range.end <= result.resultsFinalizationTime
                    onSample(OrbitWakeSample(text: text, isFinal: settled, tokens: tokens))
                }
                // The sequence completing means the analyzer stopped producing results.
                onFailure()
            } catch {
                onFailure()
            }
        }

        try await session.start(inputSequence: stream)
        isRunning = true
    }

    /// Feeds one microphone buffer, converting to the analyzer's format when needed.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let target = analyzerFormat, let continuation = inputContinuation else { return }
        guard let converted = convert(buffer, to: target) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        isRunning = false
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        // Wake listening has no transcript worth flushing; cancelling is faster than finalizing
        // and avoids a stall when the engine is torn down to hand the mic to a voice turn.
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
    }

    // MARK: - Format conversion

    /// The mic runs at 48 kHz; the analyzer wants 16 kHz mono.
    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = buffer.format
        if source == target { return buffer }

        if converter == nil || converter?.inputFormat != source || converter?.outputFormat != target {
            converter = AVAudioConverter(from: source, to: target)
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
