//
//  OrbitVoiceSession.swift
//  ORBITMac
//
//  Single source of truth for where the voice pipeline currently is.
//  Owns the wake → mic → reply → followup lifecycle for OrbitWakeVoiceBackstage:
//  `.awaitingFollowup` is the gate for reopening the mic, `.ending(_)`/`.idle`
//  mean the turn is over. It performs no side effects — callers read `state`
//  (and `lastReplyWasQuestion`) to decide what to do next.
//

import Combine
import Foundation

enum VoicePipelineState: Equatable {
    case idle
    case wakeArmed
    case wakeTriggered
    case listening
    case committing(String)
    case thinking(String)
    case responding(ResponsePlan)
    case awaitingFollowup
    case ending(EndReason)
}

struct ResponsePlan: Equatable {
    let willResume: Bool
    let lastReplyWasQuestion: Bool
}

enum EndReason: Equatable {
    case stopCommand
    case gratitude
    case displayOnlyResult
    case error
    case userCancelled
}

@MainActor
final class OrbitVoiceSession: ObservableObject {
    static let shared = OrbitVoiceSession()

    @Published private(set) var state: VoicePipelineState = .idle

    /// Mirrors the most recent `.responding` plan's `lastReplyWasQuestion`. Read by gratitude
    /// detection so it doesn't have to pattern-match associated values just to read a bool.
    private(set) var lastReplyWasQuestion = false

    private init() {}

    func transition(to newState: VoicePipelineState) {
        let current = state
        guard isLegalTransition(from: current, to: newState) else {
            OrbitFailureTelemetry.shared.logIllegalVoiceTransition(
                from: Self.label(for: current),
                to: Self.label(for: newState)
            )
            return
        }
        if case .responding(let plan) = newState {
            lastReplyWasQuestion = plan.lastReplyWasQuestion
        }
        state = newState
    }

    /// Hard re-initialization between sessions. Not a pipeline edge — this models the
    /// entry points clobbering the boolean flags to start a fresh capture, abandoning
    /// whatever the previous turn left behind. Bypasses legality on purpose; never call
    /// this mid-turn, only at a voice-session entry point.
    func reset() {
        if state != .idle { state = .idle }
    }

    // Edges are matched on the case only; associated values (transcript, plan, reason)
    // never affect legality.
    private func isLegalTransition(from: VoicePipelineState, to: VoicePipelineState) -> Bool {
        switch from {
        case .idle:
            switch to {
            case .wakeArmed, .listening: return true
            default: return false
            }
        case .wakeArmed:
            switch to {
            case .wakeTriggered, .idle: return true
            default: return false
            }
        case .wakeTriggered:
            switch to {
            case .listening, .idle: return true
            case .ending(.error): return true
            default: return false
            }
        case .listening:
            switch to {
            case .committing, .idle: return true
            case .ending(.userCancelled), .ending(.error): return true
            default: return false
            }
        case .committing:
            switch to {
            case .thinking, .responding, .ending: return true
            default: return false
            }
        case .thinking:
            switch to {
            case .responding: return true
            case .ending(.error): return true
            default: return false
            }
        case .responding:
            switch to {
            case .awaitingFollowup, .ending, .listening: return true
            default: return false
            }
        case .awaitingFollowup:
            switch to {
            case .listening, .idle: return true
            case .ending(.userCancelled), .ending(.error): return true
            default: return false
            }
        case .ending:
            switch to {
            case .idle: return true
            default: return false
            }
        }
    }

    private static func label(for state: VoicePipelineState) -> String {
        switch state {
        case .idle: return "idle"
        case .wakeArmed: return "wakeArmed"
        case .wakeTriggered: return "wakeTriggered"
        case .listening: return "listening"
        case .committing: return "committing"
        case .thinking: return "thinking"
        case .responding: return "responding"
        case .awaitingFollowup: return "awaitingFollowup"
        case .ending(let reason): return "ending(\(reason))"
        }
    }
}
