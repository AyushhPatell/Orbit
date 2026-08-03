//
//  card-corpus.swift
//  When the floating card should and should not appear
//
//      orbit-core/app/ORBITMac/Tests/run-card-corpus.sh
//
//  Anchored on Ayush's report (2026-08-03): after Phase 3.15 the card appeared for EVERY
//  question ORBIT asked. Most of ORBIT's questions are ordinary conversation, so the card
//  became noise — *"it feels weird and there is no need."*
//
//  The two properties, and the second is the one that regressed:
//    1. Show the card when getting it wrong has a cost, or the content can't be held from
//       hearing it once — choices, confirmations, misheard names, missing details, real data.
//    2. Stay away from ordinary conversation. A question is not, by itself, a reason.
//
//  Replies below are ORBIT's real phrasing, taken from this project's transcripts and docs.
//

import Foundation

@main
enum CardCorpus {
    static func main() {
        var fails = 0

        func shouldShow(_ reply: String, _ why: String, pending: Bool = false) {
            guard let reason = OrbitCardPolicy.reason(for: reply, pendingChoice: pending) else {
                print("❌ expected a card (\(why)): \"\(reply)\"")
                fails += 1
                return
            }
            _ = reason
        }

        func shouldNotShow(_ reply: String, pending: Bool = false) {
            if let reason = OrbitCardPolicy.reason(for: reply, pendingChoice: pending) {
                print("❌ unwanted card [\(reason.rawValue)]: \"\(reply)\"")
                fails += 1
            }
        }

        func expect(_ reply: String, _ want: OrbitCardPolicy.Reason, pending: Bool = false) {
            let got = OrbitCardPolicy.reason(for: reply, pendingChoice: pending)
            if got != want {
                print("❌ \"\(reply)\" → \(got?.rawValue ?? "none"), want \(want.rawValue)")
                fails += 1
            }
        }

        // ── THE REGRESSION: ordinary conversation must be silent ──────────────────────
        let conversational = [
            "Anything else I can do for you?",
            "How's that?",
            "Is that better now?",
            "Bumped the volume up to 85%. How's that?",
            "Turned the volume down to 78%. Let me know if it's better now.",
            "Sounds good — enjoy your bath! I'll be here when you get back.",
            "Want me to help with anything related to work?",
            "Would you like me to look into that?",
            "How are you doing today?",
            "How was your shift?",
            "Good morning! Hope you're feeling ready for the day. Anything on your mind?",
            "Sometimes lazy mornings are the best kind. Chill for a bit — you've earned it.",
            "Welcome back! Ready to jump into something or just chilling for now?",
            "Yep? Take your time — no rush. What's up?",
            "Wi-Fi is off now.",
            "All set.",
            "Sleep mode is on now.",
            "Brightness set to 30%.",
            "Nothing new since earlier.",
            "Okay, I'm putting this here for now.",
            "Does that make sense?",
            "Sound good?",
            "Is there anything else on your mind?",
        ]
        for reply in conversational { shouldNotShow(reply) }

        // ── Pending choice: he must SEE the options to answer ─────────────────────────
        expect("Found 5 — top 8 · say 'open 1' … 'cancel'", .pendingChoice, pending: true)
        expect("Which one did you want?", .pendingChoice, pending: true)
        shouldShow("Anything else?", "a pick list is still pending", pending: true)

        // ── Consequential confirmations: the thing being approved must be visible ─────
        for reply in [
            "Should I delete the reminder about the dentist?",
            "Do you want me to send this message to Kavan?",
            "Shall I empty the trash?",
            "Should I run this command in Terminal?",
            "Are you sure? This cannot be undone.",
            "Shall I remove the calendar event on Thursday?",
            "This will permanently delete the folder. Confirm?",
        ] { shouldShow(reply, "consequential confirmation") }

        // ── Verifying what was heard: names and spellings are exactly what voice breaks
        for reply in [
            "Did you say Kavan or Krish?",
            "Did you mean Nishika?",
            "How do you spell that?",
            "Is that spelled S-H-R-E-E-L?",
            "I heard \"geetha\" — did you mean github.com?",
            "Kavan or Kawan?",
        ] { shouldShow(reply, "verifying what was heard") }

        // ── Missing detail for something being recorded ───────────────────────────────
        for reply in [
            "Sure — what time on Tuesday should I remind you?",
            "What time would you like the meeting?",
            "What should I call this reminder?",
            "What's the title for the event?",
            "Which day works for you?",
            "How long should I block off?",
            "What should the note say?",
        ] { shouldShow(reply, "missing detail for a record") }

        // ── Data worth reading ────────────────────────────────────────────────────────
        for reply in [
            "You have 3 reminders: buy tickets at 5 PM, call the bank tomorrow, and submit the form Friday.",
            "It's 18 degrees and cloudy in Halifax, with a high of 22 and a 40% chance of rain.",
            "1. Buy tickets\n2. Call the bank\n3. Submit the form",
            "Today you have:\n- Standup at 9:30\n- Call with Kavan at 2 PM\n- Gym after your shift",
        ] { shouldShow(reply, "multi-fact data") }

        expect("Your battery is at 47%, not charging, about 3 hours 20 minutes remaining.", .dataToRead)

        // ── Display-only ──────────────────────────────────────────────────────────────
        if OrbitCardPolicy.reason(for: "नमस्ते, आप कैसे हैं?", isDisplayOnly: true) != .displayOnly {
            print("❌ display-only text should always card")
            fails += 1
        }

        // ── Precedence: a confirmation that also reads like an offer ──────────────────
        expect("Should I delete it?", .confirmAction)
        shouldNotShow("Should I put on some music?")          // no consequence — just an offer

        // ── TTLs: things he must act on outlive things he only reads ─────────────────
        let actTTL  = OrbitCardPolicy.ttlSeconds(for: .confirmAction)
        let readTTL = OrbitCardPolicy.ttlSeconds(for: .dataToRead)
        if actTTL <= readTTL {
            print("❌ a confirmation (\(actTTL)s) should outlive a readout (\(readTTL)s)")
            fails += 1
        }

        let total = conversational.count + 3 + 7 + 6 + 7 + 4 + 1 + 1 + 2 + 1
        print("card policy: \(conversational.count) conversational · confirmations · hearing checks · missing details · data")
        print(fails == 0
              ? "✅ card corpus: all \(total) checks behave correctly"
              : "❌ \(fails) failure(s)")
        exit(fails == 0 ? 0 : 1)
    }
}
