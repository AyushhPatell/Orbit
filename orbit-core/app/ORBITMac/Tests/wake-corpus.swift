//
//  wake-corpus.swift
//  ORBITMac wake-word regression test
//
//  The wake matcher is the most heavily tuned code in ORBIT and the app has no unit-test target,
//  so it is checked by compiling the real matcher against this corpus:
//
//      orbit-core/app/ORBITMac/Tests/run-wake-corpus.sh
//
//  Every phrase in `legacyPositives` worked before the en_IN migration on 2026-08-02 and must
//  keep working — that list is the month of tuning, written down. Every phrase in `negatives` is
//  ordinary speech near the Mac and must never wake ORBIT; several are deliberate traps
//  ("the orbit of mars", "wait a bit", "listen now a bit later").
//
//  Add the phrase here first, then change the matcher.
//

import Foundation

@main
enum WakeCorpus {

    static func wakes(_ text: String) -> Bool {
        OrbitWakePhraseMatcher
            .evaluate(OrbitWakeSample(text: text, isFinal: true, tokens: []))
            .acceptedByPattern
    }

    /// Accepted by the tuned matcher before the en_IN migration. These MUST still wake.
    static let legacyPositives = [
        "hey orbit", "hi orbit", "hello orbit", "yo orbit", "hay orbit", "helo orbit",
        "hey orbit please", "hey there orbit", "hey okay orbit", "hey uh um orbit",
        "wake up orbit", "wakeup orbit", "wake orbit", "wake up or bit", "wake or bit",
        "wake up are bit", "wake are bit", "hey are bit", "wake a orbit",
        "time to wake up orbit", "get up orbit", "orbit wake up", "orbit are you awake",
        "hey wake up", "orbit", "orbit please", "orbit now", "hey orbit hello",
        "orbit can you open safari", "orbit what is the time", "orbit i need help",
        "orbit please turn the volume down", "orbit tell me a joke", "orbit lets go",
        "hey orvit", "hey orbet", "hi orbid", "orbitt", "hey our bit", "hey oar bit",
        "hello or beet", "wake up orbitt", "hey arbit",
    ]

    /// Added 2026-08-02 — natural phrasings Ayush asked for, plus mishearings measured by
    /// replaying synthesized Indian-English speech through the real en_IN engine.
    static let newPositives = [
        "are you there orbit", "are you awake orbit", "are you up orbit",
        "are you around orbit", "are you listening orbit", "are you there or bit",
        "are you awake are bit", "you there orbit", "you awake orbit",
        "orbit are you there", "orbit are you up", "orbit you there",
        "orbit are you", "listen orbit", "listen up orbit", "wake orbit up",
        "orbit listen", "orbit listen up", "good morning orbit", "good night orbit",
        "good evening orbit", "orbit good morning", "orbit hello", "orbit hey",
        "come on orbit", "are you sleeping orbit", "orbit are you sleeping",
        "excuse me orbit", "r u there orbit", "are you there orbitt",
        // Measured engine output for "hey orbit" / "orbit are you there" / "listen orbit".
        "here or bit", "what bit are you there", "listen now a bit",
    ]

    /// Ordinary speech near the Mac. These MUST NOT wake ORBIT.
    static let negatives = [
        "", "the", "what time is it", "i need to buy milk",
        "let me check the orbit of mars", "the satellite entered orbit yesterday",
        "that is a bit much", "wait a bit", "hold on a bit longer",
        "can you give me a bit of space", "i will be there in a bit",
        "are you there", "are you awake", "are you up", "hello there",
        "hey how are you", "hi how is it going", "good morning everyone",
        "listen to this song", "wake up its late", "i need to wake up early",
        "the orbit is elliptical and takes a year",
        "she said it was a bit orbit like", "or bit by bit we got there",
        "call me back in a bit ok", "yeah a little bit",
        "we should orbit around the problem",
        "turn the volume down", "open safari", "what is the weather",
        "i am going to bed now", "please close the window",
        "what bit are you talking about", "put it over here or before that",
        "listen now a bit later", "i can hear a bit of noise", "what bit of it",
        "come here for a bit", "are you there yet", "hey are you listening to me",
        "orbit and the moon", "orbit or the sun", "orbit but not today",
        "orbit the earth", "orbit a star", "orbit an asteroid",
    ]

    /// Wake phrases that are also questions — these must get a spoken answer, not a silent orb.
    static let presenceQuestions = [
        "are you there orbit", "are you awake orbit", "are you up orbit",
        "are you around orbit", "are you listening orbit", "orbit are you there",
        "orbit are you awake", "orbit are you", "you there orbit",
        "are you sleeping orbit", "r u there orbit", "what bit are you there",
    ]

    /// Wake phrases that are plain summons — answering these out loud would be chatter.
    static let notQuestions = [
        "hey orbit", "wake up orbit", "orbit", "good morning orbit",
        "listen orbit", "orbit wake up", "hi orbit", "excuse me orbit",
    ]

    /// "Go and rest, ORBIT." Must reach the stop path, not the command matcher.
    static let restIntents = [
        "sleep", "sleep now", "sleep please", "orbit sleep", "sleep orbit",
        "go to sleep", "go to sleep now", "orbit go to sleep", "go to sleep orbit",
        "go back to sleep", "rest", "rest now", "take a rest", "go rest",
        "you can sleep", "you can rest", "time to sleep", "back to sleep",
        "sleep tight",
    ]

    /// Commands that merely *mention* sleep. These must still reach the command matcher.
    static let notRestIntents = [
        "sleep my screen", "sleep the screen", "put my screen to sleep",
        "sleep the display", "turn on sleep focus", "turn off sleep mode",
        "set a sleep timer", "remind me to sleep at eleven",
        "what time did i sleep", "how much did i sleep", "i couldnt sleep last night",
        "dont go to sleep", "play sleep music", "set an alarm before i sleep",
        "schedule sleep mode tonight",
    ]

    static func main() {
        var failures: [String] = []

        for phrase in presenceQuestions where !OrbitWakePhraseMatcher.isPresenceQuestion(phrase) {
            failures.append("question not recognised as one → \"\(phrase)\"")
        }
        for phrase in notQuestions where OrbitWakePhraseMatcher.isPresenceQuestion(phrase) {
            failures.append("plain summons treated as a question → \"\(phrase)\"")
        }
        for phrase in restIntents where !OrbitVoiceIntentHelpers.isRestIntent(phrase) {
            failures.append("rest intent missed → \"\(phrase)\"")
        }
        for phrase in restIntents where !OrbitVoiceIntentHelpers.isSessionStopCommand(phrase) {
            failures.append("rest intent does not reach the stop path → \"\(phrase)\"")
        }
        for phrase in notRestIntents where OrbitVoiceIntentHelpers.isRestIntent(phrase) {
            failures.append("sleep COMMAND hijacked as rest intent → \"\(phrase)\"")
        }

        for phrase in legacyPositives where !wakes(phrase) {
            failures.append("legacy positive no longer wakes → \"\(phrase)\"")
        }
        for phrase in newPositives where !wakes(phrase) {
            failures.append("new positive does not wake → \"\(phrase)\"")
        }
        for phrase in negatives where wakes(phrase) {
            failures.append("FALSE WAKE → \"\(phrase)\"")
        }


        // ── ORBIT's own goodbyes. The mic must NOT reopen after these, even in continuous
        //    voice mode — saying "talk soon" and then listening on reads as not understanding.
        for r in ["Okay — I\u{2019}m putting this here for now.", "Sure — talk to you later, Ayush.",
                  "See you later then.", "I\u{2019}m here whenever you need me, Ayush.",
                  "Okay. Let me know if something comes up.", "Good night, Ayush. Rest well.",
                  "Okay — talk soon. Take care.", "Alright, I\u{2019}ll leave you to it.",
                  "Going quiet now."] {
            if !OrbitVoiceIntentHelpers.isFarewellReply(r) {
                failures.append("farewell not recognised → \"\(r)\"")
            }
        }
        // Normal replies must keep the conversation open.
        for r in ["Done — reminder set for Tuesday at 5 PM.", "Is there anything else?",
                  "Brightness is at 40% now.", "What time on Tuesday should I remind you?",
                  "I\u{2019}ve turned the volume down. Let me know if you need anything else.",
                  "I couldn\u{2019}t reach the calendar — want me to try again?"] {
            if OrbitVoiceIntentHelpers.isFarewellReply(r) {
                failures.append("normal reply treated as farewell → \"\(r)\"")
            }
        }
        // Dismissals ORBIT must act on locally.
        for u in ["go away", "orbit go away", "leave me alone", "you\u{2019}re dismissed",
                  "off you go", "that\u{2019}ll be all", "shoo", "you can leave"] {
            if !OrbitVoiceIntentHelpers.isSessionStopCommand(u) {
                failures.append("dismissal missed → \"\(u)\"")
            }
        }
        for u in ["go away from the folder", "don\u{2019}t go away", "how far away is it",
                  "remind me to go away next month"] {
            if OrbitVoiceIntentHelpers.isSessionStopCommand(u) {
                failures.append("false dismissal → \"\(u)\"")
            }
        }

        let total = legacyPositives.count + newPositives.count + negatives.count
            + presenceQuestions.count + notQuestions.count + restIntents.count + notRestIntents.count + 27
        print("wake: legacy \(legacyPositives.count) · new \(newPositives.count) · negatives \(negatives.count)")
        print("questions: \(presenceQuestions.count) asked / \(notQuestions.count) plain summons")
        print("rest: \(restIntents.count) rest intents / \(notRestIntents.count) sleep commands")

        if failures.isEmpty {
            print("✅ wake corpus: all \(total) phrases behave correctly")
        } else {
            print("❌ \(failures.count) failure(s):")
            for f in failures { print("   \(f)") }
            exit(1)
        }
    }
}
