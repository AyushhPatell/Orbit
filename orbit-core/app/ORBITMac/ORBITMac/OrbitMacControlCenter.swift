//
//  OrbitMacControlCenter.swift
//  ORBITMac
//
//  Core types, pending store, and command dispatch.
//  Domain implementations live in OrbitMacControlCenter+{Audio,Files,Network,System,Utilities}.swift
//

import AppKit
import CoreWLAN
import Foundation

// MARK: - Pending store (file pick / delete confirm / empty trash)

/// Context for the spelling-correction pending state.
enum OrbitSpellingContext {
    case findFile
    case openSubfolder(locationLabel: String)  // "Desktop", "Documents", or "Downloads"
}

final class OrbitLocalActionPendingStore: @unchecked Sendable {
    static let shared = OrbitLocalActionPendingStore()

    private let lock = NSLock()
    private var pickPaths: [String]?
    private var pickExpires: Date?
    private var deleteURL: URL?
    private var deleteSummary: String?
    private var deleteExpires: Date?
    private var emptyTrashPending = false
    private var emptyTrashExpires: Date?

    // Spelling-correction state: set when a search fails so the user can spell the name.
    private var spellingCtx: OrbitSpellingContext?
    private var spellingExpires: Date?
    // Parsed result of the user's spelling response, consumed once by performIfCommand.
    private var spellingResultName: String?
    private var spellingResultCtx: OrbitSpellingContext?

    private let ttl: TimeInterval = 120

    func pruneExpired() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let e = pickExpires, now > e { pickPaths = nil; pickExpires = nil }
        if let e = deleteExpires, now > e { deleteURL = nil; deleteExpires = nil; deleteSummary = nil }
        if let e = emptyTrashExpires, now > e { emptyTrashPending = false; emptyTrashExpires = nil }
        if let e = folderConfirmExpires, now > e { folderConfirmURL = nil; folderConfirmName = nil; folderConfirmExpires = nil }
    }

    func setFilePick(paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        emptyTrashPending = false; emptyTrashExpires = nil
        pickPaths = paths; pickExpires = Date().addingTimeInterval(ttl)
    }

    func clearFilePick() {
        lock.lock(); defer { lock.unlock() }
        emptyTrashPending = false; emptyTrashExpires = nil
        pickPaths = nil; pickExpires = nil
    }

    func filePickPendingPaths() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard let paths = pickPaths, let e = pickExpires, Date() <= e else { return nil }
        return paths
    }

    func setDeleteProposal(url: URL, summary: String) {
        lock.lock(); defer { lock.unlock() }
        emptyTrashPending = false; emptyTrashExpires = nil
        deleteURL = url; deleteSummary = summary; deleteExpires = Date().addingTimeInterval(ttl)
    }

    func deleteProposalPending() -> (url: URL, summary: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let u = deleteURL, let s = deleteSummary, let e = deleteExpires, Date() <= e else { return nil }
        return (u, s)
    }

    func clearDeleteProposal() {
        lock.lock(); defer { lock.unlock() }
        deleteURL = nil; deleteSummary = nil; deleteExpires = nil
    }

    func setEmptyTrashProposal() {
        lock.lock(); defer { lock.unlock() }
        pickPaths = nil; pickExpires = nil
        deleteURL = nil; deleteSummary = nil; deleteExpires = nil
        emptyTrashPending = true; emptyTrashExpires = Date().addingTimeInterval(ttl)
    }

    func emptyTrashProposalPending() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard emptyTrashPending, let e = emptyTrashExpires, Date() <= e else {
            emptyTrashPending = false; emptyTrashExpires = nil; return false
        }
        return true
    }

    func clearEmptyTrashProposal() {
        lock.lock(); defer { lock.unlock() }
        emptyTrashPending = false; emptyTrashExpires = nil
    }

    // MARK: - Fuzzy folder confirmation

    private var folderConfirmURL: URL?
    private var folderConfirmName: String?
    private var folderConfirmExpires: Date?

    func setFolderConfirm(url: URL, displayName: String) {
        lock.lock(); defer { lock.unlock() }
        folderConfirmURL = url
        folderConfirmName = displayName
        folderConfirmExpires = Date().addingTimeInterval(ttl)
    }

    func folderConfirmPending() -> (url: URL, displayName: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let url = folderConfirmURL, let name = folderConfirmName,
              let exp = folderConfirmExpires, Date() <= exp else {
            folderConfirmURL = nil; folderConfirmName = nil; folderConfirmExpires = nil
            return nil
        }
        return (url, name)
    }

    func clearFolderConfirm() {
        lock.lock(); defer { lock.unlock() }
        folderConfirmURL = nil; folderConfirmName = nil; folderConfirmExpires = nil
    }

    // MARK: - Spelling correction

    /// Call when a search yields no results — puts ORBIT in "awaiting spelling" mode.
    func setSpellingPending(_ ctx: OrbitSpellingContext) {
        lock.lock(); defer { lock.unlock() }
        spellingCtx = ctx
        spellingExpires = Date().addingTimeInterval(ttl)
        spellingResultName = nil
        spellingResultCtx = nil
    }

    /// The context currently awaiting a spelled reply, if still valid.
    var spellingPendingContext: OrbitSpellingContext? {
        lock.lock(); defer { lock.unlock() }
        guard let ctx = spellingCtx, let exp = spellingExpires, Date() < exp else {
            spellingCtx = nil; spellingExpires = nil
            return nil
        }
        return ctx
    }

    /// Store the user's parsed spelling reply so `performIfCommand` can pick it up.
    func setSpellingResult(name: String, ctx: OrbitSpellingContext) {
        lock.lock(); defer { lock.unlock() }
        spellingResultName = name
        spellingResultCtx = ctx
        spellingCtx = nil; spellingExpires = nil
    }

    /// Consume-once: returns the pending spelling result and clears it.
    func consumeSpellingResult() -> (name: String, ctx: OrbitSpellingContext)? {
        lock.lock(); defer { lock.unlock() }
        guard let name = spellingResultName, let ctx = spellingResultCtx else { return nil }
        spellingResultName = nil; spellingResultCtx = nil
        return (name, ctx)
    }

    func clearSpellingState() {
        lock.lock(); defer { lock.unlock() }
        spellingCtx = nil; spellingExpires = nil
        spellingResultName = nil; spellingResultCtx = nil
    }

    // MARK: - Message proposal pending

    private var msgRecipientName: String?
    private var msgRecipientID: String?
    private var msgBody: String?
    private var msgExpires: Date?

    func setMessageProposal(recipient: String, identifier: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        msgRecipientName = recipient; msgRecipientID = identifier; msgBody = body
        msgExpires = Date().addingTimeInterval(ttl)
    }

    func messageProposalPending() -> (name: String, id: String, body: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let name = msgRecipientName, let id = msgRecipientID, let body = msgBody,
              let exp = msgExpires, Date() <= exp else {
            msgRecipientName = nil; msgRecipientID = nil; msgBody = nil; msgExpires = nil
            return nil
        }
        return (name, id, body)
    }

    func clearMessageProposal() {
        lock.lock(); defer { lock.unlock() }
        msgRecipientName = nil; msgRecipientID = nil; msgBody = nil; msgExpires = nil
    }

    // MARK: - Overdue follow-up pending

    private var followupID: String?
    private var followupTitle: String?
    private var followupExpires: Date?

    /// Set by OrbitProactiveNotifier when it fires a "did you do it?" follow-up.
    /// Stays active for 10 minutes so the user can wake ORBIT and respond.
    func setFollowupPending(id: String, title: String) {
        lock.lock(); defer { lock.unlock() }
        followupID = id
        followupTitle = title
        followupExpires = Date().addingTimeInterval(600)
    }

    var followupPendingInfo: (id: String, title: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let id = followupID, let title = followupTitle,
              let exp = followupExpires, Date() < exp
        else {
            followupID = nil; followupTitle = nil; followupExpires = nil
            return nil
        }
        return (id, title)
    }

    func clearFollowup() {
        lock.lock(); defer { lock.unlock() }
        followupID = nil; followupTitle = nil; followupExpires = nil
    }

    // MARK: - Note body pending (clarification loop)

    private var noteBodyPendingFlag = false
    private var noteBodyPendingExpires: Date?

    /// Set when "take a note" is spoken with no content — ORBIT asks what to note.
    func setNoteBodyPending() {
        lock.lock(); defer { lock.unlock() }
        noteBodyPendingFlag = true
        noteBodyPendingExpires = Date().addingTimeInterval(ttl)
    }

    /// True while ORBIT is waiting for the user to dictate the note content.
    var noteBodyPending: Bool {
        lock.lock(); defer { lock.unlock() }
        guard noteBodyPendingFlag, let exp = noteBodyPendingExpires, Date() <= exp else {
            noteBodyPendingFlag = false; noteBodyPendingExpires = nil; return false
        }
        return true
    }

    func clearNoteBodyPending() {
        lock.lock(); defer { lock.unlock() }
        noteBodyPendingFlag = false; noteBodyPendingExpires = nil
    }

    // MARK: - Terminal command pending (confirmation ceremony)

    private var termCommandPending: String?
    private var termDirectoryPending: String?
    private var termCommandExpires: Date?

    func setTerminalCommandPending(_ command: String, directory: String?) {
        lock.lock(); defer { lock.unlock() }
        termCommandPending = command
        termDirectoryPending = directory
        termCommandExpires = Date().addingTimeInterval(ttl)
    }

    func terminalCommandPending() -> (command: String, directory: String?)? {
        lock.lock(); defer { lock.unlock() }
        guard let cmd = termCommandPending, let exp = termCommandExpires, Date() <= exp else {
            termCommandPending = nil; termDirectoryPending = nil; termCommandExpires = nil; return nil
        }
        return (cmd, termDirectoryPending)
    }

    func clearTerminalCommand() {
        lock.lock(); defer { lock.unlock() }
        termCommandPending = nil; termDirectoryPending = nil; termCommandExpires = nil
    }

    // MARK: - Document pick pending

    private var docPickPaths: [String]?
    private var docPickAction: String?
    private var docPickExpires: Date?

    func setDocumentPick(paths: [String], action: String) {
        lock.lock(); defer { lock.unlock() }
        docPickPaths = paths; docPickAction = action
        docPickExpires = Date().addingTimeInterval(ttl)
    }

    func documentPickPending() -> (paths: [String], action: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let paths = docPickPaths, let action = docPickAction,
              let exp = docPickExpires, Date() <= exp else {
            docPickPaths = nil; docPickAction = nil; docPickExpires = nil; return nil
        }
        return (paths, action)
    }

    func clearDocumentPick() {
        lock.lock(); defer { lock.unlock() }
        docPickPaths = nil; docPickAction = nil; docPickExpires = nil
    }
}

// MARK: - OrbitMacControlCenter

enum OrbitMacControlCenter {

    // MARK: Nested types shared with extension files

    enum ProjectFolderParent {
        case documentsOrbitProjects
        case desktop
    }

    enum ProjectFolderScaffold: Equatable {
        case standard
        case flat
        case custom([String])
    }

    enum DeleteFolderLocation {
        case desktop
        case documents
        case downloads
    }

    enum ControlError: LocalizedError {
        case appNotFound
        case actionFailed(String)

        var errorDescription: String? {
            switch self {
            case .appNotFound:
                return "App not found. Try a slightly more specific app name."
            case .actionFailed(let message):
                return message
            }
        }
    }

    struct Outcome {
        let handled: Bool
        let reply: String?
        let appendWakeConversationPrompt: Bool
        /// When true, suppresses the "Is there anything else?" suffix even though the voice loop stays open.
        let isClarificationQuestion: Bool
        let notice: String?
        init(
            handled: Bool,
            reply: String?,
            appendWakeConversationPrompt: Bool,
            isClarificationQuestion: Bool = false,
            notice: String? = nil
        ) {
            self.handled = handled
            self.reply = reply
            self.appendWakeConversationPrompt = appendWakeConversationPrompt
            self.isClarificationQuestion = isClarificationQuestion
            self.notice = notice
        }
    }

    // MARK: Private command enum (used only in parseCommand / execute)

    private enum Command {
        case openSystemSettings(OrbitSystemSettingsPane)
        case appStoreSearch(String)
        case googleSearchChrome(String)
        case typeIntoFocusedField(String)
        case openApp(String)
        case openFinder
        case openSubfolder(name: String, location: DeleteFolderLocation)
        case openFolderAcrossLocations(String)   // "open X folder" with no location qualifier
        case openDownloads
        case openDocuments
        case openDesktop
        case openTrash
        case emptyTrashPropose
        case findFileByName(String)
        case createProjectFolder(name: String, parent: ProjectFolderParent, scaffold: ProjectFolderScaffold)
        case deletePropose(name: String, location: DeleteFolderLocation)
        case wifiOn
        case wifiOff
        case wifiStatus
        case bluetoothOn
        case bluetoothOff
        case bluetoothStatus
        case bluetoothToolingCheck
        case focusOn
        case focusOff
        case focusStatus
        case batteryStatus
        case darkModeOn
        case darkModeOff
        case darkModeToggle
        case mute
        case unmute
        case volumeUp
        case volumeDown
        case setVolume(Int)
        case lockScreen
        case quitApp(String)
        case wakeOrbit
        // Contacts / calls / messages
        case faceTimeVideo(String)
        case faceTimeAudio(String)
        case openMessage(name: String, body: String)
        case sendMessageConfirm
        // Browser
        case openInBrowser(url: URL, browserBundle: String?)
        case searchInBrowser(query: String, browserBundle: String?)
        // Music
        case musicPlay
        case musicPause
        case musicNext
        case musicPrevious
        case musicNowPlaying
        // Display
        case brightnessUp
        case brightnessDown
        case setBrightness(Int)
        case nightShiftOn
        case nightShiftOff
    }

    // MARK: - Public entry point

    static func performIfCommand(_ text: String, allowChaining: Bool = true) async -> Outcome {
        var normalized = normalize(text)
        OrbitLocalActionPendingStore.shared.pruneExpired()

        // "Sleep" said on its own means *ORBIT* should rest — decline it here so it reaches the
        // stop-intent check, which runs after this. Without this the command matcher claimed the
        // word as something to open ("Opening sleep.") while "go to sleep" fell through and
        // worked: the same intent behaving two different ways depending on phrasing.
        // Commands that merely *mention* sleep ("sleep the display", "turn on sleep focus") are
        // rejected by isRestIntent itself and still land in the matchers below.
        if OrbitVoiceIntentHelpers.isRestIntent(text) {
            return Outcome(handled: false, reply: nil, appendWakeConversationPrompt: false)
        }

        // Terminal command: checked FIRST so nothing else can steal "run git status".
        // The pending-confirmation handler is in handlePendingLocalActions below.
        if OrbitLocalActionPendingStore.shared.terminalCommandPending() == nil,
           let cmd = extractTerminalCommand(from: normalized) {
            if isBlockedCommand(cmd) {
                return Outcome(handled: true, reply: "That command looks dangerous \u{2014} I won\u{2019}t run it.", appendWakeConversationPrompt: false)
            }
            let reply = proposeTerminalCommand(cmd)
            return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: false)
        }

        if let pendingReply = handlePendingLocalActions(normalized) {
            return Outcome(
                handled: true,
                reply: pendingReply,
                appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: pendingReply)
            )
        }
        // handlePendingLocalActions may have parsed a spelling reply and stored it — consume and re-run search.
        if let (spelledName, spellingCtx) = OrbitLocalActionPendingStore.shared.consumeSpellingResult() {
            let reply: String
            do {
                switch spellingCtx {
                case .findFile:
                    reply = try await findAndMaybeOpenFile(named: spelledName)
                case .openSubfolder(let locationLabel):
                    switch locationLabel.lowercased() {
                    case "desktop":
                        reply = try openSubfolderInFinder(name: spelledName, location: .desktop)
                    case "documents":
                        reply = try openSubfolderInFinder(name: spelledName, location: .documents)
                    case "downloads":
                        reply = try openSubfolderInFinder(name: spelledName, location: .downloads)
                    default:
                        // "your folders" = all-locations search; re-run the cross-location lookup.
                        reply = findAndOpenFolderAcrossLocations(name: spelledName)
                    }
                }
            } catch {
                let detail = (error as? ControlError)?.localizedDescription ?? error.localizedDescription
                reply = detail.isEmpty ? "The search didn\u{2019}t return results. Try a different name." : detail
            }
            // If the retry also failed and set a new spelling prompt, clear it — one retry only.
            // Avoid looping the user through endless "can you spell it again?" chains.
            if OrbitLocalActionPendingStore.shared.spellingPendingContext != nil {
                OrbitLocalActionPendingStore.shared.clearSpellingState()
                return Outcome(
                    handled: true,
                    reply: "I still couldn't find that. Make sure it's in Desktop, Documents, or Downloads.",
                    appendWakeConversationPrompt: false
                )
            }
            return Outcome(
                handled: true,
                reply: reply,
                appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: reply)
            )
        }
        if let unsupported = unsupportedCapabilityResponse(for: normalized) {
            return Outcome(
                handled: true,
                reply: unsupported,
                appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: unsupported)
            )
        }
        // Notes clarification: if ORBIT asked "what would you like to note down?", the
        // next utterance is treated as the note body — unless it's a cancel or system command.
        if OrbitLocalActionPendingStore.shared.noteBodyPending {
            let cancelWords: Set<String> = ["cancel", "no", "nope", "nothing", "skip", "stop",
                                             "nevermind", "never mind", "forget it"]
            let prefixCancels = ["no thanks", "cancel that", "skip that", "forget it", "never mind"]
            let sysVerbPrefixes = ["close ", "quit ", "open ", "launch ", "exit ", "kill "]
            OrbitLocalActionPendingStore.shared.clearNoteBodyPending()
            if cancelWords.contains(normalized) || prefixCancels.contains(where: { normalized.hasPrefix($0) }) {
                return Outcome(handled: true, reply: "No problem.", appendWakeConversationPrompt: false)
            }
            if !sysVerbPrefixes.contains(where: { normalized.hasPrefix($0) }) {
                do {
                    // Accept a new "take a note: X" trigger as well as bare content.
                    let (title, body) = extractNoteContent(from: text)
                    let noteBody = body.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : body
                    if !noteBody.isEmpty {
                        let reply = try createNote(title: title, body: noteBody)
                        return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
                    }
                } catch {
                    let msg = (error as? ControlError)?.localizedDescription ?? error.localizedDescription
                    // appendWakeConversationPrompt: false — error closes the voice turn so the
                    // user's retry can't slip through to the LLM/reminder broker.
                    return Outcome(handled: true, reply: msg, appendWakeConversationPrompt: false)
                }
            }
            // System command — fall through with pending already cleared.
        }

        // Strip conversational prefix for fresh commands. "Yes, summarize the enrollment letter"
        // → "summarize the enrollment letter". Done AFTER pending handlers (where "yes" is the answer)
        // so confirmations still work, but BEFORE intent detection so commands aren't confused.
        normalized = stripLeadingAffirmationGlobal(normalized)

        // "turn it back on" → "turn wifi on", using the last feature ORBIT toggled. Resolved here
        // so the normal matchers handle it — instant, on-device, and works with no internet.
        if let resolved = await resolveSystemPronoun(in: normalized) {
            normalized = resolved
        }

        // Multi-step chaining: "open Chrome and play music", "mute and turn on focus"
        if allowChaining, let chained = await tryChainedExecution(text: text, normalized: normalized) {
            return chained
        }

        // Notes append: "add X to that note" / "also add X" — amend the last note ORBIT created.
        if isNotesAppendIntent(normalized) {
            let content = extractNoteAppendContent(from: text)
            if content.isEmpty {
                return Outcome(
                    handled: true,
                    reply: "What would you like to add to the note?",
                    appendWakeConversationPrompt: false
                )
            }
            if let noteTitle = OrbitNotesState.lastCreatedNoteTitle {
                do {
                    let reply = try appendToNote(title: noteTitle, content: content)
                    return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
                } catch {
                    let msg = (error as? ControlError)?.localizedDescription ?? error.localizedDescription
                    return Outcome(handled: true, reply: msg, appendWakeConversationPrompt: true)
                }
            } else {
                return Outcome(
                    handled: true,
                    reply: "I don\u{2019}t have a recent note to update. Which note should I add to?",
                    appendWakeConversationPrompt: false
                )
            }
        }
        // Notes creation is handled here (before parseCommand) so extractNoteContent receives the
        // original text with proper casing and punctuation, not the lowercased normalized string.
        if isNotesCreateIntent(normalized) {
            let (title, body) = extractNoteContent(from: text)
            if !body.isEmpty {
                do {
                    let reply = try createNote(title: title, body: body)
                    await OrbitConversationMemory.shared.record(.noteTitle, value: body)
                    return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
                } catch {
                    let msg = (error as? ControlError)?.localizedDescription ?? error.localizedDescription
                    return Outcome(handled: true, reply: msg, appendWakeConversationPrompt: true)
                }
            }
            // Body is empty — ask what to note, then wait for the follow-up utterance.
            OrbitLocalActionPendingStore.shared.setNoteBodyPending()
            return Outcome(
                handled: true,
                reply: "Sure! What would you like to note down?",
                appendWakeConversationPrompt: true,
                isClarificationQuestion: true  // suppresses the "Is there anything else?" suffix
            )
        }
        // Weather: handled here (not in execute) so we can carry w.display as a notice banner.
        if isWeatherIntent(normalized) {
            // Tomorrow forecast — must check before extractWeatherForecastHour (which returns nil for "tomorrow")
            if normalized.contains("tomorrow") || normalized.contains("next day") {
                if let s = await OrbitWeatherService.forecastTomorrow() {
                    let tip  = OrbitWeatherService.tip(for: s)
                    let full = tip.map { "\(s) \($0)" } ?? s
                    return Outcome(handled: true, reply: full, appendWakeConversationPrompt: true)
                }
                return Outcome(handled: true, reply: "I couldn\u{2019}t get tomorrow\u{2019}s forecast right now.", appendWakeConversationPrompt: false)
            }
            // Check if the user is asking about a future time today
            if let futureHour = extractWeatherForecastHour(from: normalized) {
                if let forecast = await OrbitWeatherService.forecastSummary(for: futureHour) {
                    let reply = "The forecast shows \(forecast)."
                    let tip = OrbitWeatherService.tip(for: forecast)
                    let full = tip.map { "\(reply) \($0)" } ?? reply
                    return Outcome(handled: true, reply: full, appendWakeConversationPrompt: true)
                }
                return Outcome(handled: true, reply: "I couldn\u{2019}t get the forecast right now.", appendWakeConversationPrompt: false)
            }
            // Current weather
            guard let w = await OrbitWeatherService.fetchHalifax() else {
                return Outcome(
                    handled: true,
                    reply: "I couldn\u{2019}t get the current weather. Check your internet connection.",
                    appendWakeConversationPrompt: false
                )
            }
            let tip = OrbitWeatherService.tip(for: w.spoken)
            let reply = OrbitWeatherService.spokenSummary(spoken: w.spoken, tip: tip)
            return Outcome(
                handled: true,
                reply: reply,
                appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: reply),
                notice: w.display
            )
        }
        // Document summarization: "summarize that PDF", "what's in the document on my desktop"
        if let docQuery = extractDocumentQuery(from: normalized) {
            switch findDocument(query: docQuery) {
            case .exactMatch(let fileURL):
                await OrbitConversationMemory.shared.record(.filePath, value: fileURL.path)
                if let text = extractDocumentText(from: fileURL) {
                    let msg = composeDocumentSummaryMessage(action: docQuery.action, fileName: fileURL.lastPathComponent, text: text)
                    return Outcome(handled: true, reply: "__orbit_doc_llm__" + msg, appendWakeConversationPrompt: true)
                }
                return Outcome(handled: true, reply: "I found \(fileURL.lastPathComponent) but couldn\u{2019}t extract text from it.", appendWakeConversationPrompt: false)
            case .fuzzyMatch(let fileURL, _):
                // Not an exact match — confirm with the user via constellation
                OrbitLocalActionPendingStore.shared.setDocumentPick(paths: [fileURL.path], action: docQuery.action)
                return Outcome(handled: true, reply: "I found a similar file:\n1. \(fileURL.lastPathComponent)\nSay open 1 to use it, or cancel.",
                               appendWakeConversationPrompt: true, isClarificationQuestion: true)
            case .multipleFound(let paths, let action):
                OrbitLocalActionPendingStore.shared.setDocumentPick(paths: paths, action: action)
                let list = paths.enumerated().map { "\($0.offset + 1). \(($0.element as NSString).lastPathComponent)" }.joined(separator: "\n")
                return Outcome(handled: true, reply: "I found \(paths.count) matches:\n\(list)\nSay open 1 through open \(paths.count), or cancel.",
                               appendWakeConversationPrompt: true, isClarificationQuestion: true)
            case .notFound(let hint):
                return Outcome(handled: true, reply: "I couldn\u{2019}t find \u{201C}\(hint)\u{201D} in your Desktop, Documents, or Downloads.", appendWakeConversationPrompt: false)
            }
        }
        // List reminders: "what are my upcoming reminders", "show my reminders", "any reminders"
        if isListRemindersIntent(normalized) {
            return Outcome(handled: true, reply: "__orbit_list_reminders__", appendWakeConversationPrompt: true)
        }
        // List events: "what are my upcoming events", "what's on my calendar"
        if isListEventsIntent(normalized) {
            return Outcome(handled: true, reply: "__orbit_list_events__", appendWakeConversationPrompt: true)
        }
        // List files in folder: "what files I have in my documents", "show files on desktop"
        if let listResult = handleListFilesIntent(normalized) {
            return listResult
        }
        // Shutdown/restart
        if isShutdownIntent(normalized) {
            return Outcome(handled: true, reply: "I can\u{2019}t shut down or restart your Mac by voice for safety reasons. Use Apple menu \u{2192} Shut Down.", appendWakeConversationPrompt: false)
        }
        // Smart home: "turn on bedroom lights" → runs matching macOS Shortcut
        if let homeComponents = extractSmartHomeComponents(normalized) {
            do {
                let reply = try await executeSmartHome(homeComponents)
                return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
            } catch {
                let msg = (error as? ControlError)?.localizedDescription ?? error.localizedDescription
                return Outcome(handled: true, reply: msg, appendWakeConversationPrompt: false)
            }
        }
        // Terminal at folder: must be before parseCommand so "open terminal in documents"
        // isn't stolen by extractSubfolderOpenSpec (which would search for a "terminal" folder).
        if let folder = extractTerminalAtFolderTarget(from: normalized) {
            do {
                let reply = try openTerminalAtFolder(folder)
                return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
            } catch {
                let msg = (error as? ControlError)?.localizedDescription ?? error.localizedDescription
                return Outcome(handled: true, reply: msg, appendWakeConversationPrompt: false)
            }
        }
        // Explicit permission request, run with ORBIT frontmost so macOS actually shows the prompt.
        if normalized.contains("grant permission") || normalized.contains("request permission")
            || normalized.contains("fix permission") || normalized.contains("ask for permission")
            || normalized.contains("enable microphone") || normalized.contains("fix the mic") {
            let report = await OrbitSpeechInputController.requestPermissionsAndReport()
            return Outcome(handled: true, reply: report, appendWakeConversationPrompt: false)
        }
        // Self-check: reports every permission gate ORBIT's system control depends on.
        if normalized.contains("diagnostic") || normalized.contains("diagnose")
            || normalized == "self check" || normalized == "check permissions" {
            return Outcome(
                handled: true,
                reply: await OrbitDisplayBrightness.diagnosticsReport(),
                appendWakeConversationPrompt: false
            )
        }
        // Telemetry: "show missed intents", "what commands did I miss"
        if normalized.contains("missed intent") || normalized.contains("missed command")
            || normalized.contains("what did i miss") || normalized.contains("failed commands")
            || normalized.contains("intent log") || normalized.contains("telemetry")
            || normalized.contains("show me intense") || normalized.contains("show intense")
            || normalized.contains("show intent") || normalized.contains("show me intent") {
            let summary = await OrbitFailureTelemetry.shared.formattedSummary()
            return Outcome(handled: true, reply: summary, appendWakeConversationPrompt: false)
        }
        // Casual greetings deliberately fall through to the brain. They used to be answered from
        // a three-item array picked by timestamp, which meant "how are you" — the most human
        // thing Ayush can ask — never reached the model holding his profile, mood and history,
        // and `user_profile.md`'s "Casual check-ins" guidance never once executed. Offline, the
        // local model still answers conversationally; only the canned strings are gone.
        // Email: must be before parseCommand so "check my emails" isn't caught by file finder.
        if isReadEmailIntent(normalized) {
            guard privacyToggleEnabled("orbitMac.allowEmail") else {
                return Outcome(handled: true, reply: "Email access is turned off in ORBIT\u{2019}s privacy settings. You can enable it in the gear menu.", appendWakeConversationPrompt: false)
            }
            do {
                let reply = try readRecentEmails()
                return Outcome(
                    handled: true,
                    reply: reply,
                    appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: reply)
                )
            } catch {
                let msg = (error as? ControlError)?.localizedDescription ?? error.localizedDescription
                return Outcome(handled: true, reply: msg, appendWakeConversationPrompt: false)
            }
        }
        if !privacyToggleEnabled("orbitMac.allowContacts"),
           isFaceTimeVideoIntent(normalized) || isFaceTimeAudioIntent(normalized) || isMessageIntent(normalized) {
            return Outcome(handled: true, reply: "Contact access is turned off in ORBIT\u{2019}s privacy settings. You can enable it in the gear menu.", appendWakeConversationPrompt: false)
        }
        guard let command = parseCommand(normalized) else {
            // Semantic fallback: keyword-based intent classification catches commands that
            // phrase matching missed (different phrasing, extra words, etc.)
            if let reclassified = await handleClassifiedIntent(normalized, originalText: text) {
                return reclassified
            }
            return Outcome(handled: false, reply: nil, appendWakeConversationPrompt: true)
        }
        do {
            let reply = try await execute(command)
            await recordSystemTarget(for: command)
            return Outcome(
                handled: true,
                reply: reply,
                appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: reply)
            )
        } catch {
            let msg = Self.richErrorMessage(for: error, context: normalized)
            return Outcome(
                handled: true,
                reply: msg,
                appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: msg)
            )
        }
    }

    // MARK: - Command parsing

    private static func parseCommand(_ normalized: String) -> Command? {
        if isOpenFinderIntent(normalized) { return .openFinder }
        if isOpenDownloadsIntent(normalized) { return .openDownloads }
        if isOpenDocumentsIntent(normalized) { return .openDocuments }
        if isOpenDesktopIntent(normalized) { return .openDesktop }
        if isOpenTrashIntent(normalized) { return .openTrash }
        if isEmptyTrashIntent(normalized) { return .emptyTrashPropose }
        if let deleteSpec = extractDeleteFolderSpec(from: normalized) {
            return .deletePropose(name: deleteSpec.name, location: deleteSpec.location)
        }
        // Subfolder nav BEFORE file search: "open PJ in documents" → open folder, not search files
        if let spec = extractSubfolderOpenSpec(from: normalized) {
            return .openSubfolder(name: spec.name, location: spec.location)
        }
        // "open X folder" without a location → scan Desktop/Documents/Downloads (must come before openApp
        // to avoid "open pj folder" being parsed as an app launch).
        if let name = extractOpenFolderNoLocationSpec(from: normalized) {
            return .openFolderAcrossLocations(name)
        }
        if let query = extractFindFileQuery(from: normalized) { return .findFileByName(query) }
        if let spec = extractProjectFolderSpec(from: normalized) {
            return .createProjectFolder(name: spec.name, parent: spec.parent, scaffold: spec.scaffold)
        }
        if let pane = OrbitSystemDeepLinks.inferSettingsPane(from: normalized) {
            return .openSystemSettings(pane)
        }
        if let q = OrbitSystemDeepLinks.extractAppStoreSearchQuery(from: normalized) {
            return .appStoreSearch(q)
        }
        if let q = OrbitSystemDeepLinks.extractGoogleChromeSearchQuery(from: normalized) {
            return .googleSearchChrome(q)
        }
        if let typed = OrbitUIAssist.extractTypeIntoFocusedPayload(from: normalized) {
            return .typeIntoFocusedField(typed)
        }
        if isWakeOrbitIntent(normalized) { return .wakeOrbit }
        if isLockScreenIntent(normalized) { return .lockScreen }
        // Contacts / calls — before openApp so "call John" doesn't hit openApp
        // FaceTime video check must come before audio to avoid "facetime X" matching audio intent
        if isFaceTimeVideoIntent(normalized), let name = extractCallTarget(from: normalized) {
            return .faceTimeVideo(name)
        }
        if isFaceTimeAudioIntent(normalized), let name = extractCallTarget(from: normalized) {
            return .faceTimeAudio(name)
        }
        if isMessageIntent(normalized), let (name, body) = extractMessageComponents(from: normalized) {
            if !name.isEmpty { return .openMessage(name: name, body: body) }
        }
        // Browser — MUST run before extractOpenAppTarget so "open YouTube in Chrome"
        // isn't claimed as openApp("youtube in chrome")
        if let result = parseBrowserIntent(from: normalized) {
            switch result {
            case .navigate(let url, let bundle): return .openInBrowser(url: url, browserBundle: bundle)
            case .search(let query, let bundle): return .searchInBrowser(query: query, browserBundle: bundle)
            }
        }
        if let appName = extractOpenAppTarget(from: normalized) { return .openApp(appName) }
        if let appName = extractQuitAppTarget(from: normalized) { return .quitApp(appName) }
        if isWifiOnIntent(normalized) { return .wifiOn }
        if isWifiOffIntent(normalized) { return .wifiOff }
        if isWifiStatusIntent(normalized) { return .wifiStatus }
        if isBluetoothToolingCheckIntent(normalized) { return .bluetoothToolingCheck }
        if isBluetoothOnIntent(normalized) { return .bluetoothOn }
        if isBluetoothOffIntent(normalized) { return .bluetoothOff }
        if isBluetoothStatusIntent(normalized) { return .bluetoothStatus }
        if isFocusOnIntent(normalized) { return .focusOn }
        if isFocusOffIntent(normalized) { return .focusOff }
        if isFocusStatusIntent(normalized) { return .focusStatus }
        if isBatteryStatusIntent(normalized) { return .batteryStatus }
        if isDarkModeOnIntent(normalized) { return .darkModeOn }
        if isDarkModeOffIntent(normalized) { return .darkModeOff }
        if isDarkModeToggleIntent(normalized) { return .darkModeToggle }
        // Display: brightness before night shift
        if isBrightnessUpIntent(normalized) { return .brightnessUp }
        if isBrightnessDownIntent(normalized) { return .brightnessDown }
        if let pct = extractBrightnessLevel(from: normalized) { return .setBrightness(pct) }
        if isNightShiftOnIntent(normalized) { return .nightShiftOn }
        if isNightShiftOffIntent(normalized) { return .nightShiftOff }
        if isMuteIntent(normalized) { return .mute }
        if isUnmuteIntent(normalized) { return .unmute }
        // setVolume BEFORE up/down: "turn volume down to 50%" → setVolume(50) not volumeDown
        if let level = extractVolumePercent(from: normalized) { return .setVolume(level) }
        if isVolumeUpIntent(normalized) { return .volumeUp }
        if isVolumeDownIntent(normalized) { return .volumeDown }
        // Music — after volume so "turn up volume" doesn't hit music intents
        if isMusicNowPlayingIntent(normalized) { return .musicNowPlaying }
        if isMusicPlayIntent(normalized)       { return .musicPlay }
        if isMusicPauseIntent(normalized)      { return .musicPause }
        if isMusicNextIntent(normalized)       { return .musicNext }
        if isMusicPreviousIntent(normalized)   { return .musicPrevious }
        return nil
    }

    private static func isWeatherIntent(_ normalized: String) -> Bool {
        let phrases = [
            "what's the weather", "what is the weather", "whats the weather",
            "how's the weather", "how is the weather", "hows the weather",
            "weather today", "today's weather", "weather right now",
            "current weather", "weather in halifax", "weather outside",
            "how's it outside", "hows it outside", "what's it like outside",
            "what is it like outside", "check the weather", "weather forecast",
            "what's the temperature", "what is the temperature", "whats the temperature",
            "tell me the weather", "weather update", "what's outside",
            // Forecast phrases
            "weather tonight", "weather this evening", "weather this afternoon",
            "weather tomorrow", "weather later", "will it rain",
            "weather at", "weather in the evening", "weather in the morning",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private static func extractWeatherForecastHour(from normalized: String) -> Int? {
        // "at 6pm" / "at 6 pm"
        if let m = normalized.range(of: #"\bat\s+(\d{1,2})\s*(pm|am)\b"#, options: .regularExpression) {
            let sub = String(normalized[m])
            let digits = sub.filter { $0.isNumber }
            guard var hour = Int(digits) else { return nil }
            if sub.contains("pm") && hour < 12 { hour += 12 }
            if sub.contains("am") && hour == 12 { hour = 0 }
            return hour
        }
        // "at 6" (bare hour)
        if let m = normalized.range(of: #"weather\s+at\s+(\d{1,2})\b"#, options: .regularExpression) {
            let sub = String(normalized[m])
            let digits = sub.filter { $0.isNumber }
            guard var hour = Int(digits) else { return nil }
            if hour >= 1 && hour <= 6 { hour += 12 }
            return hour
        }
        // Named times
        if normalized.contains("tonight") || normalized.contains("night") { return 21 }
        if normalized.contains("this evening") || normalized.contains("evening") { return 18 }
        if normalized.contains("this afternoon") || normalized.contains("afternoon") { return 15 }
        if normalized.contains("this morning") || normalized.contains("morning") {
            let currentHour = Calendar.current.component(.hour, from: Date())
            return currentHour < 12 ? nil : nil // if it's already afternoon, "morning" is past — skip
        }
        if normalized.contains("later today") || normalized.contains("later") {
            let currentHour = Calendar.current.component(.hour, from: Date())
            return min(21, currentHour + 3)
        }
        return nil
    }

    // MARK: - Pending actions handler

    private static func handlePendingLocalActions(_ normalized: String) -> String? {
        // Fuzzy folder confirmation: ORBIT offered a similar-sounding folder, awaiting yes/no.
        if let (url, displayName) = OrbitLocalActionPendingStore.shared.folderConfirmPending() {
            if isFolderConfirmYes(normalized) {
                OrbitLocalActionPendingStore.shared.clearFolderConfirm()
                NSWorkspace.shared.open(url)
                return "Opened \u{201C}\(displayName)\u{201D}."
            }
            if isFolderConfirmNo(normalized) {
                OrbitLocalActionPendingStore.shared.clearFolderConfirm()
                return "Got it \u{2014} I won\u{2019}t open it. Try saying the exact folder name."
            }
            // Unrelated command — clear confirmation and fall through to normal processing.
            OrbitLocalActionPendingStore.shared.clearFolderConfirm()
        }

        // Proactive follow-up: ORBIT asked "did you do it?" — catch yes/no/snooze responses.
        if let info = OrbitLocalActionPendingStore.shared.followupPendingInfo {
            if isFollowupConfirmIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearFollowup()
                UserDefaults.standard.set(Date(), forKey: "orbit.proactive.confirmed.\(info.id)")
                Task { @MainActor in
                    await OrbitReminderService.shared.requestAccessIfNeeded()
                    _ = await OrbitReminderService.shared.completeReminder(matching: info.title)
                }
                return "Great \u{2014} marked \u{201C}\(info.title)\u{201D} as done!"
            }
            if isFollowupTriedButFailedIntent(normalized) {
                // User attempted but couldn't complete (e.g. "I called but no answer").
                // Snooze 60 min and allow re-fire so ORBIT checks in again later.
                OrbitLocalActionPendingStore.shared.clearFollowup()
                UserDefaults.standard.set(
                    Date().addingTimeInterval(60 * 60),
                    forKey: "orbit.proactive.snooze.\(info.id)"
                )
                let failedID = info.id
                Task { @MainActor in OrbitProactiveNotifier.shared.clearFollowupFiredKey(for: failedID) }
                return "Understood \u{2014} I\u{2019}ll check back in an hour so you can try again."
            }
            if isFollowupSnoozeIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearFollowup()
                UserDefaults.standard.set(
                    Date().addingTimeInterval(30 * 60),
                    forKey: "orbit.proactive.snooze.\(info.id)"
                )
                let snoozeID = info.id
                Task { @MainActor in OrbitProactiveNotifier.shared.clearFollowupFiredKey(for: snoozeID) }
                return "Got it \u{2014} I\u{2019}ll check in again in 30 minutes."
            }
            if isFollowupDeclineIntent(normalized) {
                // "Not yet" — snooze 30 min and allow re-fire so the follow-up can repeat.
                OrbitLocalActionPendingStore.shared.clearFollowup()
                UserDefaults.standard.set(
                    Date().addingTimeInterval(30 * 60),
                    forKey: "orbit.proactive.snooze.\(info.id)"
                )
                let declineID = info.id
                Task { @MainActor in OrbitProactiveNotifier.shared.clearFollowupFiredKey(for: declineID) }
                return "No worries \u{2014} I\u{2019}ll check in again in 30 minutes."
            }
            // Unrelated input: clear the pending follow-up and process normally.
            OrbitLocalActionPendingStore.shared.clearFollowup()
        }

        // Spelling-correction flow: user is responding to "can you spell that?" prompt.
        if let ctx = OrbitLocalActionPendingStore.shared.spellingPendingContext {
            if isDeleteOrFilePickCancelIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearSpellingState()
                return "Okay — search cancelled."
            }
            // If the user re-woke ORBIT with the wake phrase instead of spelling, abandon the
            // spelling state and let the input be processed as a fresh command.
            if isWakePhraseInput(normalized) {
                OrbitLocalActionPendingStore.shared.clearSpellingState()
                return nil
            }
            let parsed = parseSpelledInput(normalized)
            if parsed.count >= 2 {
                // Store result; performIfCommand (caller) will consume it and re-run the search.
                OrbitLocalActionPendingStore.shared.setSpellingResult(name: parsed, ctx: ctx)
                return nil
            }
            return "I didn't catch that. Say the letters one by one — like a y u s h. Say space between words: a y u s h space p a t e l. Or say cancel."
        }

        if OrbitLocalActionPendingStore.shared.messageProposalPending() != nil {
            if normalized == "cancel" || normalized.hasPrefix("cancel") || normalized == "no" || normalized == "never mind" {
                OrbitLocalActionPendingStore.shared.clearMessageProposal()
                return "Okay — message cancelled."
            }
            // "yes send message", "yes send it", "send it", "send"
            let sendConfirms = ["yes send message", "yes send it", "send message", "send it", "yes send", "send", "yes"]
            if sendConfirms.contains(where: { normalized == $0 || normalized.hasPrefix($0) }) {
                do { return try confirmAndSendMessage() }
                catch { return (error as? ControlError)?.localizedDescription ?? error.localizedDescription }
            }
            if let (name, _, body) = OrbitLocalActionPendingStore.shared.messageProposalPending() {
                return "Still ready to send to \(name): \u{201C}\(body)\u{201D} — say yes send message or cancel."
            }
        }

        // Terminal command confirmation: user said "run npm install", ORBIT is waiting for yes/cancel.
        if let pending = OrbitLocalActionPendingStore.shared.terminalCommandPending() {
            if isDeleteOrFilePickCancelIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearTerminalCommand()
                return "Okay \u{2014} command cancelled."
            }
            let confirms = ["yes", "yeah", "yep", "yup", "run it", "yes run it", "go ahead",
                            "do it", "execute", "confirm", "yes please", "sure", "ok", "okay"]
            if confirms.contains(where: { normalized == $0 || normalized.hasPrefix($0) }) {
                OrbitLocalActionPendingStore.shared.clearTerminalCommand()
                return executeTerminalCommand(pending.command, directory: pending.directory)
            }
            return "Waiting to run: \(pending.command). Say yes to run, or cancel."
        }

        // Document pick: user said "summarize that PDF" and got a list — now picking by number or name.
        if let docPick = OrbitLocalActionPendingStore.shared.documentPickPending() {
            if isDeleteOrFilePickCancelIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearDocumentPick()
                return "Okay \u{2014} cancelled."
            }
            // Number pick: "1", "2", "open 2", "the second one"
            if let idx = parseDocPickIndex(normalized), idx >= 1, idx <= docPick.paths.count {
                OrbitLocalActionPendingStore.shared.clearDocumentPick()
                let path = docPick.paths[idx - 1]
                let url = URL(fileURLWithPath: path)
                if let text = extractDocumentText(from: url) {
                    let msg = composeDocumentSummaryMessage(action: docPick.action, fileName: url.lastPathComponent, text: text)
                    return "__orbit_doc_llm__" + msg
                }
                return "I couldn\u{2019}t extract text from \(url.lastPathComponent)."
            }
            // Name pick: user said part of a filename
            let lower = normalized.lowercased()
            for (i, path) in docPick.paths.enumerated() {
                let name = (path as NSString).lastPathComponent.lowercased()
                if name.contains(lower) || lower.contains(name.replacingOccurrences(of: ".pdf", with: "")) {
                    OrbitLocalActionPendingStore.shared.clearDocumentPick()
                    let url = URL(fileURLWithPath: docPick.paths[i])
                    if let text = extractDocumentText(from: url) {
                        let msg = composeDocumentSummaryMessage(action: docPick.action, fileName: url.lastPathComponent, text: text)
                        return "__orbit_doc_llm__" + msg
                    }
                    return "I couldn\u{2019}t extract text from \(url.lastPathComponent)."
                }
            }
            return "Say a number (1 through \(docPick.paths.count)) or the file name, or cancel."
        }

        if OrbitLocalActionPendingStore.shared.emptyTrashProposalPending() {
            if isDeleteOrFilePickCancelIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearEmptyTrashProposal()
                return "Okay — I will not empty the Trash."
            }
            if isEmptyTrashConfirmIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearEmptyTrashProposal()
                do {
                    try emptyTrashByRemovingContents()
                    return "Trash has been emptied."
                } catch {
                    return (error as? ControlError)?.localizedDescription
                        ?? "Could not empty Trash: \(error.localizedDescription)"
                }
            }
            return "Still waiting to empty the Trash. Reply yes empty trash to confirm, or cancel."
        }

        if let (deleteURL, summary) = OrbitLocalActionPendingStore.shared.deleteProposalPending() {
            if extractDeleteFolderSpec(from: normalized) != nil {
                OrbitLocalActionPendingStore.shared.clearDeleteProposal()
                return nil
            }
            if isDeleteOrFilePickCancelIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearDeleteProposal()
                return "Okay — I will not delete \(summary)."
            }
            if isDeleteConfirmIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearDeleteProposal()
                do {
                    try moveUserItemToTrash(at: deleteURL)
                    return "Moved to Trash: \(tildeDisplayPath(for: deleteURL)) (\(summary))."
                } catch {
                    return (error as? ControlError)?.localizedDescription
                        ?? "I could not move that to Trash: \(error.localizedDescription)"
                }
            }
            return "I am still waiting to delete \(summary) (\(tildeDisplayPath(for: deleteURL))). Reply yes delete it to confirm, or cancel."
        }

        if let paths = OrbitLocalActionPendingStore.shared.filePickPendingPaths() {
            if isDeleteOrFilePickCancelIntent(normalized) {
                OrbitLocalActionPendingStore.shared.clearFilePick()
                return "Okay — cancelled file pick. Run find again if you need to."
            }
            if normalized.contains("find ") || normalized.contains("search ") || normalized.contains("locate ") {
                OrbitLocalActionPendingStore.shared.clearFilePick()
                return nil
            }
            if let idx = parseOpenPickIndex(normalized) {
                if idx < 1 || idx > paths.count {
                    return "There are only \(paths.count) matches in the current list. Say open 1 through open \(paths.count), or cancel."
                }
                OrbitLocalActionPendingStore.shared.clearFilePick()
                let path = paths[idx - 1]
                let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
                if opened {
                    return "Opened #\(idx): \((path as NSString).lastPathComponent)\n\(tildeDisplayPath(for: URL(fileURLWithPath: path)))"
                }
                return "macOS blocked opening that file. Check System Settings \u{2192} Privacy & Security \u{2192} Files and Folders for ORBITMac."
            }
            return "I still have \(paths.count) matches from your last search. Say open 1 or open 2 (or cancel)."
        }

        return nil
    }

    /// Remembers which system feature a command touched, so a later "turn it back on" resolves.
    @MainActor
    private static func recordSystemTarget(for command: Command) async {
        let target: String?
        switch command {
        case .wifiOn, .wifiOff, .wifiStatus: target = "wifi"
        case .bluetoothOn, .bluetoothOff, .bluetoothStatus: target = "bluetooth"
        case .darkModeOn, .darkModeOff, .darkModeToggle: target = "dark mode"
        case .focusOn, .focusOff, .focusStatus: target = "focus"
        case .mute, .unmute, .volumeUp, .volumeDown, .setVolume: target = "volume"
        case .brightnessUp, .brightnessDown, .setBrightness: target = "brightness"
        default: target = nil
        }
        guard let target else { return }
        OrbitConversationMemory.shared.record(.systemTarget, value: target)
    }

    /// Picks a named Focus mode out of an utterance ("put sleep focus on" → "sleep").
    static func spokenFocusMode(in normalized: String) -> String? {
        for mode in availableFocusModes() where normalized.contains(mode) { return mode }
        if normalized.contains("do not disturb") || normalized.contains("dnd") { return "do not disturb" }
        if normalized.contains("sleep") { return "sleep" }
        if normalized.contains("work") { return "work" }
        return nil
    }

    // MARK: - Privacy toggles

    /// Reads a privacy toggle the way `@AppStorage(_, default: true)` displays it: an absent key
    /// means ON. `UserDefaults.bool(forKey:)` returns false for absent keys, which made fresh
    /// installs show toggles as ON in the menu while the guards treated them as OFF.
    static func privacyToggleEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    // MARK: - Unsupported capability guard

    static func unsupportedCapabilityResponse(for normalized: String) -> String? {
        // Block window-snapping actions that ORBIT never handles (quit/close app is handled by extractQuitAppTarget)
        if normalized.contains("minimize") || normalized.contains("maximise") || normalized.contains("maximize")
            || normalized.contains("left window") || normalized.contains("right window")
            || normalized == "close window" || normalized == "close this window" || normalized == "close the window"
        {
            return "Window management is not supported yet. I can open or quit apps, handle Wi-Fi/focus/volume, and do Finder/file helpers."
        }
        let mentionsMeeting = ["teams", "zoom", "meet", "meeting", "call"].contains { normalized.contains($0) }
        if mentionsMeeting, normalized.contains("unmute") || normalized.contains("mute me") || normalized.contains("mute myself") {
            return "I can't control meeting mute/unmute yet."
        }
        if mentionsMeeting, normalized.contains("camera") || normalized.contains("video") {
            return "I can't control meeting camera/video yet."
        }
        return nil
    }

    // MARK: - Command execution switch

    private static func execute(_ command: Command) async throws -> String {
        switch command {
        case .openSystemSettings(let pane):
            switch OrbitSystemDeepLinks.openSettingsPane(pane) {
            case .openedPane:
                return "Opened \(pane.openSummary)."
            case .openedSystemSettingsAppOnly:
                if pane == .root { return "Opened System Settings." }
                if let hint = pane.fallbackSidebarHint {
                    return "Opened System Settings. This macOS build didn't accept a direct link to that pane — choose **\(hint)** in the sidebar, or search for it in the Settings search field."
                }
                return "Opened System Settings."
            case .failed:
                throw ControlError.actionFailed("Could not open System Settings. Try Apple menu \u{2192} System Settings.")
            }
        case .appStoreSearch(let query):
            if OrbitSystemDeepLinks.openAppStoreSearch(term: query) {
                return "Searching the App Store for \u{201C}\(query)\u{201D}."
            }
            throw ControlError.actionFailed("Could not open the App Store.")
        case .googleSearchChrome(let query):
            if OrbitSystemDeepLinks.openGoogleSearchInChrome(query: query) {
                return "Searching Google in Chrome for \u{201C}\(query)\u{201D}."
            }
            throw ControlError.actionFailed(
                "Could not open Google Chrome. Install Chrome from google.com/chrome or try your default browser with a web search."
            )
        case .typeIntoFocusedField(let text):
            do {
                try OrbitUIAssist.typeIntoFocusedField(text)
                return "Typed into the focused field."
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                throw ControlError.actionFailed(msg)
            }
        case .openApp(let appName):
            let opened = try await openApp(named: appName)
            await OrbitConversationMemory.shared.record(.appName, value: opened)
            return "Opening \(opened)."
        case .openFinder:
            guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                throw ControlError.actionFailed("I couldn't launch Finder on this macOS build.")
            }
            try await openApplication(at: finderURL)
            return "Opening Finder."
        case .openFolderAcrossLocations(let name):
            return findAndOpenFolderAcrossLocations(name: name)
        case .openSubfolder(let name, let location):
            do {
                return try openSubfolderInFinder(name: name, location: location)
            } catch {
                let label: String
                switch location {
                case .desktop: label = "Desktop"
                case .documents: label = "Documents"
                case .downloads: label = "Downloads"
                }
                OrbitLocalActionPendingStore.shared.setSpellingPending(.openSubfolder(locationLabel: label))
                return "I couldn't find \"\(name)\" in your \(label). Can you spell it for me?"
            }
        case .openDownloads:
            return try openFolderInFinder(realUserHomeForFiles().appendingPathComponent("Downloads"), label: "Downloads")
        case .openDocuments:
            return try openFolderInFinder(realUserHomeForFiles().appendingPathComponent("Documents"), label: "Documents")
        case .openDesktop:
            return try openFolderInFinder(realUserHomeForFiles().appendingPathComponent("Desktop"), label: "Desktop")
        case .openTrash:
            return try openFolderInFinder(realUserHomeForFiles().appendingPathComponent(".Trash"), label: "Trash")
        case .emptyTrashPropose:
            OrbitLocalActionPendingStore.shared.setEmptyTrashProposal()
            return """
            This permanently deletes items that are already in your Trash (~/.Trash). This cannot be undone.

            Reply yes empty trash to confirm, or cancel to stop.
            """
        case .findFileByName(let query):
            return try await findAndMaybeOpenFile(named: query)
        case .createProjectFolder(let name, let parent, let scaffold):
            return try createProjectFolderTemplate(named: name, parent: parent, scaffold: scaffold)
        case .deletePropose(let name, let location):
            return try proposeDeleteFolder(named: name, location: location)
        case .wifiOn:
            let iface = try wifiInterfaceObject()
            do {
                try iface.setPower(true)
            } catch {
                if let ifName = iface.interfaceName {
                    _ = try runCommand("/usr/sbin/networksetup", ["-setairportpower", ifName, "on"], failOnNonZero: false)
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let verified = try wifiPowerStatus(), verified else {
                throw ControlError.actionFailed("I tried to turn Wi-Fi on, but macOS did not apply it. If this was your first Wi-Fi command, allow the macOS prompt once and retry.")
            }
            return "Wi-Fi is on."
        case .wifiOff:
            let iface = try wifiInterfaceObject()
            do {
                try iface.setPower(false)
            } catch {
                if let ifName = iface.interfaceName {
                    _ = try runCommand("/usr/sbin/networksetup", ["-setairportpower", ifName, "off"], failOnNonZero: false)
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let verified = try wifiPowerStatus(), !verified else {
                throw ControlError.actionFailed("I tried to turn Wi-Fi off, but macOS did not apply it. If this was your first Wi-Fi command, allow the macOS prompt once and retry.")
            }
            return "Wi-Fi is off."
        case .wifiStatus:
            if let on = try wifiPowerStatus() {
                return on ? "Wi-Fi is currently on." : "Wi-Fi is currently off."
            }
            let iface = try wifiInterfaceObject()
            return iface.powerOn() ? "Wi-Fi is currently on." : "Wi-Fi is currently off."
        case .bluetoothOn:
            try setBluetooth(enabled: true)
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let status = try bluetoothStatus(), status == true else {
                throw ControlError.actionFailed("I tried to turn Bluetooth on, but macOS did not apply it.")
            }
            return "Bluetooth is on."
        case .bluetoothOff:
            try setBluetooth(enabled: false)
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let status = try bluetoothStatus(), status == false else {
                throw ControlError.actionFailed("I tried to turn Bluetooth off, but macOS did not apply it.")
            }
            return "Bluetooth is off."
        case .bluetoothStatus:
            if let status = try bluetoothStatus() {
                return status ? "Bluetooth is currently on." : "Bluetooth is currently off."
            }
            throw ControlError.actionFailed(
                "I couldn't read Bluetooth state. Add the `blueutil` binary next to ORBITMac (see README: bundled blueutil), or install with Homebrew (`brew install blueutil`) so ORBIT can run it."
            )
        case .bluetoothToolingCheck:
            if let path = blueutilPath() {
                return "blueutil is available at \(path). Bluetooth on, off, and status use it."
            }
            return "blueutil was not found (checked the app bundle first, then Homebrew paths). Copy `blueutil` into the app bundle as an auxiliary executable, or run `brew install blueutil`. Without it, ORBIT cannot reliably toggle or read Bluetooth state."
        case .focusOn:
            return try setFocusMode(mode: nil, enabled: true)
        case .focusOff:
            return try setFocusMode(mode: nil, enabled: false)
        case .focusStatus:
            // Reads via the user's "Get Current Focus" Shortcut. The old path asked
            // `doNotDisturbStatus()`, which reads the same preferences key modern macOS ignores
            // when writing — so switching Focus was fixed to use Shortcuts while *reading* it was
            // left on the dead API, and always answered "this macOS version may not expose it".
            return try currentFocusStatus()
        case .darkModeOn:
            try setDarkMode(enabled: true)
            return "Dark mode on."
        case .darkModeOff:
            try setDarkMode(enabled: false)
            return "Dark mode off."
        case .darkModeToggle:
            try toggleDarkMode()
            return "Dark mode toggled."
        case .batteryStatus:
            let result = try runCommand("/usr/bin/pmset", ["-g", "batt"])
            let text = result.stdout
            if let m = text.range(of: #"\d+%"#, options: .regularExpression) {
                let pct = String(text[m])
                let source = text.lowercased().contains("ac power") ? "charging" : "on battery"
                return "Battery is \(pct), \(source)."
            }
            return "I couldn\u{2019}t read battery details. The power management tool didn\u{2019}t return data."
        case .mute:
            try runAppleScript("set volume with output muted")
            return "Muted."
        case .unmute:
            try runAppleScript("set volume without output muted")
            return "Unmuted."
        case .volumeUp:
            let next = min(100, currentOutputVolume() + 10)
            try runAppleScript("set volume output volume \(next)")
            return "Volume set to \(next)%."
        case .volumeDown:
            let next = max(0, currentOutputVolume() - 10)
            try runAppleScript("set volume output volume \(next)")
            return "Volume set to \(next)%."
        case .setVolume(let level):
            let clamped = max(0, min(100, level))
            try runAppleScript("set volume output volume \(clamped)")
            return "Volume set to \(clamped)%."
        case .lockScreen:
            // Announce first, then lock after TTS has time to play.
            // Locking immediately made the screen go dark mid-sentence and caused the
            // voice synthesizer to switch to a different (non-cached) voice after the lock.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                try? OrbitMacControlCenter.lockScreen()
            }
            return "Locking your screen now."
        case .quitApp(let appName):
            return try quitApp(named: appName)
        case .wakeOrbit:
            return "Still here! Go ahead."
        // MARK: Contacts / calls / messages
        case .faceTimeVideo(let name):
            return try await faceTimeCall(contactName: name, audioOnly: false)
        case .faceTimeAudio(let name):
            return try await faceTimeCall(contactName: name, audioOnly: true)
        case .openMessage(let name, let body):
            return try await openMessageConversation(contactName: name, body: body)
        case .sendMessageConfirm:
            return try confirmAndSendMessage()
        // MARK: Browser
        case .openInBrowser(let url, let bundle):
            return try openURLInBrowser(url, browserBundle: bundle)
        case .searchInBrowser(let query, let bundle):
            return try searchInBrowser(query: query, browserBundle: bundle)
        // MARK: Music
        case .musicPlay:
            return try musicPlay()
        case .musicPause:
            return try musicPause()
        case .musicNext:
            return try musicNext()
        case .musicPrevious:
            return try musicPrevious()
        case .musicNowPlaying:
            return try musicNowPlaying()
        // MARK: Display
        case .brightnessUp:
            return try adjustBrightness(up: true)
        case .brightnessDown:
            return try adjustBrightness(up: false)
        case .setBrightness(let pct):
            return try setBrightnessLevel(pct)
        case .nightShiftOn:
            return try setNightShift(enabled: true)
        case .nightShiftOff:
            return try setNightShift(enabled: false)
        }
    }

    // MARK: - Wake conversation prompt heuristic

    private static func inferAppendWakeConversationPrompt(for reply: String?) -> Bool {
        guard let text = reply?.lowercased(), !text.isEmpty else { return true }
        if text.contains("reply yes ") { return false }
        if text.contains("until you confirm") { return false }
        if text.contains("say open ") { return false }
        if text.contains("still waiting") { return false }
        if text.contains("open 1 through open") { return false }
        if text.contains("i still have ") && text.contains("matches") { return false }
        if text.contains("cancel to stop") && text.contains("confirm") { return false }
        if text.contains("cancel to dismiss") { return false }
        if text.contains("open 1"), text.contains("closest") { return false }
        // Screen lock ends the voice session — do not resume the voice loop after locking
        if text.hasPrefix("screen locked") || text.hasPrefix("locking your screen") { return false }
        // Spelling prompts end the voice turn — user re-triggers after spelling out the name
        if text.contains("spell it for me") || text.contains("spell out the name") { return false }
        if text.contains("say each letter") { return false }
        // Wake-while-listening already invites speech — no "is there anything else?" suffix
        if text.hasPrefix("still here") { return false }
        // Error / failure messages end the voice turn — do not append a time-based farewell
        // (e.g. "App not found. Have a good night!" is jarring and wrong)
        if text.contains("not found") || text.contains("couldn't") || text.contains("couldn\u{2019}t") { return false }
        if text.contains("i can't") || text.contains("i can\u{2019}t") { return false }
        if text.contains("failed") || text.contains("error") || text.contains("sorry, i") { return false }
        if text.contains("permission") && text.contains("off") { return false }
        return true
    }

    // MARK: - Spelling input parser

    /// Converts a spoken spelling reply into a usable search name.
    ///
    /// - "a y u s h" → "ayush"
    /// - "ayush space patel" → "ayush patel"
    /// - "a y u s h space p a t e l" → "ayush patel"
    // MARK: - Follow-up intent helpers

    /// "Yes I did", "done", "yes called her", etc.
    private static func isFollowupConfirmIntent(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        // Short unambiguous single-word confirms
        if words.count <= 2 {
            let confirmsShort = Set(["yes", "yeah", "yep", "yup", "done", "completed", "finished", "did"])
            if words.first.map({ confirmsShort.contains($0) }) == true { return true }
        }
        // Phrase confirms
        let phrases = [
            "yes i did", "yes done", "i did it", "i made it", "i made the call",
            "yes i made", "yes called", "yes submitted", "yes finished", "yes completed",
            "i've done", "i have done", "done it", "its done", "it is done",
            "i called", "i spoke", "i sent", "i submitted",
        ]
        return phrases.contains { text.contains($0) }
    }

    /// "Remind me later", "snooze", "not right now", etc.
    private static func isFollowupSnoozeIntent(_ text: String) -> Bool {
        let phrases = [
            "remind me later", "remind me in", "snooze", "not right now",
            "in 30", "later please", "check later", "ask me later",
        ]
        return phrases.contains { text.contains($0) }
    }

    /// Short "no", "not yet", "nope", etc. — only catches unambiguous short declines.
    private static func isFollowupDeclineIntent(_ text: String) -> Bool {
        if text == "no" || text == "nope" || text == "not yet" || text == "nah" { return true }
        let phrases = ["not yet", "haven't yet", "didn't get to", "no i haven't", "no not yet"]
        return phrases.contains { text.contains($0) }
    }

    /// "I tried but no answer", "called but she didn't pick up", "went to voicemail", etc.
    private static func isFollowupTriedButFailedIntent(_ text: String) -> Bool {
        let phrases = [
            "tried but", "called but", "no answer", "didn't answer", "not answering",
            "didn't pick up", "couldn't reach", "went to voicemail", "voicemail",
            "wasn't available", "wasn't there", "wasn't home",
            "tried to call", "attempted", "tried calling",
        ]
        return phrases.contains { text.contains($0) }
    }

    private static func isFolderConfirmYes(_ text: String) -> Bool {
        let yesWords = Set(["yes", "yeah", "yep", "yup", "sure", "correct", "right", "ok", "okay", "open", "please"])
        let words = text.split(separator: " ").map(String.init)
        if words.count <= 3, words.first.map({ yesWords.contains($0) }) == true { return true }
        let phrases = ["open it", "yes open", "go ahead", "that's it", "that's the one", "that one", "yes please"]
        return phrases.contains { text.contains($0) }
    }

    private static func isFolderConfirmNo(_ text: String) -> Bool {
        let noWords = Set(["no", "nope", "nah", "cancel", "wrong", "stop"])
        let words = text.split(separator: " ").map(String.init)
        if words.count <= 3, words.first.map({ noWords.contains($0) }) == true { return true }
        let phrases = ["not that", "not the one", "wrong folder", "never mind", "don't open", "that's not"]
        return phrases.contains { text.contains($0) }
    }

    static func parseSpelledInput(_ normalized: String) -> String {
        guard !normalized.isEmpty else { return "" }

        // Sentinels for spoken separators → their character equivalents.
        let spaceSent     = "\u{F8FF}"  // "space"     → " "
        let underscoreSent = "\u{F8FE}" // "underscore" → "_"
        let dashSent      = "\u{F8FD}"  // "dash"/"hyphen" → "-"

        var working = " \(normalized) "
        working = working.replacingOccurrences(of: " space ",      with: " \(spaceSent) ")
        working = working.replacingOccurrences(of: " underscore ", with: " \(underscoreSent) ")
        working = working.replacingOccurrences(of: " dash ",       with: " \(dashSent) ")
        working = working.replacingOccurrences(of: " hyphen ",     with: " \(dashSent) ")
        working = working.trimmingCharacters(in: .whitespaces)

        let sepMap: [String: Character] = [spaceSent: " ", underscoreSent: "_", dashSent: "-"]

        let tokens = working.split(separator: " ").map(String.init)

        // Build (letterGroup, separatorAfterGroup) pairs.
        // The separator stored in each pair is what to insert BEFORE the NEXT group.
        var segments: [(group: [String], sep: Character)] = []
        var current: [String] = []
        for token in tokens {
            if let sep = sepMap[token] {
                segments.append((current, sep))
                current = []
            } else {
                current.append(token)
            }
        }
        segments.append((current, " "))  // flush final group (sep not used)

        var result = ""
        var pendingSep: Character = " "
        for seg in segments {
            let group = seg.group
            if group.isEmpty {
                // Consecutive sentinels — prefer the most recent separator.
                pendingSep = seg.sep
                continue
            }
            let word = group.allSatisfy({ $0.count == 1 })
                ? group.joined()                    // individual letters → word
                : group.joined(separator: " ")      // already a word / phrase
            if result.isEmpty {
                result = word
            } else {
                result += String(pendingSep) + word
            }
            pendingSep = seg.sep
        }
        return result
    }

    // MARK: - Rich error messages

    static func richErrorMessage(for error: Error, context: String = "") -> String {
        if let ce = error as? ControlError { return ce.localizedDescription ?? "Something went wrong." }
        let nsError = error as NSError
        let code = nsError.code
        let domain = nsError.domain

        // AppleScript / automation permission errors
        if domain == "NSAppleScriptErrorDomain" || domain.contains("AppleScript") {
            if nsError.localizedDescription.contains("not allowed") || code == -1743 {
                return "macOS blocked that action \u{2014} ORBIT needs Automation permission. Go to System Settings \u{2192} Privacy & Security \u{2192} Automation, and allow ORBITMac for the app involved."
            }
            return "The automation script failed: \(nsError.localizedDescription.prefix(120))"
        }
        // Sandbox / file access errors
        if domain == NSCocoaErrorDomain {
            if code == 257 || code == 513 { // read/write permission denied
                return "macOS blocked file access. Check System Settings \u{2192} Privacy & Security \u{2192} Files and Folders \u{2014} make sure ORBITMac has access."
            }
            if code == 260 || code == 4 { // file not found
                return "That file or folder doesn\u{2019}t exist. It may have been moved or deleted."
            }
        }
        // Process/command errors
        if domain == NSPOSIXErrorDomain {
            if code == 2 { return "Command not found. The tool might not be installed." }
            if code == 13 { return "Permission denied. The command needs elevated access." }
        }
        // App launch errors
        if domain == "NSOSStatusErrorDomain" {
            if code == -10814 { return "That app isn\u{2019}t installed on this Mac." }
            if code == -600 { return "The app couldn\u{2019}t be launched. It might be damaged or incompatible." }
        }
        // Network errors
        if domain == NSURLErrorDomain {
            if code == -1009 { return "No internet connection. Check your Wi-Fi." }
            if code == -1001 { return "The request timed out. Try again in a moment." }
            return "Network error: \(nsError.localizedDescription.prefix(100))"
        }
        // Generic fallback — include the domain for debugging
        let detail = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty || detail == "The operation couldn\u{2019}t be completed." {
            return "Something went wrong (\(domain) \(code)). Try the command again."
        }
        return detail
    }

    // MARK: - Semantic intent fallback

    private static func handleClassifiedIntent(_ normalized: String, originalText: String) async -> Outcome? {
        guard let intent = OrbitIntentClassifier.classify(normalized) else { return nil }
        switch intent {
        case .weather:
            guard let w = await OrbitWeatherService.fetchHalifax() else {
                return Outcome(handled: true, reply: "I couldn\u{2019}t get the weather right now.", appendWakeConversationPrompt: false)
            }
            let tip = OrbitWeatherService.tip(for: w.spoken)
            let reply = OrbitWeatherService.spokenSummary(spoken: w.spoken, tip: tip)
            return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true, notice: w.display)

        case .email:
            guard privacyToggleEnabled("orbitMac.allowEmail") else {
                return Outcome(handled: true, reply: "Email access is turned off in ORBIT\u{2019}s privacy settings. You can enable it in the gear menu.", appendWakeConversationPrompt: false)
            }
            do {
                let reply = try readRecentEmails()
                return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: reply))
            } catch {
                return Outcome(handled: true, reply: (error as? ControlError)?.localizedDescription ?? error.localizedDescription, appendWakeConversationPrompt: false)
            }

        case .noteCreate:
            OrbitLocalActionPendingStore.shared.setNoteBodyPending()
            return Outcome(handled: true, reply: "Sure! What would you like to note down?", appendWakeConversationPrompt: true, isClarificationQuestion: true)

        case .noteAppend:
            return nil // let the regular flow handle append with context

        case .reminder, .calendar:
            return nil // let the broker handle these — it has multi-turn state

        case .terminal(let cmd):
            if let command = cmd, !command.isEmpty {
                let corrected = correctCommonMishearings(command)
                if isBlockedCommand(corrected) {
                    return Outcome(handled: true, reply: "That command looks dangerous.", appendWakeConversationPrompt: false)
                }
                return Outcome(handled: true, reply: proposeTerminalCommand(corrected), appendWakeConversationPrompt: false)
            }
            return nil

        case .document:
            // Re-try document query extraction with the classifier's confidence
            if let query = extractDocumentQuery(from: normalized) {
                let result = findDocument(query: query)
                switch result {
                case .exactMatch(let url):
                    if let docText = extractDocumentText(from: url) {
                        let msg = composeDocumentSummaryMessage(action: query.action, fileName: url.lastPathComponent, text: docText)
                        return Outcome(handled: true, reply: "__orbit_doc_llm__" + msg, appendWakeConversationPrompt: true)
                    }
                case .fuzzyMatch(let url, _):
                    OrbitLocalActionPendingStore.shared.setDocumentPick(paths: [url.path], action: query.action)
                    return Outcome(handled: true, reply: "I found a similar file:\n1. \(url.lastPathComponent)\nSay open 1 to use it, or cancel.", appendWakeConversationPrompt: false)
                case .multipleFound(let paths, _):
                    OrbitLocalActionPendingStore.shared.setDocumentPick(paths: paths, action: query.action)
                    let list = paths.enumerated().map { "\($0.offset + 1). \(($0.element as NSString).lastPathComponent)" }.joined(separator: "\n")
                    return Outcome(handled: true, reply: "I found \(paths.count) matches:\n\(list)\nSay open 1 through open \(paths.count), or cancel.", appendWakeConversationPrompt: false)
                case .notFound(let hint):
                    return Outcome(handled: true, reply: "I couldn\u{2019}t find \u{201C}\(hint)\u{201D}.", appendWakeConversationPrompt: false)
                }
            }
            return nil

        case .smartHome:
            if let components = extractSmartHomeComponents(normalized) {
                do {
                    let reply = try await executeSmartHome(components)
                    return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
                } catch {
                    return Outcome(handled: true, reply: (error as? ControlError)?.localizedDescription ?? error.localizedDescription, appendWakeConversationPrompt: false)
                }
            }
            return nil

        case .openApp(let name):
            do {
                let opened = try await openApp(named: name)
                return Outcome(handled: true, reply: "Opening \(opened).", appendWakeConversationPrompt: true)
            } catch {
                return Outcome(handled: true, reply: (error as? ControlError)?.localizedDescription ?? error.localizedDescription, appendWakeConversationPrompt: true)
            }

        case .closeApp(let name):
            do {
                let reply = try quitApp(named: name)
                return Outcome(handled: true, reply: reply, appendWakeConversationPrompt: true)
            } catch {
                return Outcome(handled: true, reply: (error as? ControlError)?.localizedDescription ?? error.localizedDescription, appendWakeConversationPrompt: true)
            }

        case .musicPlay:
            do { return Outcome(handled: true, reply: try musicPlay(), appendWakeConversationPrompt: true) }
            catch { return Outcome(handled: true, reply: error.localizedDescription, appendWakeConversationPrompt: true) }
        case .musicPause:
            do { return Outcome(handled: true, reply: try musicPause(), appendWakeConversationPrompt: true) }
            catch { return Outcome(handled: true, reply: error.localizedDescription, appendWakeConversationPrompt: true) }
        case .musicNext:
            do { return Outcome(handled: true, reply: try musicNext(), appendWakeConversationPrompt: true) }
            catch { return Outcome(handled: true, reply: error.localizedDescription, appendWakeConversationPrompt: true) }

        case .volumeUp:
            let next = min(100, currentOutputVolume() + 10)
            try? runAppleScript("set volume output volume \(next)")
            return Outcome(handled: true, reply: "Volume set to \(next)%.", appendWakeConversationPrompt: true)
        case .volumeDown:
            let next = max(0, currentOutputVolume() - 10)
            try? runAppleScript("set volume output volume \(next)")
            return Outcome(handled: true, reply: "Volume set to \(next)%.", appendWakeConversationPrompt: true)
        case .mute:
            try? runAppleScript("set volume with output muted")
            return Outcome(handled: true, reply: "Muted.", appendWakeConversationPrompt: true)
        case .unmute:
            try? runAppleScript("set volume without output muted")
            return Outcome(handled: true, reply: "Unmuted.", appendWakeConversationPrompt: true)

        case .darkModeOn:
            try? setDarkMode(enabled: true)
            return Outcome(handled: true, reply: "Dark mode on.", appendWakeConversationPrompt: true)
        case .darkModeOff:
            try? setDarkMode(enabled: false)
            return Outcome(handled: true, reply: "Dark mode off.", appendWakeConversationPrompt: true)
        case .focusOn:
            do { return Outcome(handled: true, reply: try setFocusMode(mode: spokenFocusMode(in: normalized), enabled: true), appendWakeConversationPrompt: true) }
            catch { return Outcome(handled: true, reply: (error as? ControlError)?.localizedDescription ?? error.localizedDescription, appendWakeConversationPrompt: false) }
        case .focusOff:
            do { return Outcome(handled: true, reply: try setFocusMode(mode: spokenFocusMode(in: normalized), enabled: false), appendWakeConversationPrompt: true) }
            catch { return Outcome(handled: true, reply: (error as? ControlError)?.localizedDescription ?? error.localizedDescription, appendWakeConversationPrompt: false) }

        case .batteryStatus:
            if let result = try? runCommand("/usr/bin/pmset", ["-g", "batt"]) {
                if let m = result.stdout.range(of: #"\d+%"#, options: .regularExpression) {
                    let pct = String(result.stdout[m])
                    let source = result.stdout.lowercased().contains("ac power") ? "charging" : "on battery"
                    return Outcome(handled: true, reply: "Battery is \(pct), \(source).", appendWakeConversationPrompt: true)
                }
            }
            return Outcome(handled: true, reply: "I couldn\u{2019}t read battery details.", appendWakeConversationPrompt: true)

        case .lockScreen:
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { try? lockScreen() }
            return Outcome(handled: true, reply: "Locking your screen now.", appendWakeConversationPrompt: false)

        case .brightness:
            return nil // too ambiguous without up/down/level — let it go to LLM
        }
    }

    // MARK: - Global affirmation stripping

    private static func stripLeadingAffirmationGlobal(_ text: String) -> String {
        let prefixes = [
            "yes please ", "yeah sure ", "yes sure ", "sure thing ",
            "yes ", "yeah ", "sure ", "ok ", "okay ", "yep ", "yup ",
            "yes, ", "yeah, ", "sure, ", "ok, ", "okay, ", "yep, ", "yup, ",
            "can you please ", "could you please ",
            "can you ", "could you ", "would you ", "will you ",
            "i want you to ", "i want to ", "i'd like to ", "i would like to ",
            "please ",
        ]
        for p in prefixes where text.hasPrefix(p) {
            let stripped = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return stripped }
        }
        return text
    }

    // MARK: - Multi-step command chaining

    private static func canHandleLocally(_ normalized: String) -> Bool {
        if isNotesCreateIntent(normalized) { return true }
        if isNotesAppendIntent(normalized) { return true }
        if isWeatherIntent(normalized) { return true }
        return parseCommand(normalized) != nil
    }

    private static func tryChainedExecution(text: String, normalized: String) async -> Outcome? {
        let connectors = [" and then ", " then ", " and also ", " also ", " and "]
        for connector in connectors {
            guard let normRange = normalized.range(of: connector) else { continue }
            let firstNorm = String(normalized[..<normRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let secondNorm = String(normalized[normRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !firstNorm.isEmpty, !secondNorm.isEmpty,
                  canHandleLocally(firstNorm), canHandleLocally(secondNorm) else { continue }

            // Split the original text at the same connector (case-insensitive)
            let textLower = text.lowercased()
            guard let textRange = textLower.range(of: connector) else { continue }
            let firstText = String(text[..<textRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let secondText = String(text[textRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !firstText.isEmpty, !secondText.isEmpty else { continue }

            let first = await performIfCommand(firstText, allowChaining: false)
            // Brief pause so app launches / system changes settle before the next step
            if first.handled { try? await Task.sleep(nanoseconds: 400_000_000) }
            let second = await performIfCommand(secondText, allowChaining: false)

            guard first.handled || second.handled else { continue }
            let replies = [first.reply, second.reply].compactMap { $0 }
            let combined = replies.joined(separator: " ")
            return Outcome(
                handled: true,
                reply: combined.isEmpty ? "Done." : combined,
                appendWakeConversationPrompt: inferAppendWakeConversationPrompt(for: combined)
            )
        }
        return nil
    }
}
