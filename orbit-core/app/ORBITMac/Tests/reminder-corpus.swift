//
//  reminder-corpus.swift
//  ORBITMac reminder/calendar parsing regression test
//
//      orbit-core/app/ORBITMac/Tests/run-reminder-corpus.sh
//
//  Anchored on the real failure from 2026-08-02, where
//  "Um, would you please remind me to buy tickets for Spiderman, um, on for today"
//  became a reminder whose TITLE was that entire sentence, due at a 12:00 nobody said.
//
//  The three properties under test:
//    1. disfluencies are removed without damaging real words ("like", "may", names)
//    2. a "title" that still reads like a request is recognised as failed extraction
//    3. a day with no clock time is known to have no clock time, so ORBIT asks instead of guessing
//

import Foundation

@main
enum ReminderCorpus {
    static func main() {
        let real = "Um, would you please remind me to buy tickets for Spiderman, um, on for   today"
        print("RAW:      \"\(real)\"")
        let cleaned = OrbitUtteranceCleanup.stripDisfluencies(real)
        print("DEFILLED: \"\(cleaned)\"")
        print("still a request? \(OrbitUtteranceCleanup.looksLikeUnextractedRequest(cleaned))  (true = hand to brain)")
        print("explicit clock time? \(OrbitUtteranceCleanup.hasExplicitClockTime(real))  (false = must ask)")
        print("")

        var fails = 0
        func check(_ label: String, _ got: Bool, _ want: Bool) {
            if got != want { print("❌ \(label): got \(got), want \(want)"); fails += 1 }
        }

        // Disfluency removal must not damage real content.
        let disfluency: [(String, String)] = [
            ("Um, would you please remind me to buy tickets", "would you please remind me to buy tickets"),
            ("uh remind me to call mum", "remind me to call mum"),
            ("remind me to buy milk, um, tomorrow", "remind me to buy milk, tomorrow"),
            ("remind me to like the post", "remind me to like the post"),
            ("remind me to email Erin", "remind me to email Erin"),
            ("remind me to book a hummus tasting", "remind me to book a hummus tasting"),
        ]
        for (input, want) in disfluency where OrbitUtteranceCleanup.stripDisfluencies(input) != want {
            print("❌ disfluency: \"\(input)\" → \"\(OrbitUtteranceCleanup.stripDisfluencies(input))\", want \"\(want)\"")
            fails += 1
        }

        // Titles that still read like the request must be handed to the brain.
        for t in ["would you please remind me to buy tickets for spiderman",
                  "remind me to buy milk", "set a reminder for the dentist",
                  "can you remind me about the call", "i want you to set a reminder"] {
            check("unextracted \"\(t)\"", OrbitUtteranceCleanup.looksLikeUnextractedRequest(t), true)
        }
        // Real titles must NOT be flagged.
        for t in ["buy tickets for spiderman", "call mum", "dentist appointment",
                  "submit the tax return", "pick up parcel", "reminder app research"] {
            check("clean title \"\(t)\"", OrbitUtteranceCleanup.looksLikeUnextractedRequest(t), false)
        }

        // Times the user actually spoke.
        for t in ["at 3", "3pm", "at 3:30", "tomorrow morning", "tonight", "in 20 minutes",
                  "at noon", "9 o'clock", "half past four", "first thing", "end of day"] {
            check("has time \"\(t)\"", OrbitUtteranceCleanup.hasExplicitClockTime(t), true)
        }
        // Day only — ORBIT must ask, not invent noon.
        for t in ["tuesday", "on tuesday", "next friday", "tomorrow", "today",
                  "on the 14th", "buy tickets for spiderman for tuesday"] {
            check("no time \"\(t)\"", OrbitUtteranceCleanup.hasExplicitClockTime(t), false)
        }

        // Answers to "what time on Tuesday?"
        for t in ["3pm", "at 3", "half past four", "in the morning"] {
            check("answer keeps day \"\(t)\"", OrbitUtteranceCleanup.mentionsExplicitDay(t), false)
        }
        for t in ["wednesday at 3", "actually tomorrow", "next monday 9am", "on the 14th"] {
            check("answer moves day \"\(t)\"", OrbitUtteranceCleanup.mentionsExplicitDay(t), true)
        }


        // ── Spoken clock times. "at five PM" is a time; missing this escalated a complete
        //    request and let an hour be invented. (Real failure, 2026-08-02.)
        for t in ["would you please remind me to buy tickets for Spider Man for Tuesday today at five PM",
                  "remind me today at five PM", "at five pm", "five pm", "at five",
                  "at nine thirty", "nine o'clock", "at eleven", "tomorrow at six"] {
            check("spoken time \"\(t)\"", OrbitUtteranceCleanup.hasExplicitClockTime(t), true)
        }
        for t in ["remind me to call the five star hotel", "buy tickets for spiderman for tuesday"] {
            check("no time \"\(t)\"", OrbitUtteranceCleanup.hasExplicitClockTime(t), false)
        }

        // ── Titles ORBIT actually saved that were not tasks at all.
        for t in ["It", "8", "Today, August 2", "for eight", "at 5", "PM", "Tuesday", "that", ""] {
            check("junk title \"\(t)\"", OrbitUtteranceCleanup.isTooThinToBeATask(t), true)
        }
        for t in ["Buy tickets for Spiderman", "Call mum", "Dentist", "Pay the 8 dollar fee",
                  "Email Erin on Tuesday", "Book August holiday", "Gym"] {
            check("real task \"\(t)\"", OrbitUtteranceCleanup.isTooThinToBeATask(t), false)
        }


        // ── Calendar (Phase 3.14). Same treatment as reminders: extraction that failed goes to
        //    the brain, and an event is never booked at an hour the user did not say.
        for t in ["would you schedule a meeting with Priya", "could you book a call",
                  "i want you to set up a meeting", "add this to my calendar",
                  "create a calendar event for the demo", "block out some time"] {
            check("unextracted event \"\(t)\"", OrbitUtteranceCleanup.looksLikeUnextractedEventRequest(t), true)
        }
        for t in ["Meeting with Priya", "Standup", "Dentist appointment", "Call with the bank",
                  "Lunch with Sam", "Demo for the team", "Interview"] {
            check("real event \"\(t)\"", OrbitUtteranceCleanup.looksLikeUnextractedEventRequest(t), false)
        }
        for t in ["meeting from 2 to 4", "standup from ten to eleven", "block from 9 until noon",
                  "between 3 and 5", "call at 4pm", "demo tomorrow at nine thirty"] {
            check("event has time \"\(t)\"", OrbitUtteranceCleanup.hasExplicitClockTime(t), true)
        }
        for t in ["meeting with priya on thursday", "schedule a call for friday",
                  "standup tomorrow", "demo next tuesday", "lunch with sam today"] {
            check("event needs time \"\(t)\"", OrbitUtteranceCleanup.hasExplicitClockTime(t), false)
        }

        print(fails == 0 ? "✅ all reminder-parsing checks passed" : "❌ \(fails) failure(s)")
        exit(fails == 0 ? 0 : 1)

    }
}
