//
//  bargein-corpus.swift
//  Barge-in: telling Ayush's voice from ORBIT's own
//
//      orbit-core/app/ORBITMac/Tests/run-bargein-corpus.sh
//
//  Listening while speaking means the mic hears the speaker. macOS echo cancellation removes
//  most of that, but "most" is not a guarantee — leakage varies with volume, room, and
//  headphones vs speakers. If ORBIT interrupts ITSELF mid-sentence, the feature is worse than
//  not having it at all. So AEC is the first line and content matching is the second.
//
//  Two properties:
//    1. ORBIT's own words coming back must NEVER interrupt it.
//    2. "Stop" must ALWAYS interrupt — even when ORBIT happens to be saying that word.
//

import Foundation

@main
enum BargeInCorpus {
    static func main() {
        var fails = 0
        func check(_ label: String, _ got: Bool, _ want: Bool) {
            if got != want { print("❌ \(label): got \(got), want \(want)"); fails += 1 }
        }

        let spoken = "You have 3 reminders: buy tickets for Spiderman at five PM, call the bank tomorrow, and submit the form on Friday."

        // ── ORBIT hearing itself must never interrupt ─────────────────────────────────
        for echo in [
            "you have 3 reminders",
            "buy tickets for Spiderman at five PM",
            "call the bank tomorrow",
            "and submit the form on Friday",
            "reminders",
            spoken,
        ] {
            check("echo \"\(echo)\"", OrbitBargeIn.shouldInterrupt(transcript: echo, spokenText: spoken), false)
        }

        // ── Ayush actually talking must interrupt ────────────────────────────────────
        for real in [
            "okay that's enough",
            "actually never mind that",
            "turn off the wifi",
            "what about tomorrow",
            "no I meant the other one",
            "hold on a second",
        ] {
            check("real \"\(real)\"", OrbitBargeIn.shouldInterrupt(transcript: real, spokenText: spoken), true)
        }

        // ── "Stop" always wins, even mid-sentence and even if ORBIT said the word ────
        for stop in ["stop", "wait", "hold on", "shut up", "quiet", "okay stop", "no wait", "enough"] {
            check("stop \"\(stop)\"", OrbitBargeIn.isStopCommand(stop), true)
            check("stop interrupts \"\(stop)\"",
                  OrbitBargeIn.shouldInterrupt(transcript: stop, spokenText: "please wait a moment while I stop the timer"), true)
        }
        for notStop in ["stop the music and play something else", "I had to wait an hour at the dentist"] {
            check("not a bare stop \"\(notStop)\"", OrbitBargeIn.isStopCommand(notStop), false)
        }

        // ── Noise and thinking sounds must not chop ORBIT off ────────────────────────
        for noise in ["um", "uh", "hmm", "", "   "] {
            check("noise \"\(noise)\"", OrbitBargeIn.shouldInterrupt(transcript: noise, spokenText: spoken), false)
        }
        // A single vague word is not enough — a cough or a word from the room shouldn't cut in.
        check("single stray word", OrbitBargeIn.shouldInterrupt(transcript: "yeah", spokenText: spoken), false)

        // ── Echo detection itself ────────────────────────────────────────────────────
        check("exact echo", OrbitBargeIn.isEcho(transcript: "call the bank tomorrow", spokenText: spoken), true)
        check("unrelated speech", OrbitBargeIn.isEcho(transcript: "what's the weather", spokenText: spoken), false)
        check("empty is not echo", OrbitBargeIn.isEcho(transcript: "", spokenText: spoken), false)
        check("punctuation/case ignored",
              OrbitBargeIn.isEcho(transcript: "Call the bank, tomorrow!", spokenText: spoken), true)

        print(fails == 0 ? "✅ barge-in corpus: all checks behave correctly" : "❌ \(fails) failure(s)")
        exit(fails == 0 ? 0 : 1)
    }
}
