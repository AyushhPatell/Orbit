//
//  ContentView+Memory.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    // MARK: - Memory disclosure

    var memoryDisclosure: some View {
        DisclosureGroup(isExpanded: $memoryExpanded) {
            VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
                TextField("Add a fact (preferences, people, goals\u{2026})", text: $rememberDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLoading)

                HStack(spacing: 10) {
                    Button("Save") {
                        Task { await saveFactFromDraft() }
                    }
                    .disabled(isLoading || rememberDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Save last reply") {
                        Task { await saveFactFromLastReply() }
                    }
                    .disabled(isLoading || responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Reload") {
                        Task { await refreshSavedFacts() }
                    }
                    .disabled(isLoading)
                }
                .font(.caption)

                if savedFacts.isEmpty {
                    Text("No saved facts yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(savedFacts) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.fact)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Remove") {
                                    Task { await removeFact(id: item.id) }
                                }
                                .font(.caption2)
                                .disabled(isLoading)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if showMemoryDebug {
                    Divider().padding(.vertical, 2)
                    memoryDebugPanel
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "note.text")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Memory")
                        .font(.subheadline.weight(.medium))
                    Text(memorySubtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    var memorySubtitle: String {
        let n = savedFacts.count
        if n == 0 { return "Curated facts \u{00B7} injected into context" }
        return "\(n) saved \u{00B7} up to 10 used in chat context"
    }

    // MARK: - Memory debug panel

    var memoryDebugPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory debug (hidden mode)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            if let md = lastMemoryDebug {
                Text("recent turns in prompt: \(md.recent_turn_count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if md.semantic_hits.isEmpty {
                    Text("semantic hits: none")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("semantic hits:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(md.semantic_hits, id: \.self) { hit in
                            Text("\u{2022} \(hit)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Text("No debug snapshot yet. Send a message with this toggle enabled.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            Text("Semantic memory store")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Add manual semantic memory\u{2026}", text: $semanticManualDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                Button("Add") {
                    Task { await addManualSemanticMemory() }
                }
                .font(.caption2)
                .disabled(
                    isLoadingSemanticMemory
                        || semanticManualDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            HStack(spacing: 8) {
                Button("Reload semantic memory") {
                    Task { await loadSemanticMemoryDebug() }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .disabled(isLoadingSemanticMemory)
                if isLoadingSemanticMemory {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            if semanticDebugItems.isEmpty {
                Text("No semantic memory rows.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(semanticDebugItems.prefix(12)) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\u{2022} [\(item.source) \u{00B7} \(item.importance, specifier: "%.2f")] \(item.text)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("-") {
                                Task { await adjustSemanticMemoryImportance(id: item.id, delta: -0.05) }
                            }
                            .font(.caption2)
                            .disabled(isLoadingSemanticMemory)
                            Button("+") {
                                Task { await adjustSemanticMemoryImportance(id: item.id, delta: 0.05) }
                            }
                            .font(.caption2)
                            .disabled(isLoadingSemanticMemory)
                            Button("Remove") {
                                Task { await deleteSemanticMemory(id: item.id) }
                            }
                            .font(.caption2)
                            .disabled(isLoadingSemanticMemory)
                        }
                    }
                }
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                if confirmClearSemanticMemory {
                    Text("Clear ALL semantic memory?")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Cancel") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            confirmClearSemanticMemory = false
                        }
                    }
                    .font(.caption2)
                    .disabled(isClearingSemanticMemory)
                    Button("Confirm erase") {
                        Task { await clearAllSemanticMemoryConfirmed() }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .disabled(isClearingSemanticMemory)
                } else {
                    Button("Clear semantic memory\u{2026}") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            confirmClearSemanticMemory = true
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .disabled(isClearingSemanticMemory)
                }

                if isClearingSemanticMemory {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    // MARK: - Semantic memory API

    @MainActor
    func clearAllSemanticMemoryConfirmed() async {
        guard confirmClearSemanticMemory else { return }
        isClearingSemanticMemory = true
        defer { isClearingSemanticMemory = false }
        do {
            let deleted = try await OrbitAPI().clearAllSemanticMemory()
            withAnimation(.easeOut(duration: 0.18)) {
                confirmClearSemanticMemory = false
            }
            lastMemoryDebug = nil
            semanticDebugItems = []
            presentNotice(
                "Cleared \(deleted) semantic memory item\(deleted == 1 ? "" : "s").",
                tone: .success,
                autoClearSuccessAfter: 6
            )
        } catch {
            presentNotice("Could not clear semantic memory: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func loadSemanticMemoryDebug() async {
        isLoadingSemanticMemory = true
        defer { isLoadingSemanticMemory = false }
        do {
            semanticDebugItems = try await OrbitAPI().listSemanticMemory()
        } catch {
            presentNotice("Could not load semantic memory: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func addManualSemanticMemory() async {
        let trimmed = semanticManualDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoadingSemanticMemory = true
        defer { isLoadingSemanticMemory = false }
        do {
            semanticDebugItems = try await OrbitAPI().addSemanticMemory(trimmed, source: "manual", importance: 0.92)
            semanticManualDraft = ""
            presentNotice("Added semantic memory.", tone: .success, autoClearSuccessAfter: 4)
        } catch {
            presentNotice("Could not add semantic memory: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func deleteSemanticMemory(id: Int) async {
        isLoadingSemanticMemory = true
        defer { isLoadingSemanticMemory = false }
        do {
            semanticDebugItems = try await OrbitAPI().deleteSemanticMemory(id: id)
            presentNotice("Removed semantic memory.", tone: .success, autoClearSuccessAfter: 4)
        } catch {
            presentNotice("Could not remove semantic memory: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func adjustSemanticMemoryImportance(id: Int, delta: Double) async {
        guard let current = semanticDebugItems.first(where: { $0.id == id }) else { return }
        let updated = max(0.0, min(1.0, current.importance + delta))
        isLoadingSemanticMemory = true
        defer { isLoadingSemanticMemory = false }
        do {
            semanticDebugItems = try await OrbitAPI().updateSemanticMemoryImportance(id: id, importance: updated)
            presentNotice("Updated memory importance.", tone: .success, autoClearSuccessAfter: 2.5)
        } catch {
            presentNotice("Could not update memory importance: \(error.localizedDescription)", tone: .issue)
        }
    }

    // MARK: - Curated facts API

    @MainActor
    func refreshSavedFacts() async {
        do {
            savedFacts = try await OrbitAPI().listFacts()
        } catch {
            presentNotice("Could not load facts: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func saveFactFromDraft() async {
        let trimmed = rememberDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let toSend = Self.clampedFact(trimmed)
        do {
            let items = try await OrbitAPI().addFact(toSend)
            rememberDraft = ""
            savedFacts = items
            if !showRoutingDebug {
                presentNotice("Saved to memory.", tone: .success, autoClearSuccessAfter: 5)
            }
        } catch {
            presentNotice("Could not save: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func saveFactFromLastReply() async {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let toSend = Self.clampedFact(trimmed)
        do {
            let items = try await OrbitAPI().addFact(toSend)
            savedFacts = items
            if !showRoutingDebug {
                presentNotice("Saved last reply to memory.", tone: .success, autoClearSuccessAfter: 5)
            }
        } catch {
            presentNotice("Could not save: \(error.localizedDescription)", tone: .issue)
        }
    }

    @MainActor
    func removeFact(id: Int) async {
        do {
            savedFacts = try await OrbitAPI().deleteFact(id: id)
            if !showRoutingDebug {
                presentNotice("Removed from memory.", tone: .success, autoClearSuccessAfter: 5)
            }
        } catch {
            presentNotice("Could not remove: \(error.localizedDescription)", tone: .issue)
        }
    }
}
