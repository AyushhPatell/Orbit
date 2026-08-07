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

        // ── THE SELF-INTERRUPT LOOP (field trace, 2026-08-04) ────────────────────────
        //
        // Verbatim from Ayush's device. Each was ORBIT's OWN next sentence, heard by the mic
        // before `lastSpokenText` caught up — so it interrupted ORBIT mid-reply, which opened
        // the mic, captured more of ORBIT's speech as a message, and looped. None is a stop
        // word, which is exactly why only stop words may interrupt now.
        let selfInterrupts = [
            ("Sometimes the quiet", "Just thinking this is a good time to unwind and let your thoughts wander a bit."),
            ("The nud", "Yeah, those moments are quiet, but never empty."),
            ("The quiet", "Exactly."),
        ]
        for (heard, saying) in selfInterrupts {
            check("self-interrupt \"\(heard)\"",
                  OrbitBargeIn.shouldInterrupt(transcript: heard, spokenText: saying), false)
        }

        // ── An ordinary sentence must NOT interrupt any more ─────────────────────────
        //
        // This is a deliberate loss, recorded honestly: without a reference signal there is
        // no way to tell his sentence from ORBIT's, so talking over ORBIT with arbitrary
        // words is not supported. Stopping it is.
        for ordinary in [
            "okay that's enough",
            "actually never mind that",
            "turn off the wifi",
            "what about tomorrow",
            "no I meant the other one",
        ] {
            check("ordinary speech \"\(ordinary)\"",
                  OrbitBargeIn.shouldInterrupt(transcript: ordinary, spokenText: spoken), false)
        }

        // ── Stop words are the whole interruption surface ────────────────────────────
        for stop in ["stop", "Stop.", "wait", "hold on", "shut up", "shush", "okay stop", "no wait", "be quiet"] {
            check("stop \"\(stop)\"", OrbitBargeIn.isStopCommand(stop), true)
            check("stop interrupts \"\(stop)\"",
                  OrbitBargeIn.shouldInterrupt(transcript: stop, spokenText: spoken), true)
        }
        // Conversational words ORBIT genuinely uses must never be stop words. "quiet" and
        // "enough" were in the list and caused the self-interrupt loop.
        for notStop in ["stop the music and play something else", "I had to wait an hour at the dentist",
                        "the quiet", "sometimes the quiet", "quiet", "enough", "that's enough",
                        "pause", "cancel"] {
            check("not a stop command \"\(notStop)\"", OrbitBargeIn.isStopCommand(notStop), false)
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

        // ── The loop breaker ────────────────────────────────────────────────────────
        //
        // Narrowing the trigger makes a cascade unlikely; the cooldown makes it impossible.
        // In the field trace ORBIT interrupted itself three times in seventeen seconds.
        OrbitBargeIn.resetCooldown()
        check("no cooldown at rest", OrbitBargeIn.isInCooldown, false)
        OrbitBargeIn.noteInterrupt()
        check("cooldown after an interrupt", OrbitBargeIn.isInCooldown, true)
        OrbitBargeIn.resetCooldown()
        check("cooldown clears", OrbitBargeIn.isInCooldown, false)

        print(fails == 0 ? "✅ barge-in corpus: all checks behave correctly" : "❌ \(fails) failure(s)")
        exit(fails == 0 ? 0 : 1)
    }
}
