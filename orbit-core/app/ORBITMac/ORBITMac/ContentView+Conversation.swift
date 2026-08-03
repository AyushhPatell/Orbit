//
//  ContentView+Conversation.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    // MARK: - Conversation reply block

    var conversationBlock: some View {
        VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
            HStack(alignment: .center, spacing: 10) {
                orbitSectionTitle("Reply")
                Spacer(minLength: 8)
                Button {
                    if speech.isSpeaking {
                        speech.stop()
                    } else {
                        speech.speak(responseText)
                    }
                } label: {
                    Label(
                        speech.isSpeaking ? "Stop" : "Speak",
                        systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !speech.isSpeaking
                )
                .help(speech.isSpeaking ? "Stop speaking" : "Speak the latest reply")
            }

            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if responseText.isEmpty, !isLoading {
                            Text(
                                "ORBIT's reply will show here. Calendar context is added automatically when your question needs it."
                            )
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                        } else {
                            Text(responseText)
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: ORBITLayout.conversationMinHeight)

                if !clarificationChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(clarificationChips, id: \.label) { chip in
                                Button(chip.label) {
                                    clarificationChips = []
                                    inputText = chip.reply
                                    Task { await sendMessage() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.accentColor)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: ORBITLayout.cardCorner, style: .continuous)
                    .fill(.quaternary.opacity(ORBITLayout.cardFillOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: ORBITLayout.cardCorner, style: .continuous)
                    .strokeBorder(.separator.opacity(ORBITLayout.cardStrokeOpacity), lineWidth: 1)
            }
        }
        .onChange(of: autoSpeakReplies) { _, enabled in
            if !enabled {
                speech.stop()
            }
        }
        .onChange(of: speech.isSpeaking) { wasSpeaking, isSpeakingNow in
            if wasSpeaking, !isSpeakingNow, shouldResumeVoiceLoop, !suppressAutoVoiceResume {
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                shouldResumeVoiceLoop = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    guard !speech.isSpeaking else { return }
                    await startVoiceInputSession()
                }
            }
        }
        .onChange(of: continuousVoiceMode) { _, enabled in
            if !enabled {
                shouldResumeVoiceLoop = false
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
            }
        }
    }

    // MARK: - Composer row

    var composerRow: some View {
        VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
            orbitSectionTitle("Message")
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Write to ORBIT\u{2026}", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.quaternary.opacity(0.28))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.separator.opacity(0.4), lineWidth: 1)
                        }
                        .lineLimit(1...6)
                        .disabled(isLoading)

                    Button {
                        Task { await toggleVoiceInput() }
                    } label: {
                        Image(systemName: speechInput.isListening ? "mic.fill" : "mic")
                            .frame(width: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isLoading || speech.isSpeaking)
                    .foregroundStyle(speechInput.isListening ? Color.red : Color.primary)
                    .help(
                        speech.isSpeaking
                            ? "Wait for ORBIT to finish speaking before using the mic."
                            : (speechInput.isListening ? "Stop and send" : "Voice input")
                    )

                    Button {
                        Task { await sendMessage() }
                    } label: {
                        Text("Send")
                            .frame(minWidth: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 4)
                    }
                }
                if speechInput.isListening {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                        Text(
                            continuousVoiceMode
                                ? "Listening \u{2014} pause to send; hands-free continues after replies."
                                : "Listening \u{2014} pause to send, or tap the mic to stop."
                        )
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: ORBITLayout.cardCorner, style: .continuous)
                    .fill(.quaternary.opacity(ORBITLayout.cardFillOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: ORBITLayout.cardCorner, style: .continuous)
                    .strokeBorder(.separator.opacity(ORBITLayout.cardStrokeOpacity), lineWidth: 1)
            }
        }
    }
}
