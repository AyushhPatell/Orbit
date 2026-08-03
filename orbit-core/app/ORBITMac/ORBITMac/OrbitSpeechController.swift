//
//  OrbitSpeechController.swift
//  ORBITMac
//
//  Text-to-speech via AVSpeechSynthesizer.
//  Voice priority: Personal Voice → Premium quality → Enhanced quality → default en-US.
//  Rate is tuned for conversational AI delivery (~0.56), not the slow default (0.50).
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class OrbitSpeechController: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isUsingPersonalVoice = false
    private(set) var lastSpokenText: String? = nil

    private let synthesizer = AVSpeechSynthesizer()

    private var cachedPersonalVoice: AVSpeechSynthesisVoice?
    private var cachedSystemVoice: AVSpeechSynthesisVoice?
    private var personalVoiceProbeFinished = false
    private var activeUtteranceCount = 0
    private var speakGeneration = 0
    private var smoothedSpeechEnergy: Double = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    func speak(_ text: String) {
        let cleaned = Self.spokenText(from: text)
        guard !cleaned.isEmpty else { return }
        lastSpokenText = cleaned
        stop()
        isSpeaking = true
        syncSpeakingOrbWithOutputState()
        syncSpeakingOrbEnergy(0.24)
        speakGeneration += 1
        let generation = speakGeneration
        Task { @MainActor in
            await self.resolvePersonalVoiceIfAvailable()
            guard generation == self.speakGeneration else { return }
            self.activeUtteranceCount = 1
            let utterance = AVSpeechUtterance(string: cleaned)
            utterance.voice = self.voiceForUtterance()
            utterance.rate = Self.naturalRate(for: cleaned)
            utterance.pitchMultiplier = 1.0
            utterance.preUtteranceDelay = 0
            utterance.postUtteranceDelay = 0
            self.synthesizer.speak(utterance)
        }
    }

    func stop() {
        speakGeneration += 1
        activeUtteranceCount = 0
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        syncSpeakingOrbWithOutputState()
        smoothedSpeechEnergy = 0
        OrbitListeningPresence.shared.setSpeechOutputEnergy(0)
    }

    // MARK: - Voice selection

    private func voiceForUtterance() -> AVSpeechSynthesisVoice {
        if let p = cachedPersonalVoice { return p }
        if let v = cachedSystemVoice { return v }
        let v = Self.bestEnglishVoice()
        cachedSystemVoice = v
        return v
    }

    /// Picks the highest-quality available English voice.
    /// Quality (Premium > Enhanced) is the primary axis; gender is not penalised.
    private static func bestEnglishVoice() -> AVSpeechSynthesisVoice {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let best = candidates.max(by: { scoreVoice($0) < scoreVoice($1) }) {
            return best
        }
        return AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice.speechVoices().first!
    }

    private static func scoreVoice(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0

        // Region preference.
        if voice.language == "en-US" { score += 20 }
        else if voice.language.hasPrefix("en") { score += 8 }

        // Quality is the primary differentiator — no gender penalty.
        if #available(macOS 13.0, *) {
            switch voice.quality {
            case .premium:  score += 200
            case .enhanced: score += 80
            default: break
            }
        }

        // Prefer male voices — gives a consistent gender identity for ORBIT across lock/unlock cycles.
        // Male voices score higher, so on ties male always wins; female voices still appear if no male equivalent exists.
        let name = voice.name.lowercased()
        let maleNames = ["evan", "alex", "oliver", "daniel", "fred", "tom", "aaron", "arthur", "reed"]
        let femaleNames = ["ava", "nicky", "zoe", "allison", "kate", "samantha", "karen", "moira", "tessa"]
        if maleNames.contains(where: { name.contains($0) }) { score += 20 }
        else if femaleNames.contains(where: { name.contains($0) }) { score += 5 }

        return score
    }

    // MARK: - Rate

    /// Conversational rate tuned for a short-reply AI assistant.
    /// Slightly faster for brief confirmations; slightly slower for long explanations.
    private static func naturalRate(for text: String) -> Float {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if words <= 6  { return 0.53 }   // short confirmations
        if words >= 50 { return 0.50 }   // long explanations — give it room
        return 0.52                       // default conversational
    }

    // MARK: - Personal Voice (macOS 14+)

    private func resolvePersonalVoiceIfAvailable() async {
        guard #available(macOS 14.0, *) else { return }
        if cachedPersonalVoice != nil { isUsingPersonalVoice = true; return }
        if personalVoiceProbeFinished { isUsingPersonalVoice = false; return }
        personalVoiceProbeFinished = true

        let status = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()
        guard status == .authorized else { isUsingPersonalVoice = false; return }

        let personal = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        cachedPersonalVoice = personal.first
        isUsingPersonalVoice = cachedPersonalVoice != nil
    }

    // MARK: - Energy sync

    private func syncSpeakingOrbWithOutputState() {
        OrbitListeningPresence.shared.setSpeechOutputActive(isSpeaking)
    }

    private func syncSpeakingOrbEnergy(_ raw: Double) {
        let clamped = max(0, min(1, raw))
        smoothedSpeechEnergy = (smoothedSpeechEnergy * 0.62) + (clamped * 0.38)
        OrbitListeningPresence.shared.setSpeechOutputEnergy(smoothedSpeechEnergy)
    }

    // MARK: - Text cleanup

    /// Strips markdown and normalises punctuation so the synthesizer reads cleanly.
    nonisolated private static func spokenText(from raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "*",  with: "")
        s = s.replacingOccurrences(of: "`",  with: "")
        s = s.replacingOccurrences(of: "#",  with: "")
        s = s.replacingOccurrences(of: "•",  with: "")
        s = s.replacingOccurrences(of: "—",  with: ", ")
        s = s.replacingOccurrences(of: ";",  with: ", ")
        s = s.replacingOccurrences(of: ":",  with: ", ")
        s = s.replacingOccurrences(of: "\n", with: ". ")
        s = s.replacingOccurrences(of: "\\([^\\)]*\\)", with: "",   options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+",          with: " ",  options: .regularExpression)
        s = s.replacingOccurrences(of: "([!?.,])\\1+",  with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*,",        with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\.\\s*\\.",    with: ".",  options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension OrbitSpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            let ns = utterance.speechString as NSString
            guard characterRange.location != NSNotFound,
                  characterRange.location + characterRange.length <= ns.length else { return }
            let fragment = ns.substring(with: characterRange)
            let words = fragment.split(whereSeparator: \.isWhitespace).count
            let chars = fragment.count
            let emphasis = fragment.contains("!") ? 0.1 : (fragment.contains("?") ? 0.06 : 0)
            let target = min(0.95, 0.22 + (Double(words) * 0.12) + (Double(chars) * 0.008) + emphasis)
            self.syncSpeakingOrbEnergy(target)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.syncSpeakingOrbWithOutputState()
            self.syncSpeakingOrbEnergy(0.26)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.activeUtteranceCount = max(0, self.activeUtteranceCount - 1)
            if self.activeUtteranceCount == 0 {
                self.isSpeaking = false
                self.smoothedSpeechEnergy = 0
                OrbitListeningPresence.shared.setSpeechOutputEnergy(0)
            } else {
                self.syncSpeakingOrbEnergy(0.18)
            }
            self.syncSpeakingOrbWithOutputState()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.activeUtteranceCount = max(0, self.activeUtteranceCount - 1)
            if self.activeUtteranceCount == 0 {
                self.isSpeaking = false
                self.smoothedSpeechEnergy = 0
                OrbitListeningPresence.shared.setSpeechOutputEnergy(0)
            } else {
                self.syncSpeakingOrbEnergy(0.15)
            }
            self.syncSpeakingOrbWithOutputState()
        }
    }
}
