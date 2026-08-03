//
//  OrbitConversationState.swift
//  ORBITMac
//
//  Always-alive singleton that shadows the most recent chat exchange.
//  ContentView's .onReceive is torn down when the menu bar panel closes, so
//  any wake-word reply posted while the panel is hidden gets missed.
//  This singleton keeps listening and ContentView syncs with it on every onAppear.
//

import Foundation

@MainActor
final class OrbitConversationState {
    static let shared = OrbitConversationState()

    private(set) var responseText: String = ""
    private(set) var lastRoute: String = "—"
    private(set) var lastModel: String = "—"
    private(set) var lastTierSource: String = "—"

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .orbitMacChatStateMerge,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract Sendable String values before crossing into the Task.
            let reply  = note.userInfo?["reply"]      as? String
            let route  = note.userInfo?["route"]      as? String
            let model  = note.userInfo?["model"]      as? String
            let tier   = note.userInfo?["tierSource"] as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let reply, !reply.isEmpty { self.responseText = reply }
                if let route { self.lastRoute = route }
                if let model { self.lastModel = model }
                if let tier  { self.lastTierSource = tier }
            }
        }
    }
}
