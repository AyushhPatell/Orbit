//
//  ContentView+OrbitMind.swift
//  ORBITMac
//
//  Dashboard showing what ORBIT has learned: personal knowledge, life events, mood trend.
//

import SwiftUI

struct OrbitMindData {
    var personalKnowledge: [String: [String]] = [:]
    var knowledgeStats: [String: Int] = [:]
    var lifeEvents: [[String: Any]] = []
    var mood24h: (baseline: Double, trend: String, emotions: [(String, Int)]) = (0, "neutral", [])
    var dailySummaries: [[String: String]] = []
}

extension ContentView {

    var orbitMindDisclosure: some View {
        DisclosureGroup(isExpanded: $orbitMindExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Button("Refresh") {
                    Task { await loadOrbitMindData() }
                }
                .font(.caption)

                if let data = orbitMindData {
                    // Personal Knowledge Profile
                    mindSubsection(title: "What ORBIT knows about you") {
                        if data.personalKnowledge.isEmpty {
                            Text("Nothing yet. Tell ORBIT about yourself \u{2014} your work, interests, people in your life, or goals \u{2014} and it will start building your profile.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            let categoryLabels: [String: String] = [
                                "identity": "Identity", "work": "Work", "relationships": "People",
                                "routines": "Routines", "preferences": "Preferences",
                                "interests": "Interests", "goals": "Goals", "location": "Location",
                            ]
                            ForEach(Array(data.personalKnowledge.keys.sorted()), id: \.self) { key in
                                if let facts = data.personalKnowledge[key], !facts.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(categoryLabels[key] ?? key.capitalized)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        ForEach(facts, id: \.self) { fact in
                                            Text("\u{2022} \(fact)")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.primary.opacity(0.85))
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Recent Life Events
                    mindSubsection(title: "Recent life events") {
                        if data.lifeEvents.isEmpty {
                            Text("No events recorded yet. Share updates with ORBIT \u{2014} plans you\u{2019}re excited about, things you\u{2019}re going through, or moments worth remembering.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(0..<min(data.lifeEvents.count, 8), id: \.self) { i in
                                let ev = data.lifeEvents[i]
                                let summary = ev["summary"] as? String ?? ""
                                let category = ev["category"] as? String ?? ""
                                let emotion = ev["emotion"] as? String
                                HStack(alignment: .top, spacing: 4) {
                                    Text(categoryEmoji(category))
                                        .font(.system(size: 10))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(summary)
                                            .font(.system(size: 11))
                                            .lineLimit(2)
                                        if let em = emotion {
                                            Text("mood: \(em)")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Mood Trend
                    mindSubsection(title: "Mood trend (24h)") {
                        HStack(spacing: 8) {
                            Text(moodEmoji(data.mood24h.trend))
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(data.mood24h.trend.capitalized)
                                    .font(.system(size: 12, weight: .medium))
                                if !data.mood24h.emotions.isEmpty {
                                    Text(data.mood24h.emotions.map { "\($0.0) (\($0.1)x)" }.joined(separator: ", "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Daily Summaries
                    mindSubsection(title: "Recent days") {
                        if data.dailySummaries.isEmpty {
                            Text("Daily summaries appear after a full day of conversations with ORBIT.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(0..<min(data.dailySummaries.count, 5), id: \.self) { i in
                                let ds = data.dailySummaries[i]
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ds["date"] ?? "")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(ds["summary"] ?? "")
                                        .font(.system(size: 11))
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                } else {
                    Text("Tap Refresh to load ORBIT\u{2019}s mind.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("ORBIT\u{2019}s Mind")
                        .font(.system(size: 13, weight: .medium))
                    Text("Personal knowledge, life events, mood")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "brain")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
        }
        .onChange(of: orbitMindExpanded) { _, expanded in
            if expanded { Task { await loadOrbitMindData() } }
        }
    }

    private func mindSubsection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
        .padding(.vertical, 4)
    }

    private func categoryEmoji(_ category: String) -> String {
        switch category {
        case "plan": return "\u{1F4C5}"
        case "feeling": return "\u{1F49C}"
        case "life-update": return "\u{2728}"
        default: return "\u{1F4AC}"
        }
    }

    private func moodEmoji(_ trend: String) -> String {
        switch trend {
        case "positive": return "\u{1F60A}"
        case "low": return "\u{1F614}"
        case "slightly-low": return "\u{1F615}"
        default: return "\u{1F610}"
        }
    }

    func loadOrbitMindData() async {
        let sessionID = "orbit-mac"
        do {
            var data = OrbitMindData()

            // Personal knowledge
            if let url = URL(string: "http://127.0.0.1:8787/memory/personal-knowledge"),
               let (d, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let profile = json["profile"] as? [String: [String]] {
                data.personalKnowledge = profile
                data.knowledgeStats = (json["stats"] as? [String: Int]) ?? [:]
            }

            // Life events
            if let url = URL(string: "http://127.0.0.1:8787/memory/life-events"),
               let (d, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let events = json["events"] as? [[String: Any]] {
                data.lifeEvents = events
            }

            // Mood
            if let url = URL(string: "http://127.0.0.1:8787/memory/mood"),
               let (d, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let trend24h = json["trend_24h"] as? [String: Any] {
                let baseline = trend24h["baseline"] as? Double ?? 0
                let trend = trend24h["trend"] as? String ?? "neutral"
                let emotions = (trend24h["recent_emotions"] as? [[Any]])?.compactMap { arr -> (String, Int)? in
                    guard arr.count >= 2, let e = arr[0] as? String, let c = arr[1] as? Int else { return nil }
                    return (e, c)
                } ?? []
                data.mood24h = (baseline, trend, emotions)
            }

            // Daily summaries
            if let url = URL(string: "http://127.0.0.1:8787/memory/daily-summaries"),
               let (d, _) = try? await URLSession.shared.data(from: url),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let summaries = json["summaries"] as? [[String: Any]] {
                data.dailySummaries = summaries.map { s in
                    var entry: [String: String] = [:]
                    entry["date"] = s["date"] as? String ?? ""
                    entry["summary"] = s["summary"] as? String ?? ""
                    entry["mood"] = s["mood"] as? String ?? ""
                    return entry
                }
            }

            await MainActor.run { orbitMindData = data }
        }
    }
}
