//
//  OrbitAppDelegate.swift
//  ORBITMac
//
//  Starts optional wake-word listening, floating listening HUD, and backstage wake voice
//  (mic + /chat without opening the menu bar panel).
//

import AppKit
import UserNotifications

final class OrbitAppDelegate: NSObject, NSApplicationDelegate {
    private var wakeObserver: NSObjectProtocol?

    /// Carries settings over from the old App Sandbox container.
    ///
    /// While sandboxed, preferences lived in `~/Library/Containers/<bundle-id>/Data/Library/
    /// Preferences/`. Unsandboxed, the app reads `~/Library/Preferences/` — a domain that starts
    /// out empty, so every setting silently read as `false`. That is what turned off
    /// `listenForHeyOrbit` and left ORBIT unable to hear "Hey ORBIT" with no error anywhere.
    /// Runs once, and never overwrites values that already exist.
    private static func migratePreferencesFromSandboxContainerIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "orbitMac.didMigrateSandboxPreferences") == nil else { return }
        defer { defaults.set(true, forKey: "orbitMac.didMigrateSandboxPreferences") }

        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let containerPlist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
        guard FileManager.default.fileExists(atPath: containerPlist.path),
              let data = try? Data(contentsOf: containerPlist),
              let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }

        var carried = 0
        for (key, value) in stored where key.hasPrefix("orbit") {
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            carried += 1
        }
        if carried > 0 {
            print("[ORBIT] Migrated \(carried) settings from the old sandbox container.")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kill any stale ORBIT instances from prior Xcode builds — prevents duplicate menu bar icons.
        let myBundleID = Bundle.main.bundleIdentifier ?? ""
        if !myBundleID.isEmpty {
            NSRunningApplication.runningApplications(withBundleIdentifier: myBundleID)
                .filter { $0 != NSRunningApplication.current }
                .forEach { $0.forceTerminate() }
        }

        UNUserNotificationCenter.current().delegate = self
        Self.migratePreferencesFromSandboxContainerIfNeeded()

        UserDefaults.standard.register(defaults: [
            "orbitMac.wakeWordAutoListen": true,
            "orbitMac.proactiveNotifications": true,
            "orbitMac.proactiveVoiceAnnounce": false,
            "orbitMac.morningBriefingEnabled": false,
            "orbitMac.morningBriefingHour": 9,
        ])

        Task { @MainActor in
            _ = OrbitConversationState.shared  // start listening for replies before any wake event
            OrbitListeningHUDController.shared.bootstrap()
            ConstellationController.shared.bootstrap()
            OrbitWakeVoiceBackstage.shared.bootstrap()
            OrbitWakeWordController.shared.applicationDidFinishLaunching()
            OrbitProactiveNotifier.shared.bootstrap()
            await OrbitReminderService.shared.requestAccessIfNeeded()
            // Do NOT call warmUp() here. On macOS 26, calling SCShareableContent.current
            // at launch when TCC is in "undetermined" state (after tccutil reset) triggers
            // the system permission dialog before the user has done anything. We let
            // captureForContext() handle the first probe on first explicit user request.
        }

        wakeObserver = NotificationCenter.default.addObserver(
            forName: .orbitWakeWordDetected,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                OrbitListeningPresence.shared.beginWakeAttention()
                // Intentionally do not open the menu bar panel — voice + floating HUD only.
            }
        }
    }

    deinit {
        if let wakeObserver {
            NotificationCenter.default.removeObserver(wakeObserver)
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension OrbitAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + play sound even when ORBIT's panel is open (app is active).
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle "Done" and "Remind me in 30 min" button taps on follow-up notifications.
        let userInfo = response.notification.request.content.userInfo
        if response.actionIdentifier != UNNotificationDefaultActionIdentifier,
           response.actionIdentifier != UNNotificationDismissActionIdentifier {
            Task { @MainActor in
                OrbitProactiveNotifier.shared.handleNotificationResponse(
                    actionID: response.actionIdentifier,
                    userInfo: userInfo
                )
            }
        }
        completionHandler()
    }
}
