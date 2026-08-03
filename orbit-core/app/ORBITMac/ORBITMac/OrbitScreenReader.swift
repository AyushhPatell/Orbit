//
//  OrbitScreenReader.swift
//  ORBITMac
//
//  Captures the primary display via ScreenCaptureKit and OCRs it with Vision.
//  The entitlement com.apple.security.screen-capture is required for sandboxed apps.
//
//  PERMISSION on macOS 26:
//  • Only the System Settings toggle controls access: Privacy & Security →
//    Screen & System Audio Recording → ORBITMac.
//  • CGPreflightScreenCaptureAccess() and CGRequestScreenCaptureAccess() check a
//    DIFFERENT (deprecated/removed) TCC entry that the System Settings toggle does NOT
//    write. On macOS 26 these always return false after tccutil reset regardless of the
//    toggle state. NEVER call them — they cause an infinite dialog loop.
//  • Call only SCShareableContent.current. If it throws, guide the user to the toggle.
//

import AppKit
import ScreenCaptureKit
import Vision

@MainActor
final class OrbitScreenReader {
    static let shared = OrbitScreenReader()
    private init() {}

    /// False only after captureForContext() confirms SCKit denies access (both tries fail).
    /// Starts optimistic — cold-start on macOS 26 can throw -3801 on the first call even
    /// when the toggle is ON; captureForContext() retries before concluding denial.
    private(set) var hasPermission: Bool = true

    /// Probe SCKit once — recovers hasPermission if the toggle was enabled since the last failure.
    func requestPermission() {
        Task {
            if (try? await SCShareableContent.current) != nil {
                hasPermission = true
            }
        }
    }

    /// Opens System Settings directly to Screen & System Audio Recording.
    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for urlString in urls {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }

    /// Captures the primary display (excluding ORBIT's own windows) and runs Vision OCR.
    /// Returns (appName, text) on success; nil on any failure.
    ///
    /// Does NOT call CGPreflightScreenCaptureAccess() or CGRequestScreenCaptureAccess().
    /// Those APIs check a legacy TCC entry that no longer exists on macOS 26 — calling them
    /// causes an infinite dialog loop because they always return false after tccutil reset,
    /// regardless of the System Settings toggle state.
    func captureForContext() async -> (appName: String, text: String)? {
        let appName = frontmostNonOrbitAppName()

        // Try SCKit. On macOS 26, the FIRST call per app launch triggers a system permission
        // dialog even when the toggle is ON. The call fails while the dialog is showing.
        // We retry with increasing delays to give the user time to dismiss the dialog.
        // We NEVER set hasPermission=false because on macOS 26 we can't distinguish
        // "permission denied" from "dialog pending" — staying optimistic avoids false negatives.
        var captureContent: SCShareableContent?
        for attempt in 0..<3 {
            do {
                captureContent = try await SCShareableContent.current
                hasPermission = true
                break
            } catch {
                if attempt < 2 {
                    let delay: UInt64 = attempt == 0 ? 500_000_000 : 1_500_000_000
                    try? await Task.sleep(nanoseconds: delay)
                } else {
                    return nil
                }
            }
        }

        guard let content = captureContent,
              let display = content.displays.first else { return nil }

        let orbitApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: orbitApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height

        do {
            let image: CGImage = try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: NSError(domain: "OrbitScreenReader", code: -1))
                    }
                }
            }

            let rawText = await recognizeText(in: image)
            guard !rawText.isEmpty else { return nil }

            let truncated = rawText.count > 2000
                ? String(rawText.prefix(1980)) + "\n…[truncated]"
                : rawText

            return (appName, truncated)
        } catch {
            return nil
        }
    }

    private func frontmostNonOrbitAppName() -> String {
        let ws = NSWorkspace.shared
        let own = Bundle.main.bundleIdentifier ?? ""
        if let front = ws.frontmostApplication, front.bundleIdentifier != own {
            return front.localizedName ?? "your screen"
        }
        return ws.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own && $0.isFinishedLaunching }
            .first?.localizedName ?? "your screen"
    }

    private func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
