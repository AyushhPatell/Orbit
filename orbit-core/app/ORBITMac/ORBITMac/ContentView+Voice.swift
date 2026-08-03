//
//  ContentView+Voice.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    @MainActor
    func toggleVoiceInput() async {
        if speechInput.isListening {
            speechInput.stopListening(commitIfPossible: true)
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }
        suppressAutoVoiceResume = false
        await startVoiceInputSession()
    }

    @MainActor
    func consumeWakeVoicePendingIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "orbitMac.pendingWakeVoiceStart") else { return }
        UserDefaults.standard.set(false, forKey: "orbitMac.pendingWakeVoiceStart")
        Task { @MainActor in
            await startVoiceInputSession()
        }
    }

    @MainActor
    func startVoiceInputSession() async {
        guard !isLoading else { return }
        if speech.isSpeaking {
            await waitForSpeechToFinishThenStartVoice()
            return
        }
        OrbitWakeWordController.shared.suspendForUserSpeech()
        do {
            try await speechInput.startListening(
                onPartial: { partial in
                    inputText = partial
                },
                onCommit: { finalText in
                    inputText = finalText
                    Task { @MainActor in
                        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !isLoading, !trimmed.isEmpty {
                            await sendMessage(fromVoice: true)
                        }
                    }
                },
                silenceAfterSeconds: max(1.1, voiceAutoSendPauseSeconds)
            )
        } catch {
            let msg = error.localizedDescription
            let isPermission = msg.contains("permission") || msg.contains("Privacy") || msg.contains("authorized")
            if isPermission {
                // Open System Settings → Privacy & Security so the user can fix it in one tap
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            presentNotice(msg, tone: .issue)
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        }
    }

    /// Waits until TTS is fully idle, then opens the mic.
    @MainActor
    func waitForSpeechToFinishThenStartVoice() async {
        for _ in 0 ..< 90 {
            if !speech.isSpeaking { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? await Task.sleep(nanoseconds: 550_000_000)
        guard !speech.isSpeaking, !isLoading else { return }
        await startVoiceInputSession()
    }
}
