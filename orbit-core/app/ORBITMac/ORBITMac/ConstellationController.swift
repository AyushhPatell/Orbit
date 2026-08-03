//
//  ConstellationController.swift
//  ORBITMac
//
//  Separate full-screen overlay panel for wake constellation choices.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ConstellationController {
    static let shared = ConstellationController()

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?

    private init() {}

    func bootstrap() {
        guard panel == nil else { return }
        guard let screen = NSScreen.main else { return }

        let host = NSHostingController(rootView: ConstellationRootView())
        let p = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        // Voice-first: keep display-only in this phase.
        p.ignoresMouseEvents = true
        p.contentView = host.view
        panel = p

        cancellable = Publishers.CombineLatest(
            OrbitListeningPresence.shared.$constellationVisible,
            OrbitListeningPresence.shared.$constellationItems
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] visible, items in
            self?.apply(visible: visible, itemsCount: items.count)
        }

        apply(
            visible: OrbitListeningPresence.shared.constellationVisible,
            itemsCount: OrbitListeningPresence.shared.constellationItems.count
        )
    }

    private func apply(visible: Bool, itemsCount: Int) {
        guard let panel else { return }
        guard visible, itemsCount > 0 else {
            panel.orderOut(nil)
            return
        }
        if let screen = NSScreen.main {
            panel.setFrame(screen.frame, display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }
}
