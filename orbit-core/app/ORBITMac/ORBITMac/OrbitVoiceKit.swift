//
//  OrbitVoiceKit.swift
//  ORBITMac
//
//  Single shared speech + mic controllers so wake / HUD / menu UI use one pipeline.
//

import Foundation

@MainActor
final class OrbitVoiceKit {
    static let shared = OrbitVoiceKit()

    let speech = OrbitSpeechController()
    let speechInput = OrbitSpeechInputController()

    private init() {}
}
