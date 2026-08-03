//
//  ContentView+Types.swift
//  ORBITMac
//
//  Shared enums used across ContentView and its extensions.
//

import Foundation

enum ORBITLayout {
    static let outerPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let innerSpacing: CGFloat = 10
    static let conversationMinHeight: CGFloat = 220
    static let cardCorner: CGFloat = 12
    static let cardFillOpacity: Double = 0.32
    static let cardStrokeOpacity: Double = 0.38
}

enum UserNoticeTone {
    case neutral
    case success
    case issue
}

enum ActionsActiveTool {
    case shortcut
    case calendarEvent
    case webAgent
    case communicationDraft
}

enum PendingWebAction {
    case openSite(url: URL)
    case webSearch(query: String, url: URL)
    case summarize(url: URL)
    case draftReply(url: URL, request: String?)
}

enum WebAgentMode: String, CaseIterable, Identifiable {
    case openSite = "Open Site"
    case searchWeb = "Search Web"
    case summarizePage = "Summarize Page"
    case draftFromPage = "Draft From Page"

    var id: String { rawValue }
}
