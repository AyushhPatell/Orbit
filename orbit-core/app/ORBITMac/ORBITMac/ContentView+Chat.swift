//
//  ContentView+Chat.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    @MainActor
    func sendMessage(fromVoice: Bool = false) async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Local system command (Wi-Fi, volume, files, etc.)
        var localControl = await OrbitMacControlCenter.performIfCommand(trimmed)
        // Safety net: if a note-body clarification was pending but performIfCommand returned
        // handled:false, retry once — the pending state is still active and will be caught.
        if !localControl.handled, OrbitLocalActionPendingStore.shared.noteBodyPending {
            localControl = await OrbitMacControlCenter.performIfCommand(trimmed)
        }
        if localControl.handled {
            // Sentinel replies: the wake path unwraps these in OrbitWakeVoiceBackstage; do the
            // same here so the panel never displays or speaks a raw "__orbit_*__" marker.
            if localControl.reply == "__orbit_list_reminders__" {
                speechInput.stopListening()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                await OrbitReminderService.shared.requestAccessIfNeeded()
                responseText = await OrbitReminderService.shared.listUpcoming()
                lastRoute = "reminder-list"
                lastModel = "on-device"
                lastTierSource = "on-device"
                inputText = ""
                suppressAutoVoiceResume = false
                shouldResumeVoiceLoop = fromVoice && continuousVoiceMode
                if fromVoice && autoSpeakReplies {
                    if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: responseText) }
                    speech.speak(responseText)
                } else if shouldResumeVoiceLoop {
                    shouldResumeVoiceLoop = false
                    await startVoiceInputSession()
                }
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            if localControl.reply == "__orbit_list_events__" {
                speechInput.stopListening()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                do {
                    try await calendarService.ensureAccess()
                    let text = try calendarService.upcomingEventsText(days: 7)
                    responseText = text.isEmpty ? "No upcoming events in the next week." : text
                } catch {
                    responseText = "I couldn\u{2019}t access your calendar: \(error.localizedDescription)"
                }
                lastRoute = "calendar-list"
                lastModel = "on-device"
                lastTierSource = "on-device"
                inputText = ""
                suppressAutoVoiceResume = false
                shouldResumeVoiceLoop = fromVoice && continuousVoiceMode
                if fromVoice && autoSpeakReplies {
                    if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: responseText) }
                    speech.speak(responseText)
                } else if shouldResumeVoiceLoop {
                    shouldResumeVoiceLoop = false
                    await startVoiceInputSession()
                }
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            if let sentinelReply = localControl.reply, sentinelReply.hasPrefix("__orbit_doc_llm__") {
                let llmMessage = String(sentinelReply.dropFirst("__orbit_doc_llm__".count))
                speechInput.stopListening()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                isLoading = true
                defer { isLoading = false }
                do {
                    let clock = OrbitClientClock.snapshotForAPI()
                    let result = try await OrbitAPI().chat(
                        sessionID: sessionID, message: llmMessage, routeHint: .local,
                        toolingContext: nil, clientLocalISO8601: clock.iso8601,
                        clientTimeZoneId: clock.timeZoneId,
                        includeMemoryDebug: showMemoryDebug ? true : nil
                    )
                    responseText = sanitizeReply(result.reply)
                    lastRoute = result.route
                    lastModel = result.model
                    lastTierSource = "on-device"
                    inputText = ""
                    suppressAutoVoiceResume = false
                    shouldResumeVoiceLoop = fromVoice && continuousVoiceMode
                    if fromVoice && autoSpeakReplies {
                        if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: responseText) }
                        speech.speak(responseText)
                    } else if shouldResumeVoiceLoop {
                        shouldResumeVoiceLoop = false
                        await startVoiceInputSession()
                    }
                } catch {
                    responseText = ""
                    presentNotice("Document summary failed: \(error.localizedDescription)", tone: .issue)
                }
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            suppressAutoVoiceResume = !localControl.appendWakeConversationPrompt
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()

            responseText = localControl.reply ?? "Done."
            lastRoute = "local-action"
            lastModel = "macos-control"
            lastTierSource = "on-device"
            inputText = ""
            if let notice = localControl.notice { presentNotice(notice) }

            // For typed input, "can you spell it for me?" makes no sense — the user already
            // typed the name correctly. Clear the pending state and strip the prompt.
            if !fromVoice, OrbitLocalActionPendingStore.shared.spellingPendingContext != nil {
                OrbitLocalActionPendingStore.shared.clearSpellingState()
                responseText = responseText
                    .replacingOccurrences(of: " Can you spell it for me?", with: ".")
                    .replacingOccurrences(of: "Can you spell it for me?", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Any pending that needs a spoken answer ("open 1", "yes", "cancel") must reopen the mic.
            let store = OrbitLocalActionPendingStore.shared
            let awaitingSpokenAnswer = fromVoice && (
                store.spellingPendingContext != nil
                || store.folderConfirmPending() != nil
                || store.noteBodyPending
                || store.filePickPendingPaths() != nil
                || store.documentPickPending() != nil
                || store.terminalCommandPending() != nil
                || store.messageProposalPending() != nil
                || store.deleteProposalPending() != nil
                || store.emptyTrashProposalPending()
            )
            if awaitingSpokenAnswer { suppressAutoVoiceResume = false }
            shouldResumeVoiceLoop = fromVoice && (continuousVoiceMode || awaitingSpokenAnswer) && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                let cleanedReply = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldResumeVoiceLoop, cleanedReply.isEmpty {
                    shouldResumeVoiceLoop = false
                    await waitForSpeechToFinishThenStartVoice()
                } else {
                    if shouldResumeVoiceLoop {
                        scheduleVoiceLoopFallback(for: cleanedReply)
                    }
                    speech.speak(cleanedReply)
                }
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        // 2. Session stop command ("stop", "bye", "done", etc.)
        if OrbitVoiceIntentHelpers.isSessionStopCommand(trimmed) {
            suppressAutoVoiceResume = true
            shouldResumeVoiceLoop = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening(commitIfPossible: false)
            OrbitWakeWordController.shared.suspendForUserSpeech()
            inputText = ""
            speech.stop()
            if fromVoice { speech.speak(OrbitVoicePartingLine.spokenLine(for: trimmed)) }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech(delay: 2.8)
            return
        }

        // 3. Reminder clarification broker
        let reminderOutcome = OrbitClarificationBroker.shared.process(trimmed)
        switch reminderOutcome {
        case .none:
            break

        case .ask(let question):
            clarificationChips = []
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            responseText = question
            lastRoute = "reminder-clarify"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            // Auto-reopen mic after clarification questions even without continuous mode.
            let askIsQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            shouldResumeVoiceLoop = fromVoice && (continuousVoiceMode || (autoSpeakReplies && askIsQuestion)) && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: question) }
                speech.speak(question)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .askWithChips(let question, let chips):
            clarificationChips = chips
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            responseText = question
            lastRoute = "reminder-clarify"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            let chipsIsQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            shouldResumeVoiceLoop = fromVoice && (continuousVoiceMode || (autoSpeakReplies && chipsIsQuestion)) && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: question) }
                speech.speak(question)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .createReminder(let title, let dueDate):
            clarificationChips = []
            await OrbitReminderService.shared.requestAccessIfNeeded()
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            let createReply: String
            do { createReply = try OrbitReminderService.shared.createReminder(title: title, dueDate: dueDate) }
            catch { createReply = "Sorry, I couldn't save the reminder: \(error.localizedDescription)" }
            responseText = createReply
            lastRoute = "reminder-create"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: createReply) }
                speech.speak(createReply)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .listReminders:
            await OrbitReminderService.shared.requestAccessIfNeeded()
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            let listReply = await OrbitReminderService.shared.listUpcoming()
            responseText = listReply
            lastRoute = "reminder-list"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: listReply) }
                speech.speak(listReply)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .completeReminder(let query):
            clarificationChips = []
            await OrbitReminderService.shared.requestAccessIfNeeded()
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            let completeReply = await OrbitReminderService.shared.completeReminder(matching: query)
            responseText = completeReply
            lastRoute = "reminder-complete"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: completeReply) }
                speech.speak(completeReply)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .deleteReminder(let query):
            clarificationChips = []
            await OrbitReminderService.shared.requestAccessIfNeeded()
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            let deleteReply = await OrbitReminderService.shared.deleteReminder(matching: query)
            responseText = deleteReply
            lastRoute = "reminder-delete"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: deleteReply) }
                speech.speak(deleteReply)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .createCalendarEvent(let title, let start, let end):
            clarificationChips = []
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            let calReply: String
            do {
                let calName = try await calendarService.addTimedEvent(title: title, start: start, end: end)
                let when = OrbitClarificationBroker.formatEventStart(start)
                let dur = Int(end.timeIntervalSince(start) / 60)
                let durStr = dur >= 60
                    ? (dur % 60 == 0 ? "\(dur / 60)h" : "\(dur / 60)h \(dur % 60)m")
                    : "\(dur)m"
                calReply = "Done — \"\(title)\" added to \(calName) \(when) (\(durStr))."
            } catch {
                calReply = "Sorry, I couldn't create the event: \(error.localizedDescription)"
            }
            responseText = calReply
            lastRoute = "calendar-create"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: calReply) }
                speech.speak(calReply)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return

        case .createBoth(let calTitle, let start, let end, let remTitle, let remDue):
            clarificationChips = []
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
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
            responseText = bothReply
            lastRoute = "calendar-reminder-create"
            lastModel = "on-device"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: bothReply) }
                speech.speak(bothReply)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        // 4. Communication draft intent broker
        let commOutcome = OrbitCommunicationDraftIntentBroker.shared.process(trimmed)
        switch commOutcome {
        case .none:
            break
        case .message(let msg):
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            responseText = msg
            lastRoute = "comm-draft-pending"
            lastModel = "macos-comm"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                speech.speak(msg)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .run(let req):
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            do {
                let run = try await OrbitCommunicationDraftRunner.run(req, sessionID: sessionID, includeMemoryDebug: showMemoryDebug)
                responseText = sanitizeReply(run.reply)
                lastRoute = run.route
                lastModel = run.model
                lastTierSource = "on-device"
                inputText = ""
                shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
                if fromVoice && autoSpeakReplies {
                    speech.speak(responseText)
                } else if shouldResumeVoiceLoop {
                    shouldResumeVoiceLoop = false
                    await startVoiceInputSession()
                }
            } catch {
                responseText = ""
                presentNotice("Communication draft failed: \(error.localizedDescription)", tone: .issue)
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        // 5. Web action intent broker
        let webOutcome = OrbitWebActionIntentBroker.shared.process(trimmed)
        switch webOutcome {
        case .none:
            break
        case .message(let msg):
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            responseText = msg
            lastRoute = "web-action-pending"
            lastModel = "macos-web"
            lastTierSource = "on-device"
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                speech.speak(msg)
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .run(let intent):
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            do {
                let run = try await OrbitWebActionRunner.run(intent, sessionID: sessionID, includeMemoryDebug: showMemoryDebug)
                responseText = sanitizeReply(run.reply)
                lastRoute = run.route
                lastModel = run.model
                lastTierSource = "on-device"
                inputText = ""
                shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
                if fromVoice && autoSpeakReplies {
                    speech.speak(responseText)
                } else if shouldResumeVoiceLoop {
                    shouldResumeVoiceLoop = false
                    await startVoiceInputSession()
                }
            } catch {
                responseText = ""
                presentNotice("Web action failed: \(error.localizedDescription)", tone: .issue)
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        }

        // 6. Clipboard intelligence expansion
        let clipboardPrep = OrbitClipboardIntelligence.prepareUserMessageForChat(trimmed)
        let messageForChat: String
        let forceLocalFromClipboard: Bool
        switch clipboardPrep {
        case .clipboardEmpty:
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            presentNotice(
                "Clipboard has no plain text to use. Copy some text first (\u{2318}C), then try again.",
                tone: .issue
            )
            inputText = ""
            shouldResumeVoiceLoop = fromVoice && continuousVoiceMode && !suppressAutoVoiceResume
            if fromVoice && autoSpeakReplies {
                speech.speak("Copy some text to the clipboard first, then ask again.")
            } else if shouldResumeVoiceLoop {
                shouldResumeVoiceLoop = false
                await startVoiceInputSession()
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .clipboardDisabled:
            suppressAutoVoiceResume = false
            voiceLoopFallbackTask?.cancel()
            voiceLoopFallbackTask = nil
            speechInput.stopListening()
            presentNotice(
                "Clipboard access is turned off in ORBIT\u{2019}s privacy settings. You can enable it in the gear menu.",
                tone: .issue
            )
            responseText = ""
            inputText = ""
            if fromVoice && autoSpeakReplies {
                speech.speak("Clipboard access is turned off in my privacy settings.")
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
            return
        case .useAsIs(let s):
            messageForChat = s
            forceLocalFromClipboard = false
        case .clipboardExpanded(let s):
            messageForChat = s
            forceLocalFromClipboard = true
        }

        // 7. Screen context injection (after clipboard, before LLM)
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
                // Capture failed — macOS 26 shows a permission dialog on first call per launch.
                // Don't open Settings (system dialog handles that). Ask user to dismiss and retry.
                inputText = ""
                responseText = "Screen capture didn\u{2019}t work. If you see a system dialog, dismiss it and try again. Make sure ORBITMac is enabled in Screen Recording settings."
                lastRoute = "screen-reader"
                lastModel = "on-device"
                lastTierSource = "on-device"
                OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
                return
            }
            // else: transient failure (no display, empty OCR) — send without screen context.
        }

        // 8. LLM chat (local or cloud)
        suppressAutoVoiceResume = false
        voiceLoopFallbackTask?.cancel()
        voiceLoopFallbackTask = nil
        speechInput.stopListening()

        isLoading = true
        clearNotice()

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
        let tierSource = OrbitRouteClassifier.lastSource.rawValue

        if fromVoice {
            // Voice path: non-streaming (TTS needs the full reply before speaking)
            defer { isLoading = false }
            do {
                let rawResult = try await OrbitAPI().chat(
                    sessionID: sessionID,
                    message: screenAugmentedMessage,
                    routeHint: routeHint,
                    toolingContext: toolingSnapshot,
                    clientLocalISO8601: clock.iso8601,
                    clientTimeZoneId: clock.timeZoneId,
                    includeMemoryDebug: showMemoryDebug ? true : nil
                )
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
                responseText = sanitizeReply(result.reply)
                lastRoute = result.route
                lastModel = result.model
                lastTierSource = tierSource
                lastMemoryDebug = result.memory_debug
                if showMemoryDebug { await loadSemanticMemoryDebug() }
                inputText = ""
                let cleanedReply = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Brain tools can leave a pick/confirm pending — the mic must reopen for the answer.
                let store = OrbitLocalActionPendingStore.shared
                let pendingNeedsVoice = store.filePickPendingPaths() != nil
                    || store.documentPickPending() != nil
                    || store.folderConfirmPending() != nil
                    || store.terminalCommandPending() != nil
                    || store.spellingPendingContext != nil
                // Auto-reopen mic after any question (clarification loop).
                // A goodbye overrides continuous voice mode — see isFarewellReply. Saying
                // "talk soon" and then reopening the mic reads as not having understood.
                let saidGoodbye = OrbitVoiceIntentHelpers.isFarewellReply(cleanedReply)
                shouldResumeVoiceLoop = !saidGoodbye
                    && (pendingNeedsVoice || continuousVoiceMode || (autoSpeakReplies && cleanedReply.hasSuffix("?")))
                    && !suppressAutoVoiceResume
                if saidGoodbye {
                    OrbitWakeWordController.shared.suspendForUserSpeech()
                    OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech(delay: 2.8)
                }
                if fromVoice && autoSpeakReplies {
                    if shouldResumeVoiceLoop, cleanedReply.isEmpty {
                        shouldResumeVoiceLoop = false
                        await waitForSpeechToFinishThenStartVoice()
                    } else {
                        if shouldResumeVoiceLoop { scheduleVoiceLoopFallback(for: cleanedReply) }
                        speech.speak(cleanedReply)
                    }
                } else if shouldResumeVoiceLoop {
                    shouldResumeVoiceLoop = false
                    await startVoiceInputSession()
                }
            } catch {
                responseText = ""
                lastMemoryDebug = nil
                speech.stop()
                voiceLoopFallbackTask?.cancel()
                voiceLoopFallbackTask = nil
                shouldResumeVoiceLoop = false
                presentNotice(error.localizedDescription, tone: .issue)
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        } else if routeHint == .cloud {
            // Streaming path: cloud research queries only. Local and tooling both go through
            // the non-streaming brain path below so tool calls are dispatched, not dropped —
            // a typed "open youtube" must act, even at the cost of progressive rendering.
            responseText = ""
            inputText = ""
            var finalRoute = routeHint.rawValue
            var finalModel = "—"
            var finalMemDebug: MemoryDebugInfo? = nil

            do {
                for try await chunk in OrbitAPI().chatStream(
                    sessionID: sessionID,
                    message: screenAugmentedMessage,
                    routeHint: routeHint,
                    toolingContext: toolingSnapshot,
                    clientLocalISO8601: clock.iso8601,
                    clientTimeZoneId: clock.timeZoneId,
                    includeMemoryDebug: showMemoryDebug ? true : nil
                ) {
                    switch chunk {
                    case .token(let t):
                        if isLoading { isLoading = false }
                        responseText += t
                    case .done(let route, let model, let reply, let memDebug):
                        responseText = sanitizeReply(reply)
                        finalRoute = route
                        finalModel = model
                        finalMemDebug = memDebug
                    }
                }
            } catch {
                if responseText.isEmpty {
                    presentNotice(error.localizedDescription, tone: .issue)
                }
            }

            isLoading = false
            lastRoute = finalRoute
            lastModel = finalModel
            lastTierSource = tierSource
            lastMemoryDebug = finalMemDebug
            if showMemoryDebug { await loadSemanticMemoryDebug() }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        } else {
            // Brain path (local / tooling / brain routes): non-streaming so tool-calling works
            responseText = ""
            inputText = ""
            defer { isLoading = false }
            do {
                let rawResult = try await OrbitAPI().chat(
                    sessionID: sessionID,
                    message: screenAugmentedMessage,
                    routeHint: routeHint,
                    toolingContext: toolingSnapshot,
                    clientLocalISO8601: clock.iso8601,
                    clientTimeZoneId: clock.timeZoneId,
                    includeMemoryDebug: showMemoryDebug ? true : nil
                )
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
                responseText = sanitizeReply(result.reply)
                lastRoute = result.route
                lastModel = result.model
                lastTierSource = tierSource
                lastMemoryDebug = result.memory_debug
                if showMemoryDebug { await loadSemanticMemoryDebug() }
            } catch {
                responseText = ""
                lastMemoryDebug = nil
                presentNotice(error.localizedDescription, tone: .issue)
            }
            OrbitWakeWordController.shared.scheduleResumeAfterUserSpeech()
        }
    }

    @MainActor
    func scheduleVoiceLoopFallback(for replyText: String) {
        voiceLoopFallbackTask?.cancel()
        let words = replyText.split(whereSeparator: \.isWhitespace).count
        let estimatedSpeechSeconds = min(36.0, max(2.0, Double(words) * 0.24 + 1.2))
        voiceLoopFallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(estimatedSpeechSeconds * 1_000_000_000))
            let deadline = Date().addingTimeInterval(90)
            while !Task.isCancelled, shouldResumeVoiceLoop, !suppressAutoVoiceResume {
                if !isLoading, !speechInput.isListening, !speech.isSpeaking {
                    shouldResumeVoiceLoop = false
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    guard !speech.isSpeaking, !isLoading else { continue }
                    await startVoiceInputSession()
                    return
                }
                if Date() >= deadline {
                    if !isLoading, !speechInput.isListening, !speech.isSpeaking {
                        shouldResumeVoiceLoop = false
                        await startVoiceInputSession()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    static func clampedFact(_ text: String, limit: Int = 2000) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit - 3))
        return head + "..."
    }

    func sanitizeReply(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<|eot_id|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
