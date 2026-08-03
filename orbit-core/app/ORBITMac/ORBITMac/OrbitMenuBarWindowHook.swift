//
//  OrbitMenuBarWindowHook.swift
//  ORBITMac
//
//  Captures the SwiftUI MenuBarExtra (.window) NSWindow so we can order it to the front
//  after a wake phrase. SwiftUI does not expose a public “open MenuBarExtra” API yet.
//

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when “Hey ORBIT” is detected; userInfo may include `startVoice: Bool`.
    static let orbitWakeWordDetected = Notification.Name("orbitWakeWordDetected")

    /// Merge chat UI from the wake / backstage path (`userInfo`: reply, route, model, tierSource, clear_input, notice, notice_tone).
    static let orbitMacChatStateMerge = Notification.Name("orbitMacChatStateMerge")

    /// Live composer text from wake / backstage dictation (`userInfo`: `text` String).
    static let orbitMacComposerDraftMerge = Notification.Name("orbitMacComposerDraftMerge")
}

/// Holds a weak reference to the menu bar panel window discovered from the view hierarchy.
@MainActor
enum OrbitMenuBarWindowHolder {
    static weak var window: NSWindow?

    static func updateFrom(_ view: NSView) {
        window = view.window
    }

    /// Brings the ORBIT menu bar window forward with a short fade (if we have a window reference).
    static func presentAnimated() {
        NSApp.activate(ignoringOtherApps: true)
        guard let w = window else { return }
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            w.animator().alphaValue = 1
        }
    }
}

/// Invisible view that registers the hosting `NSWindow` for the MenuBarExtra content.
struct OrbitMenuBarWindowHookView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.isHidden = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let win = nsView.window {
                OrbitMenuBarWindowHolder.updateFrom(nsView)
                win.animationBehavior = .documentWindow
            }
        }
    }
}
