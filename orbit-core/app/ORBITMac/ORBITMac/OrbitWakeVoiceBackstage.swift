//
//  OrbitWakeVoiceBackstage.swift
//  ORBITMac
//
//  Runs “Hey ORBIT” → mic → /chat without opening the menu bar window.
//  Posts `orbitMacChatStateMerge` so `ContentView` stays in sync when opened later.
//

import AppKit
import Foundation

@MainActor
final class OrbitWakeVoiceBackstage {
    static let shared = OrbitWakeVoiceBackstage()

    private let sessionID = "orbit-mac"
    private let calendarService = CalendarService.shared
    private var calendarSummary = ""
    private var calendarPlaceholder = true
    private var voiceLoopFallbackTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    func bootstrap() {
        guard wakeObserver == nil else { return }
        wakeObserver = NotificationCenter.default.addObserver(
            forName: .orbitWakeWordDetected,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleWakeNotification(note)
            }
        }
    }

    private func handleWakeNotification(_ note: Notification) {
        let startVoice = (note.userInfo?["startVoice"] as? Bool) ?? true
        guard startVoice else { return }
        // If we're already capturing user speech, ignore the re-trigger.
        // Concurrent startListening calls race on the same AVAudioEngine and crash.
        let speechInput = OrbitVoiceKit.shared.speechInput
        // Reject re-triggers only while a turn is actively committing or in-flight to the LLM
        // (`.committing`/`.thinking`) — concurrent startListening calls race the AVAudioEngine
        // and crash. A leftover `.awaitingFollowup`/`.ending`/`.idle` is fine; reset() clears it.
        switch OrbitVoiceSession.shared.state {
        case .committing, .thinking, .responding: return
        default: break
        }
        guard !speechInput.isListening else { return }
        OrbitVoiceSession.shared.reset()
        OrbitVoiceSession.shared.transition(to: .wakeArmed)
        OrbitVoiceSession.shared.transition(to: .wakeTriggered)
        // Clear stale spelling state and wake card from a previous session so the wake phrase
        // itself can't be mistaken for a spelled folder name in handlePendingLocalActions.
        OrbitLocalActionPendingStore.shared.clearSpellingState()
        OrbitListeningPresence.shared.clearWakeVoiceCard()
        let askedAQuestion = (note.userInfo?["presenceQuestion"] as? Bool) ?? false
        Task { await self.startWakeCapturePipeline(answeringPresenceQuestion: askedAQuestion) }
    }

    private func startWakeCapturePipeline(answeringPresenceQuestion: Bool = false) async {
        // "Are you there ORBIT?" gets an answer before the mic opens. startVoiceInputSession
        // already waits for speech to finish before listening, so this reads as one motion:
        // ORBIT replies, then is listening — no gap the user has to guess at.
        if answeringPresenceQuestion {
            OrbitVoiceKit.shared.speech.speak(OrbitWakeAcknowledgement.line())
        }
        await startVoiceInputSession()
    }

    // MARK: - Proactive followup voice entry point

    /// Called by OrbitProactiveNotifier after speaking a followup question.
    /// Opens interactive mic WITHOUT clearing the wake card (which shows the question).
    func startListeningForFollowupResponse() async {
        let speechInput = OrbitVoiceKit.shared.speechInput
        switch OrbitVoiceSession.shared.state {
        case .committing, .thinking: return
        default: break
        }
        guard !speechInput.isListening else { return }
        // Third entry point (proactive notifier). Resets so startVoiceInputSession can legally
        // transition to .listening; Phase 3 gives this a dedicated proactive edge.
        OrbitVoiceSession.shared.reset()
        await startVoiceInputSession()
    }

    // MARK: - Voice (mirrors ContentView essentials)

    private func startVoiceInputSession() async {
        let speech = OrbitVoiceKit.shared.speech
        let speechInput = OrbitVoiceKit.shared.speechInput
        if case .thinking = OrbitVoiceSession.shared.state { return }
        guard !speechInput.isListening else { return }
        if speech.isSpeaking {
            await waitForSpeechToFinishThenStartVoice()
            return
        }
        OrbitWakeWordController.shared.suspendForUserSpeech()
        let pauseSeconds = max(1.1, UserDefaults.standard.double(forKey: "orbitMac.voiceAutoSendPauseSeconds").nonZeroOrDefault(1.25))
        // Enter .listening before opening the engine so a throw transitions .listening → .ending(.error).
        OrbitVoiceSession.shared.transition(to: .listening)
        do {
            try await speechInput.startListening(
                onPartial: { partial in
                    NotificationCenter.default.post(
                        name: .orbitMacComposerDraftMerge,
                        object: nil,
                        userInfo: ["text": partial]
                    )
                },
                onCommit: { finalText in
                    Task { @MainActor in
                        NotificationCenter.default.post(
                            name: .orbitMacComposerDraftMerge,
                            object: nil,
                            userInfo: ["text": finalText]
                        )
                        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard case .listening = OrbitVoiceSession.shared.state, !trimmed.isEmpty else { return }
                        OrbitVoiceSession.shared.transition(to: .committing(trimmed))
                        await self.sendWakeVoiceMessage(trimmed)
                    }
                },
                silenceAfterSeconds: pauseSeconds
            )
        } catch {
            OrbitVoiceSession.shared.transition(to: .ending(.error))
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        }
    }

    private func waitForSpeechToFinishThenStartVoice() async {
        let speech = OrbitVoiceKit.shared.speech
        for _ in 0 ..< 90 {
            if !speech.isSpeaking { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try? await Task.sleep(nanoseconds: 550_000_000)
        guard !speech.isSpeaking else { return }
        if case .thinking = OrbitVoiceSession.shared.state { return }
        await startVoiceInputSession()
    }

    private func sendWakeVoiceMessage(_ trimmed: String) async {
        let speech = OrbitVoiceKit.shared.speech
        let speechInput = OrbitVoiceKit.shared.speechInput
        OrbitListeningPresence.shared.clearWakeVoiceCard()
        OrbitListeningPresence.shared.hideConstellation()
        var localControl = await OrbitMacControlCenter.performIfCommand(trimmed)
        // Safety net: if a note-body clarification was pending but performIfCommand returned
        // handled:false (e.g. the wake phrase leaked into the transcript confusing the intent
        // matcher), retry once — the pending state is unchanged and the second call will catch it.
        if !localControl.handled, OrbitLocalActionPendingStore.shared.noteBodyPending {
            localControl = await OrbitMacControlCenter.performIfCommand(trimmed)
        }
        if localControl.handled {
            // List reminders: route to EventKit locally
            if localControl.reply == "__orbit_list_reminders__" {
                await OrbitReminderService.shared.requestAccessIfNeeded()
                let listReply = await OrbitReminderService.shared.listUpcoming()
                OrbitVoiceSession.shared.transition(to: .responding(
                    ResponsePlan(willResume: false, lastReplyWasQuestion: false)
                ))
                speechInput.stopListening()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                NotificationCenter.default.post(name: .orbitMacChatStateMerge, object: nil,
                    userInfo: ["reply": listReply, "route": "reminder-list", "model": "on-device",
                               "tierSource": "on-device", "clear_input": true])
                NotificationCenter.default.post(name: .orbitMacComposerDraftMerge, object: nil, userInfo: ["text": ""])
                let autoSpeak = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
                if autoSpeak { speech.speak(listReply) }
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            // List events: route to CalendarService locally
            if localControl.reply == "__orbit_list_events__" {
                speechInput.stopListening()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                let eventsReply: String
                do {
                    try await calendarService.ensureAccess()
                    let text = try calendarService.upcomingEventsText(days: 7)
                    eventsReply = text.isEmpty ? "No upcoming events in the next week." : text
                } catch {
                    eventsReply = "I couldn\u{2019}t access your calendar: \(error.localizedDescription)"
                }
                OrbitVoiceSession.shared.transition(to: .responding(
                    ResponsePlan(willResume: false, lastReplyWasQuestion: false)
                ))
                NotificationCenter.default.post(name: .orbitMacChatStateMerge, object: nil,
                    userInfo: ["reply": eventsReply, "route": "calendar-list", "model": "on-device",
                               "tierSource": "on-device", "clear_input": true])
                NotificationCenter.default.post(name: .orbitMacComposerDraftMerge, object: nil, userInfo: ["text": ""])
                let autoSpeak = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
                if autoSpeak { speech.speak(eventsReply) }
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            // Document summarization: the reply contains extracted text that needs LLM processing.
            // Re-route it through the LLM instead of speaking the raw extraction prompt.
            if let reply = localControl.reply, reply.hasPrefix("__orbit_doc_llm__") {
                let llmMessage = String(reply.dropFirst("__orbit_doc_llm__".count))
                speechInput.stopListening()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                OrbitListeningPresence.shared.presentWakeVoiceCard(from: "Reading document\u{2026}", ttlSeconds: 30)
                let autoSpeakReplies = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
                if autoSpeakReplies { speech.speak("Let me read through that.") }
                OrbitVoiceSession.shared.transition(to: .thinking(llmMessage))
                do {
                    let showMemoryDebug = UserDefaults.standard.bool(forKey: "orbitMac.showMemoryDebug")
                    let clock = OrbitClientClock.snapshotForAPI()
                    let result = try await OrbitAPI().chat(
                        sessionID: sessionID, message: llmMessage, routeHint: .local,
                        toolingContext: nil, clientLocalISO8601: clock.iso8601,
                        clientTimeZoneId: clock.timeZoneId, includeMemoryDebug: showMemoryDebug ? true : nil
                    )
                    let docReply = Self.sanitizeReply(result.reply)
                    OrbitVoiceSession.shared.transition(to: .responding(
                        ResponsePlan(willResume: false, lastReplyWasQuestion: false)
                    ))
                    OrbitListeningPresence.shared.presentWakeVoiceCard(from: docReply, title: "Summary", ttlSeconds: 120)
                    NotificationCenter.default.post(name: .orbitMacChatStateMerge, object: nil,
                        userInfo: ["reply": docReply, "route": result.route, "model": result.model,
                                   "tierSource": "on-device", "clear_input": true])
                    NotificationCenter.default.post(name: .orbitMacComposerDraftMerge, object: nil, userInfo: ["text": ""])
                    if autoSpeakReplies {
                        let isNonLatin = Self.isNonLatinHeavy(docReply)
                        let spoken = isNonLatin ? "The result is on your screen." : docReply
                        speech.speak(spoken)
                    }
                    OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
                } catch {
                    OrbitVoiceSession.shared.transition(to: .ending(.error))
                    NotificationCenter.default.post(name: .orbitMacChatStateMerge, object: nil,
                        userInfo: ["reply": "", "route": "—", "model": "—", "tierSource": "—",
                                   "notice": "Document summary failed: \(error.localizedDescription)",
                                   "notice_tone": "issue"])
                }
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }

            // Terminal commands (screen lock, etc.) must silence the mic — match ContentView logic.
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil

            // Wipe any pending clarification so stale broker/store state can't be
            // triggered by the next utterance after screen unlock.
            if !localControl.appendWakeConversationPrompt {
                OrbitClarificationBroker.shared.clearPending()
                OrbitLocalActionPendingStore.shared.clearNoteBodyPending()
            }

            let autoSpeakReplies = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
            let actionReply = localControl.reply ?? "Done."
            let suffix = (localControl.appendWakeConversationPrompt && !localControl.isClarificationQuestion)
                ? " \(Self.rotatingClosingSuffix())" : ""
            let reply = "\(actionReply)\(suffix)"
            let replyIsQuestion = reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            let didShowConstellation: Bool
            if let constellation = parseConstellationItems(from: actionReply) {
                OrbitListeningPresence.shared.showConstellation(
                    items: constellation.items,
                    totalFound: constellation.totalFound
                )
                OrbitListeningPresence.shared.clearWakeVoiceCard()
                didShowConstellation = true
            } else {
                OrbitListeningPresence.shared.hideConstellation()
                didShowConstellation = false
            }
            // Show a compact wake card for replies that need the user to respond (spelling prompt,
            // pending confirms, clarification questions). Clear for all other cases.
            let spellingNowPending = OrbitLocalActionPendingStore.shared.spellingPendingContext != nil
            let folderConfirmNowPending = OrbitLocalActionPendingStore.shared.folderConfirmPending() != nil
            let noteBodyNowPending = OrbitLocalActionPendingStore.shared.noteBodyPending
            let termCommandNowPending = OrbitLocalActionPendingStore.shared.terminalCommandPending() != nil
            let docPickNowPending = OrbitLocalActionPendingStore.shared.documentPickPending() != nil
            // File pick was missing here: after "find my resume" listed numbered matches the mic
            // never reopened, so "open 1" / "cancel" went to the idle wake listener and did nothing.
            let filePickNowPending = OrbitLocalActionPendingStore.shared.filePickPendingPaths() != nil
            let messageNowPending = OrbitLocalActionPendingStore.shared.messageProposalPending() != nil
            let deleteNowPending = OrbitLocalActionPendingStore.shared.deleteProposalPending() != nil
            let emptyTrashNowPending = OrbitLocalActionPendingStore.shared.emptyTrashProposalPending()
            let needsVoiceResponse = spellingNowPending || folderConfirmNowPending || noteBodyNowPending
                || termCommandNowPending || docPickNowPending || filePickNowPending
                || messageNowPending || deleteNowPending || emptyTrashNowPending
            if needsVoiceResponse && !didShowConstellation {
                // Keep a compact card visible so the user knows ORBIT is waiting for their response.
                OrbitListeningPresence.shared.presentWakeVoiceCard(from: actionReply, ttlSeconds: 120)
            } else if let notice = localControl.notice, !didShowConstellation {
                // Informational replies (e.g. weather with emoji) — show the enriched version in the
                // floating HUD for a few seconds so the user can glance at it without opening the panel.
                OrbitListeningPresence.shared.presentWakeVoiceCard(from: notice, ttlSeconds: 15)
            } else {
                OrbitListeningPresence.shared.clearWakeVoiceCard()
            }
            // Resume the mic for one follow-up turn unless this was a terminal/silencing command
            // (no conversation prompt). Clarification prompts always reopen — the user must respond.
            let willResume = localControl.appendWakeConversationPrompt || needsVoiceResponse
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: replyIsQuestion)
            ))
            var chatMerge: [String: Any] = [
                "reply": reply,
                "route": "local-action",
                "model": "macos-control",
                "tierSource": "on-device",
                "clear_input": true,
            ]
            if let notice = localControl.notice { chatMerge["notice"] = notice }
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: chatMerge
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if autoSpeakReplies {
                let cleanedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                // When constellation is showing a list, speak a short summary instead
                // of reading every filename — the user can see them on screen.
                let spokenReply: String
                if didShowConstellation, let count = parseConstellationItems(from: actionReply)?.totalFound, count > 2 {
                    spokenReply = "I found \(count) results. Take a look and tell me which one."
                } else {
                    spokenReply = cleanedReply
                }
                if willResume, spokenReply.isEmpty {
                    await waitForSpeechToFinishThenStartVoice()
                } else {
                    if willResume {
                        scheduleVoiceLoopFallback(for: spokenReply)
                    }
                    speech.speak(spokenReply)
                }
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }
        if OrbitVoiceIntentHelpers.isSessionStopCommand(trimmed) {
            OrbitVoiceSession.shared.transition(to: .ending(.stopCommand))
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            self.voiceLoopFallbackTask?.cancel()
            self.voiceLoopFallbackTask = nil
            speechInput.stopListening(commitIfPossible: false)
            OrbitWakeWordController.shared.suspendForUserSpeech()
            speech.stop()
            speech.speak(OrbitVoicePartingLine.spokenLine(for: trimmed))
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech(delay: 2.8)
            return
        }

        // Gratitude close — "thank you so much, I appreciate it" without a follow-up task.
        // Respond briefly and end the voice session gracefully (no "Is there anything else?").
        if OrbitVoiceIntentHelpers.isGratitudeClose(trimmed, lastReplyWasQuestion: OrbitVoiceSession.shared.lastReplyWasQuestion) {
            OrbitVoiceSession.shared.transition(to: .ending(.gratitude))
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            let autoSpeakReplies = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
            let replyText = Self.contextualPartingLine()
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": replyText,
                    "route": "local-gratitude",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if autoSpeakReplies { speech.speak(replyText) }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        // "Repeat that" — replay the last thing ORBIT said.
        if OrbitVoiceIntentHelpers.isRepeatIntent(trimmed) {
            if let last = speech.lastSpokenText, !last.isEmpty {
                speechInput.stopListening()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
                OrbitVoiceSession.shared.transition(to: .responding(
                    ResponsePlan(willResume: willResume, lastReplyWasQuestion: OrbitVoiceSession.shared.lastReplyWasQuestion)
                ))
                NotificationCenter.default.post(name: .orbitMacChatStateMerge, object: nil,
                    userInfo: ["reply": last, "route": "repeat", "model": "on-device",
                               "tierSource": "on-device", "clear_input": true])
                NotificationCenter.default.post(name: .orbitMacComposerDraftMerge, object: nil, userInfo: ["text": ""])
                if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                    if willResume { scheduleVoiceLoopFallback(for: last) }
                    speech.speak(last)
                } else if willResume {
                    await startVoiceInputSession()
                }
                OrbitVoiceSession.shared.transition(to: willResume ? .awaitingFollowup : .ending(.displayOnlyResult))
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            // Nothing spoken yet — fall through to LLM which will say something natural
        }

        // Reminder / calendar broker — must run here so EventKit is actually called.
        // Without this block, reminder intents fall through to the LLM which generates
        // a fake "Done" reply without saving anything.
        let reminderOutcome = OrbitClarificationBroker.shared.process(trimmed)
        switch reminderOutcome {
        case .none:
            break

        case .ask(let question):
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            // Numbered options (e.g. calendar/reminder/skip) → constellation stars.
            // Plain open-ended questions → compact wake card.
            let spokenText: String
            if let options = parseAskAsConstellationOptions(from: question) {
                OrbitListeningPresence.shared.showConstellation(items: options, totalFound: options.count)
                OrbitListeningPresence.shared.clearWakeVoiceCard()
                // Speak only the preamble line, not the numbered list.
                spokenText = question.components(separatedBy: "\n")
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? question
            } else {
                OrbitListeningPresence.shared.hideConstellation()
                OrbitListeningPresence.shared.presentWakeVoiceCard(
                    from: question,
                    ttlSeconds: wakeCardTTLSeconds(for: question)
                )
                spokenText = question
            }
            let autoSpeak = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
            let contVoice = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            // Auto-reopen mic after clarification questions (the spoken preamble always ends with "?").
            let willResume = contVoice || (autoSpeak && spokenText.hasSuffix("?"))
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: true)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": question,
                    "route": "reminder-clarify",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if autoSpeak {
                if willResume { scheduleVoiceLoopFallback(for: spokenText) }
                speech.speak(spokenText)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .createReminder(let title, let dueDate):
            await OrbitReminderService.shared.requestAccessIfNeeded()
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            let createReply: String
            do { createReply = try OrbitReminderService.shared.createReminder(title: title, dueDate: dueDate) }
            catch { createReply = "Sorry, I couldn\u{2019}t save the reminder: \(error.localizedDescription)" }
            let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": createReply,
                    "route": "reminder-create",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                if willResume { scheduleVoiceLoopFallback(for: createReply) }
                speech.speak(createReply)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .listReminders:
            await OrbitReminderService.shared.requestAccessIfNeeded()
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            let listReply = await OrbitReminderService.shared.listUpcoming()
            let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": listReply,
                    "route": "reminder-list",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                if willResume { scheduleVoiceLoopFallback(for: listReply) }
                speech.speak(listReply)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .completeReminder(let query):
            await OrbitReminderService.shared.requestAccessIfNeeded()
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            let completeReply = await OrbitReminderService.shared.completeReminder(matching: query)
            let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": completeReply,
                    "route": "reminder-complete",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                if willResume { scheduleVoiceLoopFallback(for: completeReply) }
                speech.speak(completeReply)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .askWithChips(let question, _):
            // Chips are UI-only (shown in ContentView). Voice users answer naturally and
            // the broker's pending state resolves their response.
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            OrbitListeningPresence.shared.hideConstellation()
            OrbitListeningPresence.shared.presentWakeVoiceCard(from: question, ttlSeconds: wakeCardTTLSeconds(for: question))
            let autoSpeak = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
            let contVoice = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            let willResume = contVoice || (autoSpeak && question.hasSuffix("?"))
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: true)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": question,
                    "route": "reminder-clarify",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if autoSpeak {
                if willResume { scheduleVoiceLoopFallback(for: question) }
                speech.speak(question)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .deleteReminder(let query):
            await OrbitReminderService.shared.requestAccessIfNeeded()
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            let deleteReply = await OrbitReminderService.shared.deleteReminder(matching: query)
            let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": deleteReply,
                    "route": "reminder-delete",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                if willResume { scheduleVoiceLoopFallback(for: deleteReply) }
                speech.speak(deleteReply)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .createCalendarEvent(let title, let start, let end):
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            let calReply: String
            do {
                let calName = try await calendarService.addTimedEvent(title: title, start: start, end: end)
                let when = OrbitClarificationBroker.formatEventStart(start)
                let dur = Int(end.timeIntervalSince(start) / 60)
                let durStr = dur >= 60
                    ? (dur % 60 == 0 ? "\(dur / 60)h" : "\(dur / 60)h \(dur % 60)m")
                    : "\(dur)m"
                calReply = "Done \u{2014} \u{201C}\(title)\u{201D} added to \(calName) \(when) (\(durStr))."
            } catch {
                calReply = "Sorry, I couldn\u{2019}t create the event: \(error.localizedDescription)"
            }
            let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": calReply,
                    "route": "calendar-create",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                if willResume { scheduleVoiceLoopFallback(for: calReply) }
                speech.speak(calReply)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .createBoth(let calTitle, let start, let end, let remTitle, let remDue):
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            await OrbitReminderService.shared.requestAccessIfNeeded()
            var parts: [String] = []
            do {
                let calName = try await calendarService.addTimedEvent(title: calTitle, start: start, end: end)
                let when = OrbitClarificationBroker.formatEventStart(start)
                parts.append("\u{201C}\(calTitle)\u{201D} added to \(calName) \(when)")
            } catch {
                parts.append("couldn\u{2019}t create calendar event: \(error.localizedDescription)")
            }
            do { parts.append(try OrbitReminderService.shared.createReminder(title: remTitle, dueDate: remDue)) }
            catch { parts.append("couldn\u{2019}t save reminder: \(error.localizedDescription)") }
            let bothReply = parts.joined(separator: ". ")
            let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": bothReply,
                    "route": "calendar-reminder-create",
                    "model": "on-device",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(name: .orbitMacComposerDraftMerge, object: nil, userInfo: ["text": ""])
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                if willResume { scheduleVoiceLoopFallback(for: bothReply) }
                speech.speak(bothReply)
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        let commOutcome = OrbitCommunicationDraftIntentBroker.shared.process(trimmed)
        switch commOutcome {
        case .none:
            break
        case .message(let msg):
            OrbitListeningPresence.shared.hideConstellation()
            OrbitListeningPresence.shared.presentWakeVoiceCard(
                from: msg,
                ttlSeconds: wakeCardTTLSeconds(for: msg)
            )
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            // Confirmation prompts always reopen the mic — user must say "yes" or "cancel".
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: true, lastReplyWasQuestion: true)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": msg,
                    "route": "comm-draft-pending",
                    "model": "macos-comm",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                scheduleVoiceLoopFallback(for: msg)
                speech.speak(msg)
            } else {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .run(let req):
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            OrbitVoiceSession.shared.transition(to: .thinking(trimmed))
            do {
                let showMemoryDebug = UserDefaults.standard.bool(forKey: "orbitMac.showMemoryDebug")
                let run = try await OrbitCommunicationDraftRunner.run(req, sessionID: sessionID, includeMemoryDebug: showMemoryDebug)
                let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
                OrbitVoiceSession.shared.transition(to: .responding(
                    ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
                ))
                NotificationCenter.default.post(
                    name: .orbitMacChatStateMerge,
                    object: nil,
                    userInfo: [
                        "reply": run.reply.trimmingCharacters(in: .whitespacesAndNewlines),
                        "route": run.route,
                        "model": run.model,
                        "tierSource": "on-device",
                        "clear_input": true,
                    ]
                )
                NotificationCenter.default.post(
                    name: .orbitMacComposerDraftMerge,
                    object: nil,
                    userInfo: ["text": ""]
                )
                if willResume {
                    OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
                } else {
                    OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
                }
                if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                    if willResume { scheduleVoiceLoopFallback(for: run.reply.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    speech.speak(run.reply.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if willResume {
                    await startVoiceInputSession()
                }
            } catch {
                OrbitVoiceSession.shared.transition(to: .ending(.error))
                NotificationCenter.default.post(
                    name: .orbitMacChatStateMerge,
                    object: nil,
                    userInfo: [
                        "reply": "",
                        "route": "comm-draft",
                        "model": "macos-comm",
                        "tierSource": "on-device",
                        "notice": "Communication draft failed: \(error.localizedDescription)",
                        "notice_tone": "issue",
                        "clear_input": true,
                    ]
                )
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        let webOutcome = OrbitWebActionIntentBroker.shared.process(trimmed)
        switch webOutcome {
        case .none:
            break
        case .message(let msg):
            OrbitListeningPresence.shared.hideConstellation()
            OrbitListeningPresence.shared.presentWakeVoiceCard(
                from: msg,
                ttlSeconds: wakeCardTTLSeconds(for: msg)
            )
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            // Confirmation prompts always reopen the mic — user must say "yes" or "cancel".
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: true, lastReplyWasQuestion: true)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": msg,
                    "route": "web-action-pending",
                    "model": "macos-web",
                    "tierSource": "on-device",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                scheduleVoiceLoopFallback(for: msg)
                speech.speak(msg)
            } else {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .run(let intent):
            OrbitListeningPresence.shared.clearWakeVoiceCard()
            OrbitListeningPresence.shared.hideConstellation()
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            OrbitVoiceSession.shared.transition(to: .thinking(trimmed))
            do {
                let showMemoryDebug = UserDefaults.standard.bool(forKey: "orbitMac.showMemoryDebug")
                let run = try await OrbitWebActionRunner.run(intent, sessionID: sessionID, includeMemoryDebug: showMemoryDebug)
                let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
                OrbitVoiceSession.shared.transition(to: .responding(
                    ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
                ))
                NotificationCenter.default.post(
                    name: .orbitMacChatStateMerge,
                    object: nil,
                    userInfo: [
                        "reply": run.reply.trimmingCharacters(in: .whitespacesAndNewlines),
                        "route": run.route,
                        "model": run.model,
                        "tierSource": "on-device",
                        "clear_input": true,
                    ]
                )
                NotificationCenter.default.post(
                    name: .orbitMacComposerDraftMerge,
                    object: nil,
                    userInfo: ["text": ""]
                )
                if willResume {
                    OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
                } else {
                    OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
                }
                if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                    if willResume { scheduleVoiceLoopFallback(for: run.reply.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    speech.speak(run.reply.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if willResume {
                    await startVoiceInputSession()
                }
            } catch {
                OrbitVoiceSession.shared.transition(to: .ending(.error))
                NotificationCenter.default.post(
                    name: .orbitMacChatStateMerge,
                    object: nil,
                    userInfo: [
                        "reply": "",
                        "route": "web-action",
                        "model": "macos-web",
                        "tierSource": "on-device",
                        "notice": "Web action failed: \(error.localizedDescription)",
                        "notice_tone": "issue",
                        "clear_input": true,
                    ]
                )
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        let clipboardPrep = OrbitClipboardIntelligence.prepareUserMessageForChat(trimmed)
        let messageForChat: String
        let forceLocalFromClipboard: Bool
        switch clipboardPrep {
        case .clipboardEmpty:
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            let notice = "Clipboard has no plain text to use. Copy some text first (⌘C), then try again."
            let willResume = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": "",
                    "route": "—",
                    "model": "—",
                    "tierSource": "—",
                    "notice": notice,
                    "notice_tone": "issue",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if willResume {
                OrbitVoiceSession.shared.transition(to: .awaitingFollowup)
            } else {
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            }
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                speech.speak("Copy some text to the clipboard first, then ask again.")
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .clipboardDisabled:
            speechInput.stopListening()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            let disabledNotice = "Clipboard access is turned off in ORBIT\u{2019}s privacy settings. You can enable it in the gear menu."
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: false, lastReplyWasQuestion: false)
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": "",
                    "route": "—",
                    "model": "—",
                    "tierSource": "—",
                    "notice": disabledNotice,
                    "notice_tone": "issue",
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") {
                speech.speak("Clipboard access is turned off in my privacy settings.")
            }
            OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .useAsIs(let s):
            messageForChat = s
            forceLocalFromClipboard = false
        case .clipboardExpanded(let s):
            messageForChat = s
            forceLocalFromClipboard = true
        }

        OrbitListeningPresence.shared.clearWakeVoiceCard()
        OrbitListeningPresence.shared.hideConstellation()
        speechInput.stopListening()
        voiceLoopFallbackTask?.cancel()
        voiceLoopFallbackTask = nil

        // Screen context injection: captureForContext() calls SCShareableContent.current only
        // (no legacy CGPreflightScreenCaptureAccess/CGRequestScreenCaptureAccess calls).
        var screenAugmentedMessage = messageForChat
        if !forceLocalFromClipboard, OrbitVoiceIntentHelpers.isScreenContextQuery(trimmed),
           OrbitMacControlCenter.privacyToggleEnabled("orbitMac.allowScreenReading") {
            if let sc = await OrbitScreenReader.shared.captureForContext() {
                screenAugmentedMessage = """
                [Screen content from \(sc.appName) — captured via OCR]
                IMPORTANT: This text was extracted from the screen via OCR without visual layout. \
                Multiple sections (ads, sidebars, main content) appear as flat text. Be careful to:
                - Distinguish the PRIMARY content from ads, sponsored listings, or unrelated sections
                - If there are multiple products/items visible, focus on the one the user is actively viewing (usually the largest/central one)
                - State specific numbers (prices, quantities, ratings) only when clearly tied to the main content
                - If details are ambiguous, say so rather than guessing

                \(sc.text)
                [/Screen content]

                \(messageForChat)
                """
            } else {
                // Capture failed — likely macOS showed a permission dialog that blocked the call.
                // Don't open Settings (the system dialog handles that). Just ask to try again.
                let msg = "Screen capture didn\u{2019}t work this time. If you saw a system dialog, dismiss it and try again. Make sure ORBITMac is enabled in Screen Recording settings."
                OrbitVoiceSession.shared.transition(to: .responding(
                    ResponsePlan(willResume: false, lastReplyWasQuestion: false)
                ))
                NotificationCenter.default.post(
                    name: .orbitMacChatStateMerge,
                    object: nil,
                    userInfo: ["reply": msg, "route": "screen-reader", "model": "on-device", "tierSource": "on-device", "clear_input": true]
                )
                NotificationCenter.default.post(name: .orbitMacComposerDraftMerge, object: nil, userInfo: ["text": ""])
                if UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies") { speech.speak("Screen capture didn\u{2019}t work. Dismiss the system dialog if you see one, then try again.") }
                OrbitVoiceSession.shared.transition(to: .ending(.displayOnlyResult))
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            // else: transient failure (no display, empty OCR) — send without screen context.
        }

        OrbitVoiceSession.shared.transition(to: .thinking(trimmed))

        // Log missed intent — this text wasn't handled by any local handler, broker,
        // or clipboard action, so it's going to the LLM. Tracking these reveals
        // which phrasings ORBIT needs new triggers for.
        if !forceLocalFromClipboard {
            OrbitFailureTelemetry.shared.logMissedIntent(trimmed, route: "llm-fallback")
        }

        let continuousVoiceMode = UserDefaults.standard.bool(forKey: "orbitMac.continuousVoiceMode")
        let autoSpeakReplies = UserDefaults.standard.bool(forKey: "orbitMac.autoSpeakReplies")
        let showMemoryDebug = UserDefaults.standard.bool(forKey: "orbitMac.showMemoryDebug")

        do {
            if forceLocalFromClipboard {
                OrbitRouteClassifier.lastSource = .keyword
            }
            let hint = forceLocalFromClipboard ? OrbitRoute.local : await OrbitRouteClassifier.classify(messageForChat)
            let needsCalendar = !forceLocalFromClipboard && Self.messageNeedsCalendarContext(messageForChat)
            let routeHint: OrbitRoute = (hint == .tooling || needsCalendar) ? .tooling : hint
            if routeHint == .tooling {
                await refreshCalendarSnapshot(silent: true)
            }
            let toolingSnapshot: String? =
                (routeHint == .tooling && calendarReadyForTooling) ? calendarSummary : nil
            let clock = OrbitClientClock.snapshotForAPI()
            let rawResult = try await OrbitAPI().chat(
                sessionID: sessionID,
                message: screenAugmentedMessage,
                routeHint: routeHint,
                toolingContext: toolingSnapshot,
                clientLocalISO8601: clock.iso8601,
                clientTimeZoneId: clock.timeZoneId,
                includeMemoryDebug: showMemoryDebug ? true : nil
            )
            // Brain tool-calling: if the server wants to run a tool, dispatch it and resume.
            let result: ChatResponse
            if let toolCalls = rawResult.tool_calls, !toolCalls.isEmpty {
                let toolResults = await OrbitToolDispatcher.dispatchAll(toolCalls)
                result = try await OrbitAPI().chatToolResult(
                    sessionID: sessionID,
                    originalMessage: screenAugmentedMessage,
                    results: toolResults,
                    clientLocalISO8601: clock.iso8601,
                    clientTimeZoneId: clock.timeZoneId
                )
            } else {
                result = rawResult
            }
            let reply = Self.sanitizeReply(result.reply)
            let cleanedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            // Non-Latin text (translation) is display-only and ends the session — never resume.
            let isNonLatin = Self.isNonLatinHeavy(cleanedReply)
            // A brain tool may have left a pick/confirm pending (find_file list, folder
            // confirm, spelling). The user must answer by voice ("open 1", "cancel"),
            // so the mic MUST reopen — otherwise they're talking to the idle wake listener.
            let store = OrbitLocalActionPendingStore.shared
            let pendingNeedsVoice = store.filePickPendingPaths() != nil
                || store.documentPickPending() != nil
                || store.folderConfirmPending() != nil
                || store.terminalCommandPending() != nil
                || store.spellingPendingContext != nil
            // Auto-reopen mic after any clarification question from the brain — unless ORBIT just
            // said goodbye. A farewell overrides continuous voice mode: "okay, I'm putting this
            // here for now" followed by the listening orb reappearing is the behaviour Ayush
            // reported, and it makes ORBIT look like it didn't understand its own answer.
            let saidGoodbye = OrbitVoiceIntentHelpers.isFarewellReply(reply)
            let willResume = !isNonLatin && !saidGoodbye
                && (pendingNeedsVoice || continuousVoiceMode || (autoSpeakReplies && reply.hasSuffix("?")))
            if saidGoodbye {
                // Hand the mic back to the wake word rather than leaving it half-open.
                OrbitWakeWordController.shared.suspendForUserSpeech()
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech(delay: 2.8)
            }
            OrbitVoiceSession.shared.transition(to: .responding(
                ResponsePlan(willResume: willResume, lastReplyWasQuestion: reply.hasSuffix("?"))
            ))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": reply,
                    "route": result.route,
                    "model": result.model,
                    "tierSource": OrbitRouteClassifier.lastSource.rawValue,
                    "clear_input": true,
                ]
            )
            NotificationCenter.default.post(
                name: .orbitMacComposerDraftMerge,
                object: nil,
                userInfo: ["text": ""]
            )
            OrbitVoiceSession.shared.transition(to: willResume ? .awaitingFollowup : .ending(.displayOnlyResult))
            if isNonLatin {
                // Non-Latin text (translation): show in the floating HUD card and end the
                // voice session — the user needs to read, not speak.
                OrbitListeningPresence.shared.presentWakeVoiceCard(from: cleanedReply, ttlSeconds: 30)
                if autoSpeakReplies { speech.speak("The result is on your screen.") }
            } else if autoSpeakReplies {
                // A question from the brain is a clarification, and clarifications have always
                // been shown as a banner with the question written out — deliberately, so there
                // is no ambiguity about what is being asked. That banner lived only in the local
                // `.ask` branch, so moving clarifications to the brain (Phases 3.11/3.14) silently
                // dropped it and left a bare listening orb. Restored here.
                if cleanedReply.hasSuffix("?") {
                    OrbitListeningPresence.shared.hideConstellation()
                    OrbitListeningPresence.shared.presentWakeVoiceCard(
                        from: cleanedReply,
                        ttlSeconds: wakeCardTTLSeconds(for: cleanedReply)
                    )
                }
                if willResume, cleanedReply.isEmpty {
                    await waitForSpeechToFinishThenStartVoice()
                } else {
                    if willResume {
                        scheduleVoiceLoopFallback(for: cleanedReply)
                    }
                    speech.speak(cleanedReply)
                }
            } else if willResume {
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        } catch {
            speech.stop()
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            OrbitVoiceSession.shared.transition(to: .ending(.error))
            NotificationCenter.default.post(
                name: .orbitMacChatStateMerge,
                object: nil,
                userInfo: [
                    "reply": "",
                    "route": "—",
                    "model": "—",
                    "tierSource": "—",
                    "notice": error.localizedDescription,
                    "notice_tone": "issue",
                ]
            )
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        }
    }

    private func scheduleVoiceLoopFallback(for replyText: String) {
        let speech = OrbitVoiceKit.shared.speech
        let speechInput = OrbitVoiceKit.shared.speechInput
        voiceLoopFallbackTask?.cancel()
        let words = replyText.split(whereSeparator: \.isWhitespace).count
        let estimatedSpeechSeconds = min(36.0, max(2.0, Double(words) * 0.24 + 1.2))
        voiceLoopFallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(estimatedSpeechSeconds * 1_000_000_000))
            let deadline = Date().addingTimeInterval(90)
            while !Task.isCancelled, case .awaitingFollowup = OrbitVoiceSession.shared.state {
                if !speechInput.isListening, !speech.isSpeaking {
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    guard !speech.isSpeaking else { continue }
                    // startVoiceInputSession transitions .awaitingFollowup → .listening, ending this loop.
                    await self.startVoiceInputSession()
                    return
                }
                if Date() >= deadline {
                    if !speechInput.isListening, !speech.isSpeaking {
                        await self.startVoiceInputSession()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    private var calendarReadyForTooling: Bool {
        !calendarSummary.isEmpty
            && !calendarSummary.hasPrefix("Calendar error")
            && !(calendarPlaceholder && calendarSummary.isEmpty)
    }

    private func refreshCalendarSnapshot(silent: Bool) async {
        do {
            try await calendarService.ensureAccess()
            let text = try calendarService.upcomingEventsText(days: 14)
            calendarSummary = text
            calendarPlaceholder = false
            _ = silent
        } catch {
            calendarSummary = "Calendar error: \(error.localizedDescription)"
            calendarPlaceholder = false
        }
    }

    private static func messageNeedsCalendarContext(_ message: String) -> Bool {
        let t = message.lowercased()
        let keys = [
            "calendar", "reminder", "schedule", "event", "todo", "task",
            "this week", "next week", "coming up", "upcoming",
            "agenda", "appointment", "appointments",
            "what's on", "whats on", "what is on",
            "my day", "free today", "busy today",
        ]
        return keys.contains { t.contains($0) }
    }

    private static func contextualPartingLine() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let general = [
            "Catch you later!",
            "I\u{2019}ll be around.",
            "See you!",
            "Take care!",
            "You know where to find me.",
            "Just say hey when you need me.",
            "Anytime!",
        ]
        let timeSpecific: [String]
        switch hour {
        case 5..<12:
            timeSpecific = [
                "Enjoy your morning!",
                "Have a great start to the day!",
                "Hope your morning goes well!",
                "Make the most of it!",
            ]
        case 12..<17:
            timeSpecific = [
                "Enjoy the rest of your day!",
                "Have a good afternoon!",
                "Hope the rest of your day is smooth!",
                "Keep it going!",
            ]
        case 17..<22:
            timeSpecific = [
                "Enjoy your evening!",
                "Have a nice night ahead!",
                "Hope you have a relaxing evening!",
                "Wind down well!",
            ]
        default:
            timeSpecific = [
                "Good night!",
                "Rest well!",
                "Sleep well, catch you tomorrow!",
                "Have a peaceful night!",
            ]
        }
        // 60% general, 40% time-specific for variety
        let seed = Int(Date().timeIntervalSince1970) % 97
        let allLines = seed % 5 < 3 ? general : timeSpecific
        let idx = (seed + Int(Date().timeIntervalSince1970 / 30)) % allLines.count
        return allLines[idx]
    }

    private static func rotatingClosingSuffix() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let general = [
            "Anything else?",
            "Need anything else?",
            "What else can I help with?",
            "Anything more?",
            "Let me know if you need anything else.",
            "Is there anything else?",
            "What else?",
        ]
        // Use time-of-day specific closings occasionally (1 in 5 chance)
        let timeSpecific: String? = {
            let roll = Int(Date().timeIntervalSince1970) % 5
            guard roll == 0 else { return nil }
            switch hour {
            case 5..<12: return ["Have a great morning!", "Good start to the day!"].randomElement()
            case 17..<22: return ["Have a nice evening!", "Enjoy your evening!"].randomElement()
            case 22...23, 0..<5: return ["Have a good night!", "Rest well!"].randomElement()
            default: return nil
            }
        }()
        if let specific = timeSpecific { return specific }
        let idx = Int(Date().timeIntervalSince1970 / 60) % general.count
        return general[idx]
    }

    private static func isNonLatinHeavy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let scalars = text.unicodeScalars
        let total = scalars.count
        // Count characters in Latin + common punctuation ranges only (U+0000–U+024F).
        // CharacterSet.alphanumerics includes ALL Unicode letters (Devanagari, Arabic, CJK)
        // which defeats the purpose, so we check the scalar value directly.
        let latinCount = scalars.filter { $0.value <= 0x024F }.count
        return Double(total - latinCount) / Double(max(1, total)) > 0.3
    }

    private static func sanitizeReply(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<|eot_id|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Returns constellation items if the text contains a numbered-option list (e.g. "1. Calendar\n2. Reminder\n3. Skip").
    private func parseAskAsConstellationOptions(from text: String) -> [OrbitListeningPresence.ConstellationItem]? {
        let lines = text.components(separatedBy: .newlines)
        var items: [OrbitListeningPresence.ConstellationItem] = []
        guard let regex = try? NSRegularExpression(pattern: #"^(\d+)\.\s+(.+)$"#) else { return nil }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = t as NSString
            guard let m = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 3,
                  let num = Int(ns.substring(with: m.range(at: 1)))
            else { continue }
            let title = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                items.append(OrbitListeningPresence.ConstellationItem(id: num, title: title, subtitle: "Say \u{201C}\(num)\u{201D}"))
            }
        }
        return items.count >= 2 ? items : nil
    }

    private func wakeCardTTLSeconds(for message: String) -> Double {
        let words = max(1, message.split(whereSeparator: \.isWhitespace).count)
        // Short terminal acknowledgments (≤ 6 words, no question, no list) dismiss in 4 s.
        if words <= 6 && !message.contains("?") && !message.contains("\n") { return 4 }
        return min(240, max(25, Double(words) * 0.35 + 18))
    }
    
    private func parseConstellationItems(from reply: String) -> (items: [OrbitListeningPresence.ConstellationItem], totalFound: Int)? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().contains("say open 1") || trimmed.lowercased().contains("matches for") else {
            return nil
        }
        let totalFound: Int = {
            guard let r = try? NSRegularExpression(pattern: #"i found\s+(\d+)\s+matches"#, options: [.caseInsensitive]),
                  let m = r.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  m.numberOfRanges >= 2,
                  let range = Range(m.range(at: 1), in: trimmed),
                  let n = Int(trimmed[range])
            else { return 0 }
            return n
        }()

        let lines = trimmed.components(separatedBy: .newlines)
        var items: [OrbitListeningPresence.ConstellationItem] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let m = line.range(of: #"^(\d{1,2})\.\s+(.+)$"#, options: .regularExpression) else {
                i += 1
                continue
            }
            let row = String(line[m])
            let ns = row as NSString
            guard let rr = try? NSRegularExpression(pattern: #"^(\d{1,2})\.\s+(.+)$"#),
                  let mm = rr.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)),
                  mm.numberOfRanges >= 3
            else {
                i += 1
                continue
            }
            let idxString = ns.substring(with: mm.range(at: 1))
            let title = ns.substring(with: mm.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle: String = {
                if i + 1 < lines.count {
                    let next = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if next.hasPrefix("/") || next.hasPrefix("~") {
                        return next
                    }
                }
                return ""
            }()
            if let idx = Int(idxString), !title.isEmpty {
                items.append(.init(id: idx, title: title, subtitle: subtitle))
            }
            i += 1
        }
        guard !items.isEmpty else { return nil }
        return (Array(items.prefix(15)), max(totalFound, items.count))
    }
}

private extension Double {
    func nonZeroOrDefault(_ def: Double) -> Double {
        self > 0.05 ? self : def
    }
}
