//
//  ContentView.swift
//  ORBITMac
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var wakeWord = OrbitWakeWordController.shared

    @AppStorage("orbitMac.showRoutingDebug") var showRoutingDebug = false
    @AppStorage("orbitMac.autoSpeakReplies") var autoSpeakReplies = false
    @AppStorage("orbitMac.showMemoryDebug") var showMemoryDebug = false
    @AppStorage("orbitMac.voiceAutoSendPauseSeconds") var voiceAutoSendPauseSeconds = 1.25
    @AppStorage("orbitMac.continuousVoiceMode") var continuousVoiceMode = false
    @AppStorage("orbitMac.listenForHeyOrbit") var listenForHeyOrbit = false
    @AppStorage("orbitMac.wakeWordAutoListen") var wakeWordAutoListen = true
    @AppStorage("orbitMac.listenInLowPowerMode") var listenInLowPowerMode = false
    @AppStorage("orbitMac.useModernSpeech") var useModernSpeech = true
    @AppStorage("orbitMac.allowBargeIn") var allowBargeIn = false
    @AppStorage("orbitMac.showWakeDiagnostics") var showWakeDiagnostics = false
    @AppStorage("orbitMac.proactiveNotifications") var proactiveNotifications = true
    @AppStorage("orbitMac.proactiveVoiceAnnounce") var proactiveVoiceAnnounce = false
    @AppStorage("orbitMac.morningBriefingEnabled") var morningBriefingEnabled = false
    @AppStorage("orbitMac.morningBriefingHour") var morningBriefingHour = 9
    @AppStorage("OrbitGraphClientId") var graphClientIdStorage = ""
    @AppStorage("orbitMac.allowScreenReading") var allowScreenReading = true
    @AppStorage("orbitMac.saveConversationMemory") var saveConversationMemory = true
    @AppStorage("orbitMac.allowContacts") var allowContacts = true
    @AppStorage("orbitMac.allowEmail") var allowEmail = true
    @AppStorage("orbitMac.allowClipboard") var allowClipboard = true

    @ObservedObject var speech = OrbitVoiceKit.shared.speech
    @ObservedObject var speechInput = OrbitVoiceKit.shared.speechInput
    @ObservedObject var graphSession = OrbitGraphSession.shared

    @State var inputText = ""
    @State var responseText = ""
    @State var isLoading = false
    @State var rememberDraft = ""
    @State var savedFacts: [FactRecord] = []

    @State var calendarSummary = ""
    @State var calendarPlaceholder = true
    @State var isLoadingCalendar = false
    @State var calendarLastRefresh: Date?
    @State var calendarExpanded = false
    @State var memoryExpanded = false
    @State var actionsExpanded = false
    @State var microsoft365Expanded = false
    @State var orbitMindExpanded = false
    @State var orbitMindData: OrbitMindData?
    @State var graphPreviewText: String?
    @State var isLoadingGraphPreview = false

    @State var shortcutLibrary: [ShortcutLibraryEntry] = []
    @State var shortcutListFilter = ""
    @State var shortcutManualName = ""
    @State var shortcutPick: ShortcutLibraryEntry?
    @State var isLoadingShortcutList = false
    @State var shortcutListError: String?
    @State var shortcutInputDraft = ""
    @State var newEventTitle = ""
    @State var newEventStart = Date()
    @State var newEventDurationMinutes = 30
    @State var newEventNotes = ""
    @State var pendingShortcut: (name: String, runToken: String, input: String?)?
    @State var pendingCalendarEvent: (title: String, start: Date, end: Date, notes: String?)?
    @State var isSavingCalendarEvent = false
    @State var webURLDraft = ""
    @State var webSearchDraft = ""
    @State var webDraftRequest = ""
    @State var pendingWebAction: PendingWebAction?
    @State var isRunningWebAction = false
    @State var webAgentMode: WebAgentMode = .summarizePage
    @State var commDraftChannel: OrbitCommDraftChannel = .email
    @State var commDraftInstruction = ""
    @State var commDraftContext = ""
    @State var pendingCommDraft: OrbitCommunicationDraftRequest?
    @State var isRunningCommDraft = false
    @State var actionsActiveTool: ActionsActiveTool?
    @State var actionFeedback: String?
    @State var actionFeedbackTone: UserNoticeTone = .neutral

    @State var lastRoute: String = "—"
    @State var lastModel: String = "—"
    @State var lastTierSource: String = "—"
    @State var lastMemoryDebug: MemoryDebugInfo?
    @State var semanticDebugItems: [SemanticMemoryRecord] = []
    @State var semanticManualDraft = ""
    @State var confirmClearSemanticMemory = false
    @State var isClearingSemanticMemory = false
    @State var isLoadingSemanticMemory = false
    @State var clarificationChips: [(label: String, reply: String)] = []
    @State var userNotice: String?
    @State var userNoticeTone: UserNoticeTone = .neutral
    @State var shouldResumeVoiceLoop = false
    @State var suppressAutoVoiceResume = false
    @State var voiceLoopFallbackTask: Task<Void, Never>?

    let sessionID = "orbit-mac"
    let calendarService = CalendarService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ORBITLayout.sectionSpacing) {
                headerRow

                conversationBlock

                composerRow

                if showRoutingDebug {
                    routingDebugPanel
                } else {
                    noticeBanner
                }

                if showWakeDiagnostics {
                    wakeDiagnosticsPanel
                    // Shares the wake-diagnostics toggle rather than adding another switch.
                    reminderTracePanel
                }

                toolsSection
            }
            .padding(ORBITLayout.outerPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrbitMenuBarWindowHookView())
        .onReceive(NotificationCenter.default.publisher(for: .orbitMacChatStateMerge)) { note in
            guard let info = note.userInfo else { return }
            if let reply = info["reply"] as? String {
                responseText = reply
            }
            if let route = info["route"] as? String {
                lastRoute = route
            }
            if let model = info["model"] as? String {
                lastModel = model
            }
            if let tier = info["tierSource"] as? String {
                lastTierSource = tier
            }
            if info["clear_input"] as? Bool == true {
                inputText = ""
            }
            if let notice = info["notice"] as? String {
                userNotice = notice
                if (info["notice_tone"] as? String) == "issue" {
                    userNoticeTone = .issue
                } else {
                    userNoticeTone = .neutral
                }
            }
            if showMemoryDebug {
                Task { await loadSemanticMemoryDebug() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .orbitMacComposerDraftMerge)) { note in
            if let text = note.userInfo?["text"] as? String {
                inputText = text
            }
        }
        .onChange(of: speechInput.isListening) { _, listening in
            OrbitListeningPresence.shared.setUserVoiceListening(listening)
        }
        .onAppear {
            OrbitListeningPresence.shared.setMenuPanelVisible(true)
            OrbitListeningPresence.shared.setUserVoiceListening(speechInput.isListening)
            consumeWakeVoicePendingIfNeeded()
            // Catch replies that arrived while the panel was closed (wake-word path).
            // ContentView's .onReceive is torn down on panel close, so the singleton
            // keeps listening and we sync here on every open.
            let cs = OrbitConversationState.shared
            if !cs.responseText.isEmpty, cs.responseText != responseText {
                responseText = cs.responseText
                if cs.lastRoute != "—" { lastRoute = cs.lastRoute }
                if cs.lastModel != "—" { lastModel = cs.lastModel }
                if cs.lastTierSource != "—" { lastTierSource = cs.lastTierSource }
            }
        }
        .onChange(of: listenForHeyOrbit) { _, _ in
            OrbitWakeWordController.shared.syncFromDefaults()
        }
        .onChange(of: listenInLowPowerMode) { _, _ in
            // Re-evaluate immediately: if the pause was the only thing stopping it, start now.
            OrbitWakeWordController.shared.syncFromDefaults()
        }
        .onChange(of: actionsExpanded) { _, expanded in
            if !expanded {
                resetActionsSectionForClose()
            }
        }
        .onChange(of: showMemoryDebug) { _, enabled in
            if enabled {
                Task { await loadSemanticMemoryDebug() }
            } else {
                lastMemoryDebug = nil
                confirmClearSemanticMemory = false
                semanticManualDraft = ""
                semanticDebugItems = []
            }
        }
        .task {
            await refreshSavedFacts()
            await refreshCalendarSnapshot(silent: true)
        }
        .onDisappear {
            // Sampled before stopListening() clears them: a voice turn only counts as "in
            // flight" if the mic or speech was actually live as the panel closed. Reading
            // OrbitVoiceSession alone was wrong — it can sit in .awaitingFollowup long after
            // a turn is abandoned, so opening and closing the panel woke a sleeping ORBIT.
            let voiceWasLive = speechInput.isListening || speech.isSpeaking

            OrbitListeningPresence.shared.setMenuPanelVisible(false)
            speechInput.stopListening()
            OrbitListeningPresence.shared.setUserVoiceListening(false)

            // Closing the panel must not end an in-flight voice session, but must not start
            // one either. Reopen the mic only when a turn was genuinely live or ORBIT is
            // waiting on a spoken answer.
            let store = OrbitLocalActionPendingStore.shared
            let hasPendingQuestion = voiceWasLive
                || store.folderConfirmPending() != nil
                || store.spellingPendingContext != nil
                || store.noteBodyPending
                || store.filePickPendingPaths() != nil
                || store.documentPickPending() != nil
                || store.terminalCommandPending() != nil
                || store.messageProposalPending() != nil
                || store.deleteProposalPending() != nil
                || store.emptyTrashProposalPending()
            voiceLoopFallbackTask?.cancel()
            if hasPendingQuestion {
                voiceLoopFallbackTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled, !isLoading else { return }
                    await waitForSpeechToFinishThenStartVoice()
                }
            } else {
                voiceLoopFallbackTask = nil
            }
            // Panel closing ends any in-panel voice session. Ensure wake-word resumes so
            // "Hey ORBIT" keeps working even if the mic was suspended for spelling input.
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 440, height: 860)
}
