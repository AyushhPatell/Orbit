//
//  ContentView+Debug.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    var routingDebugPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routing (debug)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text("route \(lastRoute) \u{00B7} \(lastModel) \u{00B7} tier-1 \(lastTierSource)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .monospaced()
            if let userNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: noticeIconName)
                        .foregroundStyle(noticeAccentColor)
                    Text(userNotice)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.08))
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    /// Percentages are meaningless with no candidates — showing "0%" made "nothing was heard"
    /// look identical to "everything was rejected", which are opposite problems.
    private func wakeRate(_ count: Int, of total: Int) -> String {
        total == 0 ? "—" : String(format: "%.0f%%", (Double(count) / Double(total)) * 100)
    }

    var wakeDiagnosticsPanel: some View {
        let d = wakeWord.diagnostics
        let hitRate = wakeRate(d.acceptedCount, of: d.candidateCount)
        let lowConfRate = wakeRate(d.rejectedLowConfidenceCount, of: d.candidateCount)
        let cooldownRate = wakeRate(d.rejectedCooldownCount, of: d.candidateCount)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Wake Diagnostics")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Reset") {
                    wakeWord.resetDiagnostics()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Reset counters for a new tuning run")
            }

            // Which acoustic model is listening. en_CA on an Indian accent is the difference
            // between "orbit" and "are bit", so this is the first thing to check.
            Text("ears: \(d.engineDescription)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(d.engineDescription.hasPrefix("SpeechAnalyzer") ? Color.secondary : Color.orange)
                .monospaced()

            Text(
                "engine starts \(d.listeningStartCount) \u{00B7} wake observations \(d.observationCount) \u{00B7} wake attempts \(d.candidateCount)"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospaced()

            Text("hit \(hitRate) \u{00B7} low-conf \(lowConfRate) \u{00B7} cooldown \(cooldownRate) \u{00B7} restarts \(d.restartCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospaced()

            // The single most useful line when the wake word goes quiet: it separates
            // "the recogniser produced no text at all" from "it heard you but nothing matched".
            Text(wakeStateSummary(d))
                .font(.caption2.weight(.medium))
                .foregroundStyle(wakeWord.isListening && d.observationCount == 0 ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !d.recentCandidateConfidences.isEmpty {
                Text("confidence \(wakeConfidenceSparkline(d.recentCandidateConfidences))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            if let last = d.lastAcceptedAt {
                Text("last wake \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Always shown, even when empty — an absent row used to read as "fine".
            Text(d.lastTranscript.isEmpty ? "heard: (nothing yet)" : "heard: \(d.lastTranscript)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.07))
                .strokeBorder(Color.blue.opacity(0.24), lineWidth: 1)
        }
    }

    /// Every decision the reminder/calendar broker just made, newest last.
    ///
    /// A three-turn reminder conversation failed twice and could not be diagnosed by reading the
    /// code — more than one mechanism could produce the same symptom. This shows what actually
    /// happened, so a single reproduction is enough.
    var reminderTracePanel: some View {
        let trace = OrbitClarificationBroker.decisionTrace
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Reminder Trace")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear") { OrbitClarificationBroker.clearDecisionTrace() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            if trace.isEmpty {
                Text("no reminder or calendar turns yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(trace.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(line.contains("⚠︎") ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.purple.opacity(0.07))
                .strokeBorder(Color.purple.opacity(0.24), lineWidth: 1)
        }
    }

    /// Plain-language read of the counters, so the panel names the fault instead of only
    /// reporting numbers that have to be interpreted.
    func wakeStateSummary(_ d: OrbitWakeWordController.WakeDiagnosticsSnapshot) -> String {
        if !wakeWord.isEnabledInDefaults { return "off — enable \u{201C}Listen for Hey ORBIT\u{201D}" }
        if wakeWord.isSuspendedForUserSpeech { return "paused — mic handed to a voice turn" }
        if !wakeWord.isListening { return "not listening — \(wakeWord.lastError ?? "engine is not running")" }
        if d.observationCount == 0 {
            return "listening, but the recogniser has produced no text at all — audio isn\u{2019}t reaching it"
        }
        if d.candidateCount == 0 {
            return "hearing you fine, but nothing matched the wake phrase (see \u{201C}heard\u{201D} below)"
        }
        if d.acceptedCount == 0 {
            return "wake phrase recognised but rejected — confidence too low"
        }
        return "working \u{2014} \(d.acceptedCount) wake\(d.acceptedCount == 1 ? "" : "s") accepted"
    }

    func wakeConfidenceSparkline(_ values: [Double]) -> String {
        let blocks = Array("\u{2581}\u{2582}\u{2583}\u{2584}\u{2585}\u{2586}\u{2587}\u{2588}")
        let clipped = values.suffix(12)
        return clipped.map { value in
            let idx = max(0, min(blocks.count - 1, Int(round(value * Double(blocks.count - 1)))))
            return String(blocks[idx])
        }.joined()
    }
}
