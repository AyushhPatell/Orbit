//
//  reminder-matching-corpus.swift
//  Reminder duplicate + completion matching
//
//      orbit-core/app/ORBITMac/Tests/run-reminder-matching-corpus.sh
//
//  Anchored on the exact sequence Ayush hit on 2026-08-03, screenshot and all:
//
//     14:42  "remind me to call Shreel, we have a get together and dinner"
//              → "Call Shreel about get together and dinner"
//     14:56  "yes I am ready"
//              → "Call Shreel about the get together and dinner"     ← a duplicate
//            "mark those reminders done"     → only ONE completed
//            "there is one more reminder left, mark it done"  → failed
//            "there is one more reminder left, mark it done"  → failed again
//            'mark "Call Shreel about get together and dinner" as done' → finally worked
//
//  Being made to recite an exact title back to an assistant is the opposite of the point.
//

import Foundation

@main
enum ReminderMatchingCorpus {

    // The two real titles, differing by one word.
    static let realA = "Call Shreel about get together and dinner"
    static let realB = "Call Shreel about the get together and dinner"

    static func main() {
        var fails = 0
        func check(_ label: String, _ got: Bool, _ want: Bool) {
            if got != want { print("❌ \(label): got \(got), want \(want)"); fails += 1 }
        }

        // ── The duplicate that should never have been created ─────────────────────────
        check("real duplicate pair", OrbitReminderMatching.isSameTask(realA, realB), true)
        check("identical", OrbitReminderMatching.isSameTask(realA, realA), true)
        check("case + punctuation", OrbitReminderMatching.isSameTask("call shreel about dinner!", "Call Shreel about dinner"), true)
        check("shorter phrasing of same task",
              OrbitReminderMatching.isSameTask("Call Shreel", "Call Shreel about get together and dinner"), true)

        // Genuinely different tasks must NEVER be merged — a false duplicate silently
        // swallows a reminder the user asked for.
        let distinct: [(String, String)] = [
            ("Call Shreel about dinner", "Call Kavan about dinner"),
            ("Buy tickets for Spiderman", "Buy milk"),
            ("Submit the assignment", "Submit the tax return"),
            ("Call mum", "Call the bank"),
            ("Gym at 6", "Dentist at 6"),
            ("Email Shreel", "Call Shreel"),
        ]
        for (a, b) in distinct {
            check("distinct \"\(a)\" vs \"\(b)\"", OrbitReminderMatching.isSameTask(a, b), false)
        }

        // ── Vague references: he should never have to recite a title ──────────────────
        let vague = [
            "there is one more reminder left",
            "there's one more reminder left please mark it done",
            "one more",
            "the other one",
            "the other reminder",
            "the last one",
            "the remaining one",
            "mark it done",
            "mark them all done",
            "complete both",
            "it", "that", "this one",
        ]
        for phrase in vague {
            check("vague \"\(phrase)\"", OrbitReminderMatching.isVagueReference(phrase), true)
        }
        // A real title must NOT be treated as vague, or it would never match anything.
        for phrase in [realA, "Call Shreel", "buy tickets for Spiderman", "dentist appointment"] {
            check("named \"\(phrase)\"", OrbitReminderMatching.isVagueReference(phrase), false)
        }

        // ── Plural: "mark THOSE reminders done" must not stop at the first ────────────
        for phrase in ["mark those reminders done", "complete both", "mark them all done",
                       "clear all of them", "mark these done", "finish both reminders"] {
            check("plural \"\(phrase)\"", OrbitReminderMatching.refersToMultiple(phrase), true)
        }
        for phrase in ["mark the dentist reminder done", "complete Call Shreel", "mark it done"] {
            check("singular \"\(phrase)\"", OrbitReminderMatching.refersToMultiple(phrase), false)
        }

        // ── Matching against a real pending list ─────────────────────────────────────
        let pending = [realA, realB, "Buy tickets for Spiderman", "Dentist appointment"]

        let shreelHits = OrbitReminderMatching.matches(query: "Call Shreel", titles: pending)
        if Set(shreelHits) != Set([0, 1]) {
            print("❌ \"Call Shreel\" should match BOTH duplicates, got \(shreelHits)")
            fails += 1
        }
        check("both matches are the same task",
              OrbitReminderMatching.allSameTask(shreelHits.map { pending[$0] }), true)

        let exact = OrbitReminderMatching.matches(query: realA, titles: pending)
        if exact.first != 0 {
            print("❌ the exact title should rank first, got \(exact)")
            fails += 1
        }

        let dentist = OrbitReminderMatching.matches(query: "dentist", titles: pending)
        if dentist != [3] {
            print("❌ \"dentist\" should match exactly one, got \(dentist)")
            fails += 1
        }

        if !OrbitReminderMatching.matches(query: "something nobody wrote down", titles: pending).isEmpty {
            print("❌ an unrelated query should match nothing")
            fails += 1
        }

        // Distinct matches must stay distinct so ORBIT asks instead of guessing.
        let twoDistinct = ["Call Shreel about dinner", "Call Kavan about dinner"]
        check("distinct matches are not one task", OrbitReminderMatching.allSameTask(twoDistinct), false)

        // ── STT robustness: the title comes back slightly misheard ───────────────────
        check("misheard title still matches",
              OrbitReminderMatching.matches(query: "call shreel about gettogether and dinner",
                                            titles: pending).contains(0), true)

        print(fails == 0
              ? "✅ reminder matching corpus: all checks behave correctly"
              : "❌ \(fails) failure(s)")
        exit(fails == 0 ? 0 : 1)
    }
}
