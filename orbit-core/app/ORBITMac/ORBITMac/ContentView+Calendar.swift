//
//  ContentView+Calendar.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    // MARK: - Calendar disclosure

    var calendarDisclosure: some View {
        DisclosureGroup(isExpanded: $calendarExpanded) {
            VStack(alignment: .leading, spacing: ORBITLayout.innerSpacing) {
                if calendarSummary.isEmpty && calendarPlaceholder {
                    Text("Loading\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(calendarSummary.isEmpty ? "\u{2014}" : calendarSummary)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await loadCalendarExplicit() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoadingCalendar)
                    .labelStyle(.titleAndIcon)

                    Button("Insert planning prompt") {
                        inputText = planPromptIncludingCalendar()
                    }
                    .disabled(!calendarReadyForTooling)

                    if isLoadingCalendar {
                        ProgressView()
                            .scaleEffect(0.85)
                    }
                }
                .font(.caption)
            }
            .padding(.top, 6)
        } label: {
            calendarDisclosureLabel
        }
    }

    var calendarDisclosureLabel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text("Calendar")
                    .font(.subheadline.weight(.medium))
                Text(calendarSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    var calendarSubtitle: String {
        if calendarSummary.hasPrefix("Calendar error") {
            return "EventKit unavailable \u{2014} check Privacy & Security \u{2192} Calendars"
        }
        if calendarPlaceholder && calendarSummary.isEmpty {
            return "Background sync for scheduling-aware replies"
        }
        if let n = eventCountFromSummary(calendarSummary) {
            if let d = calendarLastRefresh {
                let rel = RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
                return "\(n) event\(n == 1 ? "" : "s") in the next 14 days \u{00B7} updated \(rel)"
            }
            return "\(n) event\(n == 1 ? "" : "s") in the next 14 days"
        }
        if calendarSummary.hasPrefix("No calendar events") {
            return "No events in the next 14 days"
        }
        return "EventKit snapshot for tooling route"
    }

    var calendarReadyForTooling: Bool {
        !calendarSummary.isEmpty
            && !calendarSummary.hasPrefix("Calendar error")
            && !(calendarPlaceholder && calendarSummary.isEmpty)
    }

    func eventCountFromSummary(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.hasPrefix("Calendar error") { return nil }
        if t.contains("No calendar events") { return 0 }
        return t.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Mirrors tooling keywords in orbit-core/app/router.py so schedule questions always get a calendar snapshot.
    static func messageNeedsCalendarContext(_ message: String) -> Bool {
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

    @MainActor
    func loadCalendarExplicit() async {
        isLoadingCalendar = true
        defer { isLoadingCalendar = false }
        await refreshCalendarSnapshot(silent: false)
    }

    /// Loads 14 days for UI + tooling. Silent mode avoids user-facing notices on first launch.
    @MainActor
    func refreshCalendarSnapshot(silent: Bool) async {
        do {
            try await calendarService.ensureAccess()
            let text = try calendarService.upcomingEventsText(days: 14)
            calendarSummary = text
            calendarPlaceholder = false
            calendarLastRefresh = Date()
            if !silent { clearNotice() }
        } catch {
            calendarSummary = "Calendar error: \(error.localizedDescription)"
            calendarPlaceholder = false
            if !silent {
                presentNotice("Calendar: \(error.localizedDescription)", tone: .issue)
            }
        }
    }

    func planPromptIncludingCalendar() -> String {
        """
        Here is my upcoming calendar (local EventKit, next ~14 days):
        \(calendarSummary)

        Suggest how I should block the rest of my day for deep work and assignments. Be concise.
        """
    }
}
