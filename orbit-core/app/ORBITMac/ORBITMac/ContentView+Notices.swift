//
//  ContentView+Notices.swift
//  ORBITMac
//

import SwiftUI

extension ContentView {

    // MARK: - Global notice banner

    var noticeBanner: some View {
        Group {
            if let userNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: noticeIconName)
                        .font(.body)
                        .foregroundStyle(noticeAccentColor)
                    Text(userNotice)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        clearNotice()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(11)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(noticeBackgroundFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(noticeStrokeColor, lineWidth: 1)
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: userNotice)
    }

    var noticeIconName: String {
        switch userNoticeTone {
        case .neutral: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .issue: return "exclamationmark.triangle.fill"
        }
    }

    var noticeAccentColor: Color {
        switch userNoticeTone {
        case .neutral: return .secondary
        case .success: return .green
        case .issue: return .orange
        }
    }

    var noticeBackgroundFill: Color {
        switch userNoticeTone {
        case .neutral: return Color(nsColor: .controlBackgroundColor).opacity(0.55)
        case .success: return Color.green.opacity(0.1)
        case .issue: return Color.orange.opacity(0.1)
        }
    }

    var noticeStrokeColor: Color {
        switch userNoticeTone {
        case .neutral: return Color.secondary.opacity(0.35)
        case .success: return Color.green.opacity(0.35)
        case .issue: return Color.orange.opacity(0.4)
        }
    }

    @MainActor
    func presentNotice(
        _ text: String?,
        tone: UserNoticeTone = .neutral,
        autoClearSuccessAfter seconds: TimeInterval = 0
    ) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            userNotice = text
            userNoticeTone = text == nil ? .neutral : tone
        }
        guard tone == .success, let t = text, seconds > 0 else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run {
                if userNotice == t {
                    clearNotice()
                }
            }
        }
    }

    @MainActor
    func clearNotice() {
        withAnimation(.easeOut(duration: 0.18)) {
            userNotice = nil
            userNoticeTone = .neutral
        }
    }

    // MARK: - Actions-section feedback banner

    var actionFeedbackBanner: some View {
        Group {
            if let actionFeedback {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: actionFeedbackIconName)
                        .font(.body)
                        .foregroundStyle(actionFeedbackAccentColor)
                    Text(actionFeedback)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        clearActionFeedback()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(11)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(actionFeedbackBackgroundFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(actionFeedbackStrokeColor, lineWidth: 1)
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: actionFeedback)
    }

    var actionFeedbackIconName: String {
        switch actionFeedbackTone {
        case .neutral: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .issue: return "exclamationmark.triangle.fill"
        }
    }

    var actionFeedbackAccentColor: Color {
        switch actionFeedbackTone {
        case .neutral: return .secondary
        case .success: return .green
        case .issue: return .orange
        }
    }

    var actionFeedbackBackgroundFill: Color {
        switch actionFeedbackTone {
        case .neutral: return Color(nsColor: .controlBackgroundColor).opacity(0.55)
        case .success: return Color.green.opacity(0.1)
        case .issue: return Color.orange.opacity(0.1)
        }
    }

    var actionFeedbackStrokeColor: Color {
        switch actionFeedbackTone {
        case .neutral: return Color.secondary.opacity(0.35)
        case .success: return Color.green.opacity(0.35)
        case .issue: return Color.orange.opacity(0.4)
        }
    }

    @MainActor
    func presentActionFeedback(
        _ text: String?,
        tone: UserNoticeTone = .neutral,
        autoClearSuccessAfter seconds: TimeInterval = 0
    ) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            actionFeedback = text
            actionFeedbackTone = text == nil ? .neutral : tone
        }
        guard let t = text, seconds > 0 else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run {
                if actionFeedback == t {
                    clearActionFeedback()
                }
            }
        }
    }

    @MainActor
    func clearActionFeedback() {
        withAnimation(.easeOut(duration: 0.18)) {
            actionFeedback = nil
            actionFeedbackTone = .neutral
        }
    }
}
