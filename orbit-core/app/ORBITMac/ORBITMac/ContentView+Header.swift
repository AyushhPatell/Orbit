//
//  ContentView+Header.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("ORBIT")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Menu {
                Section("Voice") {
                    Toggle("Auto-speak replies", isOn: $autoSpeakReplies)
                    Toggle("Hands-free loop", isOn: $continuousVoiceMode)
                    Toggle("Listen for \u{201C}Hey ORBIT\u{201D}", isOn: $listenForHeyOrbit)
                    Toggle("After Hey ORBIT, open mic", isOn: $wakeWordAutoListen)
                    Toggle("Listen in Low Power Mode", isOn: $listenInLowPowerMode)
                    Toggle("New speech engine (en-IN accent model)", isOn: $useModernSpeech)
                    Toggle("Let me interrupt ORBIT while he's speaking", isOn: $allowBargeIn)
                }
                Section("Proactive") {
                    Toggle("Event & reminder alerts", isOn: $proactiveNotifications)
                    Toggle("ORBIT speaks alerts aloud", isOn: $proactiveVoiceAnnounce)
                    Toggle("Daily morning briefing (\(morningBriefingHour):00)", isOn: $morningBriefingEnabled)
                }
                Section("Privacy") {
                    Toggle("Screen reading", isOn: $allowScreenReading)
                    Toggle("Save conversation memory", isOn: $saveConversationMemory)
                    Toggle("Access contacts (FaceTime & Messages)", isOn: $allowContacts)
                    Toggle("Read email", isOn: $allowEmail)
                    Toggle("Clipboard access", isOn: $allowClipboard)
                }
                Section("Advanced") {
                    Toggle("Routing & model details", isOn: $showRoutingDebug)
                    Toggle("Memory debug", isOn: $showMemoryDebug)
                    Toggle("Wake diagnostics", isOn: $showWakeDiagnostics)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .fixedSize()
            .menuStyle(.borderlessButton)
            .help("Voice and advanced options")
        }
    }

    func orbitSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
