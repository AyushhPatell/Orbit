//
//  OrbitReminderMatching.swift
//  ORBITMac
//
//  Matching and duplicate rules for reminders, as pure functions.
//
//  Written from a real sequence Ayush hit on 2026-08-03:
//
//    1. "I'm going for a bath — when I return remind me to call Shreel, we have a get
//       together and dinner"        → reminder created (14:42)
//    2. he came back; ORBIT asked "are you ready about the reminder to call Shreel…"
//    3. "yes I am ready"            → a SECOND reminder created (14:56)
//    4. "mark those reminders done" → only ONE was completed
//    5. "there is one more reminder left, mark it done" → failed, twice
//    6. only the exact title worked on the third try
//
//  Three separate defects, all visible in the screenshot he sent:
//
//    - `createReminder` had no duplicate check at all, so confirming an existing reminder
//      made another one. The two titles differed by a single word ("about **the** get
//      together" vs "about get together"), which is why nothing downstream linked them.
//    - `completeReminder` used `incomplete.first { … }` — it can only ever complete ONE,
//      so "mark **those** reminders done" was always going to leave one behind.
//    - vague references ("one more", "the other one", "the rest") matched no title, so the
//      request failed until he read the full title aloud. Being made to recite an exact
//      string back to an assistant is the opposite of the point.
//

import Foundation

enum OrbitReminderMatching {

    /// Titles compared the way a person would: case, punctuation, and the small words that
    /// carry no meaning are all ignored. "Call Shreel about **the** get together and dinner"
    /// and "Call Shreel about get together and dinner" are the same task.
    static func normalizedTitle(_ title: String) -> String {
        let lowered = title.lowercased()
        let stripped = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let noise: Set<String> = ["the", "a", "an", "about", "to", "for", "my", "our", "please", "and"]
        let kept = stripped.filter { !noise.contains($0) }
        return (kept.isEmpty ? stripped : kept).joined(separator: " ")
    }

    /// True when two reminders are the same task written twice.
    static func isSameTask(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedTitle(lhs)
        let b = normalizedTitle(rhs)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        // One phrasing contained in the other ("call shreel" vs "call shreel get together").
        if a.contains(b) || b.contains(a) { return true }
        return levenshtein(a, b) <= max(2, min(a.count, b.count) / 6)
    }

    /// Phrases that point at a reminder without naming it. The user should never have to
    /// recite a title back — that is what made step 5 above fail three times.
    private static let vagueReferences: Set<String> = [
        "it", "that", "this", "one", "the one", "that one", "this one",
        "the reminder", "that reminder", "this reminder", "the other",
        "the other one", "the other reminder", "one more", "one more reminder",
        "the last one", "the last reminder", "the remaining one", "the rest",
        "the second one", "the other task", "another one", "the leftover",
    ]

    static func isVagueReference(_ query: String) -> Bool {
        var q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\"“”"))
        if vagueReferences.contains(q) { return true }
        // Sentences that describe a leftover rather than name it.
        let patterns = [
            #"^(there'?s |there is |you have )?(still )?(one|1) more\b"#,
            #"\bthe (other|remaining|last|second) (one|reminder|task)\b"#,
            #"\bone more (reminder|task|one)\b"#,
            #"\b(remaining|leftover) (reminder|task|one)\b"#,
            #"^(mark|complete|finish) (it|that|this|the rest|them|both|all)\b"#,
        ]
        return patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }

    /// True when the user is talking about more than one reminder at once —
    /// "mark **those** reminders done", "complete **both**", "clear them **all**".
    static func refersToMultiple(_ query: String) -> Bool {
        let q = query.lowercased()
        let patterns = [
            #"\b(those|these|both|all|them|every)\b"#,
            #"\breminders\b"#,          // plural noun
        ]
        return patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }

    /// Every reminder whose title plausibly answers the query, best first.
    static func matches(query: String, titles: [String]) -> [Int] {
        let q = normalizedTitle(query)
        guard !q.isEmpty else { return [] }
        var scored: [(index: Int, score: Int)] = []
        for (index, title) in titles.enumerated() {
            let t = normalizedTitle(title)
            if t.isEmpty { continue }
            if t == q { scored.append((index, 0)) }
            else if t.contains(q) || q.contains(t) { scored.append((index, 1)) }
            else {
                let distance = levenshtein(t, q)
                if distance <= max(3, min(t.count, q.count) / 5) { scored.append((index, 2 + distance)) }
            }
        }
        return scored.sorted { $0.score < $1.score }.map(\.index)
    }

    /// True when everything matched is really one task duplicated — then completing all of
    /// them is what the user meant, not an ambiguity to ask about.
    static func allSameTask(_ titles: [String]) -> Bool {
        guard let first = titles.first else { return false }
        return titles.dropFirst().allSatisfy { isSameTask(first, $0) }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1]
                    ? prev[j - 1]
                    : Swift.min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            prev = cur
        }
        return prev[y.count]
    }
}
