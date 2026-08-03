//
//  ORBITMacApp.swift
//  ORBITMac
//
//  Created by Ayush on 2026-04-18.
//

import SwiftUI

@main
struct ORBITMacApp: App {
    @NSApplicationDelegateAdaptor(OrbitAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ORBIT", systemImage: "sparkles") {
            ContentView()
                .frame(width: 440, height: 860)
        }
        .menuBarExtraStyle(.window)
    }
}
