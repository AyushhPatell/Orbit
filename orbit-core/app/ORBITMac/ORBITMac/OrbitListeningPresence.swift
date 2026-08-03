//
//  OrbitListeningPresence.swift
//  ORBITMac
//
//  Shared state for menu bar + floating orb: mic listening vs speech output use different visuals.
//

import Combine
import Foundation

@MainActor
final class OrbitListeningPresence: ObservableObject {
    static let shared = OrbitListeningPresence()
    
    struct ConstellationItem: Identifiable, Equatable {
        let id: Int // 1-based for voice commands ("open 1")
        let title: String
        let subtitle: String
    }
    
    struct WakeVoiceCard: Equatable {
        let title: String
        let body: String
    }

    enum Phase: Equatable {
        case idle
        /// Heard “Hey ORBIT”; mic may not be up yet.
        case wakeAttention
        /// User speech recognition is active.
        case listening
    }

    /// Drives the floating orb: distinct “languages” for mic vs TTS (Siri-like clarity).
    enum OrbDisplayMode: Equatable {
        case hidden
        case listening
        case speaking
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var orbDisplayMode: OrbDisplayMode = .hidden
    @Published private(set) var wakeVoiceCard: WakeVoiceCard?
    @Published private(set) var constellationItems: [ConstellationItem] = []
    @Published private(set) var constellationVisible: Bool = false
    @Published private(set) var constellationTotalFound: Int = 0
    /// 0...1 envelope from TTS callbacks; HUD uses this for low-cost speech-reactive motion.
    @Published private(set) var speakingEnergy: Double = 0

    private var wakeDismissTask: Task<Void, Never>?
    private var wakeVoiceCardDismissTask: Task<Void, Never>?
    private var isMicrophoneOpen = false
    private var isSpeechOutputOpen = false
    private var isMenuPanelVisible = false

    private init() {}

    private func reconcileOrbMode() {
        // If the menu panel is open, keep HUD hidden to avoid duplicate surfaces.
        if isMenuPanelVisible {
            if orbDisplayMode != .hidden {
                orbDisplayMode = .hidden
            }
            return
        }
        let next: OrbDisplayMode
        if isSpeechOutputOpen {
            next = .speaking
        } else if isMicrophoneOpen || phase == .listening {
            next = .listening
        } else {
            next = .hidden
        }
        if next != orbDisplayMode {
            orbDisplayMode = next
        }
    }

    /// Call when the wake phrase fires (from app delegate so it works before `ContentView` loads).
    func beginWakeAttention() {
        wakeDismissTask?.cancel()
        phase = .wakeAttention
        reconcileOrbMode()
        wakeDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            if phase == .wakeAttention {
                phase = .idle
                self.reconcileOrbMode()
            }
        }
    }

    func setUserVoiceListening(_ listening: Bool) {
        isMicrophoneOpen = listening
        if listening {
            wakeDismissTask?.cancel()
            phase = .listening
        } else if phase == .listening {
            phase = .idle
        }
        reconcileOrbMode()
    }

    /// TTS state from `OrbitSpeechController` — orb stays visible with a different “breathing” pattern while ORBIT speaks.
    func setSpeechOutputActive(_ active: Bool) {
        isSpeechOutputOpen = active
        if !active, speakingEnergy != 0 {
            speakingEnergy = 0
        }
        reconcileOrbMode()
    }

    func setSpeechOutputEnergy(_ value: Double) {
        let v = max(0, min(1, value))
        if abs(v - speakingEnergy) > 0.001 {
            speakingEnergy = v
        }
        reconcileOrbMode()
    }

    func setMenuPanelVisible(_ visible: Bool) {
        if isMenuPanelVisible != visible {
            isMenuPanelVisible = visible
            reconcileOrbMode()
        }
    }
    
    func presentWakeVoiceCard(from text: String, title: String? = nil, ttlSeconds: Double = 120) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Callers can provide an explicit title to bypass the heuristic in buildWakeVoiceCard
        // (e.g. "Morning Briefing" uses the full-card layout instead of the compact mic pill).
        let card = title.map { WakeVoiceCard(title: $0, body: trimmed) } ?? Self.buildWakeVoiceCard(trimmed)
        if wakeVoiceCard != card {
            wakeVoiceCard = card
        }
        wakeVoiceCardDismissTask?.cancel()
        wakeVoiceCardDismissTask = Task { @MainActor in
            let minTTL = max(20, ttlSeconds)
            try? await Task.sleep(nanoseconds: UInt64(minTTL * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Keep the card while ORBIT is still speaking, then dismiss shortly after speech ends.
            var waitedTicks = 0
            while self.isSpeechOutputOpen, waitedTicks < 120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                waitedTicks += 1
            }
            self.wakeVoiceCard = nil
        }
    }
    
    func clearWakeVoiceCard() {
        wakeVoiceCardDismissTask?.cancel()
        wakeVoiceCardDismissTask = nil
        if wakeVoiceCard != nil {
            wakeVoiceCard = nil
        }
    }
    
    func showConstellation(items: [ConstellationItem], totalFound: Int) {
        constellationTotalFound = max(totalFound, items.count)
        constellationItems = Array(items.prefix(15))
        constellationVisible = true
    }
    
    func hideConstellation() {
        constellationVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Keep safety: only clear if no newer constellation is currently shown.
            if !self.constellationVisible {
                self.constellationItems = []
                self.constellationTotalFound = 0
            }
        }
    }
    
    private static func buildWakeVoiceCard(_ reply: String) -> WakeVoiceCard {
        let normalized = reply.replacingOccurrences(of: "\n\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().contains("open 1") || normalized.lowercased().contains("matches for") {
            return WakeVoiceCard(title: "Choose a file", body: normalized)
        }
        if normalized.lowercased().contains("reply yes") || normalized.lowercased().contains("confirm") {
            return WakeVoiceCard(title: "Confirm", body: normalized)
        }
        // Clarification questions: compact, no title — keeps the UI clean and minimal.
        return WakeVoiceCard(title: "", body: normalized)
    }

    var showsPanelOrb: Bool {
        phase != .idle
    }

    var menuBarSystemImage: String {
        if isSpeechOutputOpen {
            return "speaker.wave.3.fill"
        }
        switch phase {
        case .idle: return "sparkles"
        case .wakeAttention: return "waveform.circle.fill"
        case .listening: return "mic.fill"
        }
    }

    var menuBarHelp: String {
        if isSpeechOutputOpen {
            return "ORBIT — speaking"
        }
        switch phase {
        case .idle: return "ORBIT"
        case .wakeAttention: return "ORBIT — heard you"
        case .listening: return "ORBIT — listening"
        }
    }
}
