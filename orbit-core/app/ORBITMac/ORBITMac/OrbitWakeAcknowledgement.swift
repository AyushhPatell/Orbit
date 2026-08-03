//
//  OrbitWakeAcknowledgement.swift
//  ORBITMac
//
//  A short spoken answer when the wake phrase was also a question.
//
//  "Are you there ORBIT?" used to open a listening orb and say nothing. That answers the summons
//  and ignores the question — the exact thing that makes ORBIT feel like a machine rather than
//  someone in the room.
//
//  Why this is local text rather than a brain call, given that Phase 3.4 deliberately removed
//  ORBIT's canned conversational replies:
//
//    • Those replies were canned *answers* — "how are you?" met with a fixed
//      "All good and ready to go", which is a machine pretending to converse. This is an
//      acknowledgement of presence, which is formulaic even between people ("Yeah?", "I'm here").
//    • It must be instant. Ayush's ask is that ORBIT "speaks and immediately listens back" — a
//      round-trip to the brain before he is allowed to talk defeats the point.
//    • It must work with no network. A wake phrase that only answers when online is worse than
//      one that never answers.
//
//  What keeps it from feeling canned: it never repeats the previous line, and it knows what time
//  it is. If a reply here ever needs to be *about* something, it belongs in the brain, not here.
//

import Foundation

enum OrbitWakeAcknowledgement {

    /// The last line spoken, so the same one is never used twice running.
    private static var lastSpoken: String?

    private static let anytime = [
        "Yes, I\u{2019}m here.",
        "I\u{2019}m here \u{2014} go ahead.",
        "Right here.",
        "Yeah, tell me.",
        "Here. What\u{2019}s up?",
        "I\u{2019}m listening.",
        "Awake and listening.",
        "Yep, go on.",
        "Still here.",
        "I\u{2019}m around \u{2014} what do you need?",
    ]

    private static let earlyMorning = [
        "Morning. I\u{2019}m here.",
        "Up early \u{2014} what do you need?",
        "Morning. Go ahead.",
    ]

    private static let lateNight = [
        "Still up with you. Go ahead.",
        "I\u{2019}m here \u{2014} late one tonight.",
        "Here. What\u{2019}s keeping you up?",
    ]

    /// A short reply for a wake phrase that asked a question.
    static func line(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        var pool = anytime
        if hour >= 5, hour < 10 {
            pool += earlyMorning
        } else if hour >= 23 || hour < 3 {
            pool += lateNight
        }

        let candidates = pool.filter { $0 != lastSpoken }
        let chosen = candidates.randomElement() ?? pool[0]
        lastSpoken = chosen
        return chosen
    }
}
