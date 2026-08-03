//
//  ContentView+Actions.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    // MARK: - Tools section container

    var toolsSection: some View {
        VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
            orbitSectionTitle("Tools")
            VStack(alignment: .leading, spacing: 10) {
                calendarDisclosure
                microsoft365Disclosure
                actionsDisclosure
                memoryDisclosure
                orbitMindDisclosure
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: ORBITLayout.cardCorner, style: .continuous)
                    .fill(.quaternary.opacity(ORBITLayout.cardFillOpacity * 0.85))
            }
            .overlay {
                RoundedRectangle(cornerRadius: ORBITLayout.cardCorner, style: .continuous)
                    .strokeBorder(.separator.opacity(ORBITLayout.cardStrokeOpacity * 0.9), lineWidth: 1)
            }
        }
    }

    // MARK: - Actions disclosure

    var actionsDisclosure: some View {
        DisclosureGroup(isExpanded: $actionsExpanded) {
            VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
                actionFeedbackBanner

                if actionsActiveTool == nil {
                    actionsToolChooser
                } else {
                    actionsBackRow

                    switch actionsActiveTool {
                    case .shortcut:
                        shortcutToolContent
                    case .calendarEvent:
                        calendarToolContent
                    case .webAgent:
                        webAgentToolContent
                    case .communicationDraft:
                        communicationDraftToolContent
                    case .none:
                        EmptyView()
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Actions")
                        .font(.subheadline.weight(.medium))
                    Text("Shortcut, calendar, or web agent \u{00B7} confirms before running")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    var actionsToolChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What would you like to do?")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    clearActionFeedback()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        actionsActiveTool = .shortcut
                    }
                } label: {
                    Label("Shortcut", systemImage: "command.square.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    clearActionFeedback()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        actionsActiveTool = .calendarEvent
                    }
                } label: {
                    Label("Calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    clearActionFeedback()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        actionsActiveTool = .webAgent
                    }
                } label: {
                    Label("Web Agent", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    clearActionFeedback()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        actionsActiveTool = .communicationDraft
                    }
                } label: {
                    Label("Comms Draft", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    var actionsBackRow: some View {
        HStack {
            Button {
                clearActionFeedback()
                returnActionsToChooser()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Shortcut tool

    var shortcutToolContent: some View {
        VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
            Text("Run Shortcut")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(
                "Pick from your library (loaded via the system `shortcuts` tool) or type a name. Runs use that tool when possible so ORBIT can report real failures."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await loadShortcutList() }
                } label: {
                    Label("Refresh list", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingShortcutList)
                .font(.caption)

                if isLoadingShortcutList {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            if let shortcutListError {
                Text(shortcutListError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Search shortcuts", text: $shortcutListFilter)
                .textFieldStyle(.roundedBorder)
                .disabled(shortcutLibrary.isEmpty && shortcutListError == nil)

            ZStack(alignment: .center) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredShortcutLibrary) { entry in
                            Button {
                                shortcutPick = entry
                                shortcutManualName = ""
                            } label: {
                                HStack(spacing: 8) {
                                    Text(entry.name)
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if shortcutPick?.id == entry.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(shortcutPick?.id == entry.id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.35))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 200)
                .scrollIndicators(.hidden)

                if shortcutLibrary.isEmpty, !isLoadingShortcutList, shortcutListError == nil {
                    Text("List will load when this panel opens.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            TextField("Or type the exact name from Shortcuts", text: $shortcutManualName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: shortcutManualName) { old, new in
                    let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    let previous = old.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        shortcutPick = nil
                        if pendingShortcut != nil {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                pendingShortcut = nil
                            }
                        }
                    } else if !previous.isEmpty, shortcutPick == nil, pendingShortcut != nil {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            pendingShortcut = nil
                        }
                    }
                }

            TextField("Optional text input", text: $shortcutInputDraft)
                .textFieldStyle(.roundedBorder)

            Button("Prepare shortcut run\u{2026}") {
                let manual = shortcutManualName.trimmingCharacters(in: .whitespacesAndNewlines)
                let input = shortcutInputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let name: String
                let runToken: String
                if !manual.isEmpty {
                    name = manual
                    runToken = manual
                } else if let pick = shortcutPick {
                    name = pick.name
                    runToken = pick.id
                } else {
                    return
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    pendingShortcut = (name, runToken, input.isEmpty ? nil : input)
                }
            }
            .disabled(!shortcutPrepareEnabled)

            if let s = pendingShortcut {
                inlineShortcutConfirmCard(s)
            }
        }
        .onChange(of: shortcutPick) { _, newPick in
            syncPendingShortcutAfterPickChange(newPick)
        }
        .onChange(of: shortcutInputDraft) { _, _ in
            syncPendingShortcutInputFromDraft()
        }
        .task(id: actionsActiveTool) {
            guard actionsActiveTool == .shortcut else { return }
            await loadShortcutList()
        }
    }

    // MARK: - Calendar event tool

    var calendarToolContent: some View {
        VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
            Text("New calendar event")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Title", text: $newEventTitle)
                .textFieldStyle(.roundedBorder)

            DatePicker("Starts", selection: $newEventStart, displayedComponents: [.date, .hourAndMinute])

            Picker("Duration", selection: $newEventDurationMinutes) {
                Text("15 min").tag(15)
                Text("30 min").tag(30)
                Text("60 min").tag(60)
                Text("90 min").tag(90)
            }
            .pickerStyle(.segmented)

            TextField("Notes (optional)", text: $newEventNotes, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            Button("Review before adding\u{2026}") {
                let title = newEventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                let end = Calendar.current.date(
                    byAdding: .minute,
                    value: newEventDurationMinutes,
                    to: newEventStart
                ) ?? newEventStart
                let notes = newEventNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    pendingCalendarEvent = (
                        title,
                        newEventStart,
                        end,
                        notes.isEmpty ? nil : notes
                    )
                }
            }
            .disabled(newEventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let ev = pendingCalendarEvent {
                inlineCalendarConfirmCard(ev)
            }
        }
        .onChange(of: newEventTitle) { _, _ in syncPendingCalendarFromForm() }
        .onChange(of: newEventStart) { _, _ in syncPendingCalendarFromForm() }
        .onChange(of: newEventDurationMinutes) { _, _ in syncPendingCalendarFromForm() }
        .onChange(of: newEventNotes) { _, _ in syncPendingCalendarFromForm() }
    }

    // MARK: - Web agent tool

    var webAgentToolContent: some View {
        VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
            Text("Browser/Web Action Agent (semi-automated)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Open a site, run a search, summarize a page, or draft a response from a page. Every action is review + confirm first.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    webAgentModeButton(.openSite)
                    webAgentModeButton(.searchWeb)
                }
                HStack(spacing: 8) {
                    webAgentModeButton(.summarizePage)
                    webAgentModeButton(.draftFromPage)
                }
            }

            if webAgentMode == .searchWeb {
                TextField("Search query (web)", text: $webSearchDraft)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("Prepare web search\u{2026}") {
                        let q = webSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !q.isEmpty, let url = WebActionService.searchURL(for: q) else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            pendingWebAction = .webSearch(query: q, url: url)
                        }
                    }
                    .disabled(webSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .font(.caption)
                    Spacer(minLength: 0)
                }
            } else {
                TextField("Site URL (example: openai.com or https://example.com)", text: $webURLDraft)
                    .textFieldStyle(.roundedBorder)
                if webAgentMode == .openSite {
                    HStack(spacing: 10) {
                        Button("Prepare open site\u{2026}") {
                            guard let url = WebActionService.normalizeURL(from: webURLDraft) else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                pendingWebAction = .openSite(url: url)
                            }
                        }
                        .disabled(WebActionService.normalizeURL(from: webURLDraft) == nil)
                        .font(.caption)
                        Spacer(minLength: 0)
                    }
                } else if webAgentMode == .summarizePage {
                    HStack(spacing: 10) {
                        Button("Prepare summarize page\u{2026}") {
                            guard let url = WebActionService.normalizeURL(from: webURLDraft) else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                pendingWebAction = .summarize(url: url)
                            }
                        }
                        .disabled(WebActionService.normalizeURL(from: webURLDraft) == nil)
                        .font(.caption)
                        Spacer(minLength: 0)
                    }
                } else {
                    TextField("Draft request from page (optional context)", text: $webDraftRequest, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        Button("Prepare draft response from page\u{2026}") {
                            guard let url = WebActionService.normalizeURL(from: webURLDraft) else { return }
                            let req = webDraftRequest.trimmingCharacters(in: .whitespacesAndNewlines)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                pendingWebAction = .draftReply(url: url, request: req.isEmpty ? nil : req)
                            }
                        }
                        .disabled(WebActionService.normalizeURL(from: webURLDraft) == nil)
                        .font(.caption)
                        Spacer(minLength: 0)
                    }
                }
            }

            if let action = pendingWebAction {
                inlineWebActionConfirmCard(action)
            }
        }
        .onChange(of: webAgentMode) { _, _ in
            withAnimation(.easeOut(duration: 0.18)) {
                pendingWebAction = nil
            }
        }
    }

    // MARK: - Communication draft tool

    var communicationDraftToolContent: some View {
        VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
            Text("Communication Drafting (draft-only)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Draft email/Slack/Teams replies, meeting follow-ups, and status updates. ORBIT drafts only \u{2014} it does not send.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Channel")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                OrbitCommDraftChannelPopUp(selection: $commDraftChannel)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("What should I draft? (for example: draft a reply to copied email)", text: $commDraftInstruction, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            TextField("Extra context (optional)", text: $commDraftContext, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button("Prepare communication draft\u{2026}") {
                    let req = OrbitCommunicationDraftRequest(
                        channel: commDraftChannel,
                        userInstruction: commDraftInstruction.trimmingCharacters(in: .whitespacesAndNewlines),
                        extraContext: commDraftContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : commDraftContext.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        pendingCommDraft = req
                    }
                }
                .disabled(commDraftInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .font(.caption)
                Spacer(minLength: 0)
            }

            if let req = pendingCommDraft {
                inlineCommunicationDraftConfirmCard(req)
            }
        }
    }

    // MARK: - Confirm cards

    func inlineShortcutConfirmCard(_ p: (name: String, runToken: String, input: String?)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm shortcut")
                .font(.caption.weight(.semibold))
            Text(
                ShortcutsService.isCLIInstalled
                    ? "ORBIT will run \u{201C}\(p.name)\u{201D} with the system shortcuts tool (exit code 0 means it finished). If that path is unavailable, the Shortcuts app opens instead \u{2014} then errors only show there."
                    : "The shortcuts command-line tool was not found. ORBIT can only hand off to the Shortcuts app, which cannot confirm success from here."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let input = p.input, !input.isEmpty {
                Text("Input: \(input)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { pendingShortcut = nil }
                }
                .keyboardShortcut(.cancelAction)
                Button("Run shortcut") {
                    Task {
                        let outcome = await ShortcutsService.runShortcut(
                            displayName: p.name,
                            runToken: p.runToken,
                            input: p.input
                        )
                        await MainActor.run {
                            switch outcome {
                            case .completed:
                                presentActionFeedback(
                                    "Finished \u{201C}\(p.name)\u{201D} successfully.",
                                    tone: .success,
                                    autoClearSuccessAfter: 6
                                )
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    pendingShortcut = nil
                                    actionsActiveTool = nil
                                }
                            case .handedOffToShortcutsApp:
                                presentActionFeedback(
                                    "Handed off to Shortcuts for \u{201C}\(p.name)\u{201D}. If it fails, that app will show it \u{2014} ORBIT only knows the handoff worked.",
                                    tone: .neutral,
                                    autoClearSuccessAfter: 10
                                )
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    pendingShortcut = nil
                                    actionsActiveTool = nil
                                }
                            case .failed(let message):
                                presentActionFeedback(message, tone: .issue)
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    func inlineCalendarConfirmCard(_ e: (title: String, start: Date, end: Date, notes: String?)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm calendar event")
                .font(.caption.weight(.semibold))
            Text(e.title)
                .font(.caption.weight(.medium))
            Text(formattedEventRange(start: e.start, end: e.end))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let n = e.notes, !n.isEmpty {
                Text(n)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { pendingCalendarEvent = nil }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSavingCalendarEvent)
                Button("Add to Calendar") {
                    Task {
                        isSavingCalendarEvent = true
                        let ok = await confirmAddCalendarEvent(
                            title: e.title,
                            start: e.start,
                            end: e.end,
                            notes: e.notes
                        )
                        await MainActor.run {
                            isSavingCalendarEvent = false
                            if ok {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    pendingCalendarEvent = nil
                                    newEventTitle = ""
                                    newEventNotes = ""
                                    actionsActiveTool = nil
                                }
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSavingCalendarEvent)
                if isSavingCalendarEvent {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    func inlineWebActionConfirmCard(_ action: PendingWebAction) -> some View {
        let detail: String
        switch action {
        case .openSite(let url):
            detail = "Open site in browser: \(url.absoluteString)"
        case .webSearch(let query, let url):
            detail = "Open web search for \u{201C}\(query)\u{201D} in browser.\n\(url.absoluteString)"
        case .summarize(let url):
            detail = "Fetch and summarize this page:\n\(url.absoluteString)"
        case .draftReply(let url, let request):
            detail = "Fetch this page and draft a response.\nPage: \(url.absoluteString)\nRequest: \(request ?? "Draft a useful response from page context.")"
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Confirm web action")
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { pendingWebAction = nil }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunningWebAction)

                Button("Run web action") {
                    Task { await runConfirmedWebAction(action) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRunningWebAction)

                if isRunningWebAction {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    func inlineCommunicationDraftConfirmCard(_ req: OrbitCommunicationDraftRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm communication draft")
                .font(.caption.weight(.semibold))
            Text("Channel: \(req.channel.rawValue)\nDraft-only; ORBIT will not send anything automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Request: \(req.userInstruction)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { pendingCommDraft = nil }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunningCommDraft)

                Button("Run draft") {
                    Task { await runConfirmedCommunicationDraft(req) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isRunningCommDraft)

                if isRunningCommDraft {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    // MARK: - Helper views

    func webAgentModeButton(_ mode: WebAgentMode) -> some View {
        Button {
            webAgentMode = mode
        } label: {
            Text(mode.rawValue)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(webAgentMode == mode ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(webAgentMode == mode ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.15), lineWidth: 1)
        }
    }

    func formattedEventRange(start: Date, end: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "\(df.string(from: start)) \u{2013} \(df.string(from: end))"
    }

    // MARK: - State helpers

    @MainActor
    func resetActionsSectionForClose() {
        actionsActiveTool = nil
        pendingShortcut = nil
        pendingCalendarEvent = nil
        pendingWebAction = nil
        pendingCommDraft = nil
        isRunningWebAction = false
        isRunningCommDraft = false
        clearShortcutPickerStateForSession()
        clearActionFeedback()
    }

    @MainActor
    func returnActionsToChooser() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            actionsActiveTool = nil
            pendingShortcut = nil
            pendingCalendarEvent = nil
            pendingWebAction = nil
            pendingCommDraft = nil
        }
        clearShortcutPickerStateForSession()
    }

    @MainActor
    func clearShortcutPickerStateForSession() {
        shortcutPick = nil
        shortcutManualName = ""
        shortcutListFilter = ""
        shortcutListError = nil
    }

    var filteredShortcutLibrary: [ShortcutLibraryEntry] {
        let q = shortcutListFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return shortcutLibrary }
        return shortcutLibrary.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var shortcutPrepareEnabled: Bool {
        let manual = shortcutManualName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return true }
        return shortcutPick != nil
    }

    @MainActor
    func loadShortcutList() async {
        isLoadingShortcutList = true
        shortcutListError = nil
        defer { isLoadingShortcutList = false }
        do {
            shortcutLibrary = try await ShortcutsService.listShortcuts()
        } catch {
            shortcutListError = error.localizedDescription
            shortcutLibrary = []
        }
    }

    @MainActor
    func syncPendingShortcutAfterPickChange(_ pick: ShortcutLibraryEntry?) {
        guard pendingShortcut != nil else { return }
        let manual = shortcutManualName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return }
        guard let pick else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                pendingShortcut = nil
            }
            return
        }
        guard let p = pendingShortcut else { return }
        if pick.name != p.name || pick.id != p.runToken {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                pendingShortcut = (pick.name, pick.id, p.input)
            }
        }
    }

    @MainActor
    func syncPendingShortcutInputFromDraft() {
        guard let p = pendingShortcut else { return }
        let input = shortcutInputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newInput = input.isEmpty ? nil : input
        guard newInput != p.input else { return }
        pendingShortcut = (p.name, p.runToken, newInput)
    }

    @MainActor
    func syncPendingCalendarFromForm() {
        guard pendingCalendarEvent != nil else { return }
        let title = newEventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                pendingCalendarEvent = nil
            }
            return
        }
        let end = Calendar.current.date(
            byAdding: .minute,
            value: newEventDurationMinutes,
            to: newEventStart
        ) ?? newEventStart
        let notes = newEventNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesOpt = notes.isEmpty ? nil : notes
        guard let p = pendingCalendarEvent else { return }
        if p.title != title || p.start != newEventStart || p.end != end || p.notes != notesOpt {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                pendingCalendarEvent = (title, newEventStart, end, notesOpt)
            }
        }
    }

    // MARK: - Action runners

    @MainActor
    func runConfirmedWebAction(_ action: PendingWebAction) async {
        isRunningWebAction = true
        defer { isRunningWebAction = false }
        do {
            let intent: OrbitWebActionIntent
            switch action {
            case .openSite(let url):
                intent = .openSite(url)
            case .webSearch(let query, let url):
                intent = .searchWeb(query: query, url: url)
            case .summarize(let url):
                intent = .summarizePage(url)
            case .draftReply(let url, let request):
                intent = .draftFromPage(url: url, request: request)
            }

            let run = try await OrbitWebActionRunner.run(intent, sessionID: sessionID, includeMemoryDebug: showMemoryDebug)
            responseText = sanitizeReply(run.reply)
            lastRoute = run.route
            lastModel = run.model
            lastTierSource = OrbitRouteClassifier.lastSource.rawValue
            presentActionFeedback("Web action completed.", tone: .success, autoClearSuccessAfter: 8)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                pendingWebAction = nil
                actionsActiveTool = nil
            }
        } catch {
            presentActionFeedback("Web action failed: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func runConfirmedCommunicationDraft(_ req: OrbitCommunicationDraftRequest) async {
        isRunningCommDraft = true
        defer { isRunningCommDraft = false }
        do {
            let run = try await OrbitCommunicationDraftRunner.run(req, sessionID: sessionID, includeMemoryDebug: showMemoryDebug)
            responseText = sanitizeReply(run.reply)
            lastRoute = run.route
            lastModel = run.model
            lastTierSource = OrbitRouteClassifier.lastSource.rawValue
            presentActionFeedback("Communication draft ready.", tone: .success, autoClearSuccessAfter: 8)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                pendingCommDraft = nil
                actionsActiveTool = nil
            }
        } catch {
            presentActionFeedback("Drafting failed: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func confirmAddCalendarEvent(
        title: String,
        start: Date,
        end: Date,
        notes: String?
    ) async -> Bool {
        do {
            try await calendarService.addTimedEvent(
                title: title,
                start: start,
                end: end,
                notes: notes
            )
            await refreshCalendarSnapshot(silent: true)
            presentActionFeedback(
                "Added \u{201C}\(title)\u{201D} to your calendar.",
                tone: .success,
                autoClearSuccessAfter: 8
            )
            return true
        } catch {
            presentActionFeedback(
                "Could not add event: \(error.localizedDescription)",
                tone: .issue
            )
            return false
        }
    }
}
