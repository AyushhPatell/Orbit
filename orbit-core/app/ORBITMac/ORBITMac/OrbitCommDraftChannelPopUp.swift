//
//  OrbitCommDraftChannelPopUp.swift
//  ORBITMac
//
//  AppKit pop-up for channel selection. SwiftUI Menu often fails to open inside MenuBarExtra popovers.
//

import AppKit
import SwiftUI

struct OrbitCommDraftChannelPopUp: NSViewRepresentable {
    @Binding var selection: OrbitCommDraftChannel

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: OrbitCommDraftChannelPopUp
        init(_ parent: OrbitCommDraftChannelPopUp) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < OrbitCommDraftChannel.allCases.count else { return }
            parent.selection = OrbitCommDraftChannel.allCases[idx]
        }
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for ch in OrbitCommDraftChannel.allCases {
            button.addItem(withTitle: ch.rawValue)
        }
        if let idx = OrbitCommDraftChannel.allCases.firstIndex(of: selection) {
            button.selectItem(at: idx)
        }
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let idx = button.indexOfSelectedItem
        let current: OrbitCommDraftChannel? =
            if idx >= 0, idx < OrbitCommDraftChannel.allCases.count {
                OrbitCommDraftChannel.allCases[idx]
            } else { nil }
        if current != selection, let want = OrbitCommDraftChannel.allCases.firstIndex(of: selection) {
            button.selectItem(at: want)
        }
    }
}
