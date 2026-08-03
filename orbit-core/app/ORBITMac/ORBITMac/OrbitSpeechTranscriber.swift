//
//  OrbitSpeechTranscriber.swift
//  ORBITMac
//
//  Speech recognition on macOS 26's SpeechAnalyzer engine, replacing SFSpeechRecognizer.
//
//  Two reasons this beats bundling Whisper:
//
//  1. Accent. Apple ships a dedicated **en_IN** acoustic model and it is already installed on
//     this Mac. ORBIT had been running `Locale.current` — en_CA — a Canadian English model
//     listening to an Indian accent, which is the root of the "kachuful → a game catch full"
//     class of mishearing that phonetic alias tables were patching one entry at a time.
//  2. Portability. This is a first-party framework present on macOS 26 *and* iOS 26, so it moves
//     to iPhone/iPad/Watch unchanged. A bundled Whisper binary would not.
//
//  The engine also has no 60-second server timeout, so there is no `isFinal` mid-sentence
//  recycling to work around.
//

import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class OrbitSpeechTranscriber {

    /// Locale preference, best accent match first. `en_IN` is chosen ahead of the system locale
    /// deliberately — matching the speaker matters more than matching the region.
    static let preferredLocaleIdentifiers = ["en_IN", "en_CA", "en_GB", "en_US"]

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private(set) var isRunning = false

    // MARK: - Availability

    /// The locale ORBIT should transcribe with, or nil when none is installed.
    static func bestInstalledLocale() async -> Locale? {
        let installed = await SpeechTranscriber.installedLocales
        let supported = await SpeechTranscriber.supportedLocales
        for identifier in preferredLocaleIdentifiers {
            if let hit = installed.first(where: { $0.identifier == identifier }) { return hit }
        }
        // Nothing preferred installed — fall back to any installed English, then any supported.
        if let anyEnglish = installed.first(where: { $0.identifier.hasPrefix("en") }) { return anyEnglish }
        return supported.first { $0.identifier.hasPrefix("en") }
    }

    static func isUsable() async -> Bool { await bestInstalledLocale() != nil }

    // MARK: - Lifecycle

    /// Starts a transcription session.
    /// - Parameters:
    ///   - onVolatile: in-progress text, replaced as the engine refines it.
    ///   - onFinalized: text the engine has committed and will not revise.
    func start(
        onVolatile: @escaping @Sendable (String) -> Void,
        onFinalized: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let locale = await Self.bestInstalledLocale() else {
            throw TranscriberError.noInstalledLocale
        }

        // `.progressiveTranscription` streams volatile results as the user speaks, which is what
        // drives ORBIT's live composer text and its silence-based commit.
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        transcriber = module

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.noCompatibleAudioFormat
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Deliberately the module-only initializer. `SpeechAnalyzer(inputSequence:modules:)`
        // *begins analyzing immediately*, so pairing it with an explicit `start(inputSequence:)`
        // hands the analyzer two sequences and trips
        // "Failed precondition: cannot simultaneously analyze multiple input sequences".
        let session = SpeechAnalyzer(modules: [module])
        analyzer = session

        resultsTask = Task {
            do {
                for try await result in module.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    // `resultsFinalizationTime` past the result's range means it is settled.
                    if result.range.end <= result.resultsFinalizationTime {
                        onFinalized(text)
                    } else {
                        onVolatile(text)
                    }
                }
            } catch {
                // Stream ended or failed; the caller's silence timer still governs the turn.
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

    /// Ends the session, flushing anything the engine still holds.
    func stop() async {
        isRunning = false
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
    }

    // MARK: - Format conversion

    /// The mic runs at 48 kHz; the analyzer wants 16 kHz mono. Converting here keeps the audio
    /// tap untouched, so the same buffers can still feed other consumers.
    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let source = buffer.format as AVAudioFormat? else { return nil }
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

    enum TranscriberError: LocalizedError {
        case noInstalledLocale
        case noCompatibleAudioFormat

        var errorDescription: String? {
            switch self {
            case .noInstalledLocale:
                return "No speech model is installed for English. Check System Settings → General → Language & Region."
            case .noCompatibleAudioFormat:
                return "Could not negotiate an audio format with the speech engine."
            }
        }
    }
}
