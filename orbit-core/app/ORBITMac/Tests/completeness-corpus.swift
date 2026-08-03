//
//  completeness-corpus.swift
//  Semantic endpointing regression test
//
//      orbit-core/app/ORBITMac/Tests/run-completeness-corpus.sh
//
//  Two properties, and the second matters as much as the first:
//
//    1. An unfinished sentence must WAIT. "remind me to…" is not a request, it is the first
//       half of one, and committing it is how ORBIT cuts him off mid-thought.
//    2. A finished sentence must NOT wait. A false "he's still talking" adds a second of dead
//       air to every single turn — that is worse than the bug being fixed, because it is felt
//       constantly rather than occasionally.
//
//  The commands are real ones from ORBIT's own phrase tables and from Ayush's transcripts.
//

import Foundation

@main
enum CompletenessCorpus {

    static let base: TimeInterval = 1.25

    static func main() {
        var fails = 0

        func pause(_ text: String) -> TimeInterval {
            OrbitUtteranceCompleteness.endpointPause(for: text, base: base)
        }

        /// Must wait noticeably longer than a plain, unremarkable utterance.
        func mustWait(_ text: String) {
            let got = pause(text)
            if got < base + 1.0 {
                print("❌ should WAIT: \"\(text)\" → \(String(format: "%.2f", got))s")
                fails += 1
            }
        }

        /// Must not be given extra thinking time.
        func mustNotWait(_ text: String) {
            let got = pause(text)
            if got > base + 0.8 {
                print("❌ should NOT wait: \"\(text)\" → \(String(format: "%.2f", got))s")
                fails += 1
            }
        }

        // ── Unfinished: dangling function words ────────────────────────────────────────
        let unfinished = [
            "remind me to",
            "remind me to call",                    // verb with no object yet
            "set a reminder for",
            "schedule a meeting with",
            "open",                                  // bare verb — nothing to open yet
            "I want to",
            "can you",
            "could you please",
            "I was thinking about going to the",
            "put it in the",
            "turn off the",
            "search for",
            "play something by",
            "message Kavan and",
            "I'll be back in",
            "the meeting is at",
            "add milk and eggs and",
            "it's either this or",
            "I need to finish it because",
            "let me know when",
            "I am going to be",
            "we should probably",
            "my shift ends at",
            "tell him that I",
            "I have a call with",
        ]
        for text in unfinished { mustWait(text) }

        // ── Unfinished times: a bare hour usually has "thirty" or "PM" coming ──────────
        for text in ["remind me at five", "meet me at seven", "the call is at 3", "wake me up at six"] {
            mustWait(text)
        }

        // ── Finished: real commands that must stay snappy ──────────────────────────────
        let finished = [
            "turn off the wifi",
            "turn on dark mode",
            "what's the battery",
            "open safari",
            "call mum",
            "remind me to call mum",
            "remind me to buy tickets for Spiderman at five PM",
            "play some music",
            "volume up",
            "set the volume to 50",
            "lower the brightness",
            "what's on my calendar today",
            "go to sleep",
            "thanks",
            "no thanks",
            "who are my friends",
            "schedule a call with Kavan on Thursday at 2 PM",
            "I am going for a bath now",
            "how are you",
            "good morning",
            "cancel that",
            "delete the reminder about the dentist",
            "search for hummus recipes in Chrome",
            "I finished my shift",
            "it's too loud in here",
        ]
        for text in finished { mustNotWait(text) }

        // ── Terminal punctuation is a completion signal, and must be quick ─────────────
        for text in ["That's done.", "I'm good, thanks!", "Are you there?"] {
            if pause(text) > base {
                print("❌ punctuation should be quick: \"\(text)\" → \(pause(text))s")
                fails += 1
            }
        }

        // ── Filler-only keeps the long thinking window (the 3 PM briefing bug) ─────────
        for text in ["Um", "uh, um", "hmm"] {
            if pause(text) < 5.0 {
                print("❌ filler should get the thinking window: \"\(text)\" → \(pause(text))s")
                fails += 1
            }
        }

        // ── Ordering guarantee: unfinished always waits longer than the same stem finished
        let pairs = [
            ("remind me to", "remind me to call mum"),
            ("turn off the", "turn off the wifi"),
            ("the meeting is at", "the meeting is at 3 PM"),
            ("I have a call with", "I have a call with Kavan"),
        ]
        for (open, closed) in pairs where pause(open) <= pause(closed) {
            print("❌ \"\(open)\" (\(pause(open))s) must wait longer than \"\(closed)\" (\(pause(closed))s)")
            fails += 1
        }

        // ── Long utterances get more room than short ones ──────────────────────────────
        let long = "so I was thinking that maybe after my shift I could go to the gym and then swimming with my friends"
        if pause(long) <= base {
            print("❌ a long utterance should get more room, got \(pause(long))s")
            fails += 1
        }

        let total = unfinished.count + finished.count + 4 + 3 + 3 + pairs.count + 1 + 4
        print("completeness: \(unfinished.count) unfinished · \(finished.count) finished · \(pairs.count) ordered pairs")
        print(fails == 0
              ? "✅ completeness corpus: all \(total) checks behave correctly"
              : "❌ \(fails) failure(s)")
        exit(fails == 0 ? 0 : 1)
    }
}
