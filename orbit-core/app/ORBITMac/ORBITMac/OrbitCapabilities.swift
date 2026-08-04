//
//  OrbitCapabilities.swift
//  ORBITMac
//
//  What ORBIT is allowed to do, as a gate the brain cannot talk its way past.
//
//  Ayush asked for guardrails months ago and they were never finished. Five privacy toggles
//  existed — screen reading, contacts, email, clipboard, conversation memory — but they only
//  guarded the *phrase-matched* paths. When the brain got a full tool belt (Phase 1), it
//  gained the ability to open apps, run shortcuts, read files and change system state with
//  nothing checking whether those capabilities were wanted. ORBIT.md recorded the hole
//  plainly: "the brain can use any tool whenever the backing handler is allowed."
//
//  This closes it at the one place every brain tool must pass through — the dispatcher.
//  A disabled capability is not a prompt instruction the model might ignore; the tool simply
//  does not run, and ORBIT says so honestly instead of pretending it failed.
//
//  Defaults are ON for everything that already worked. This is a control panel, not a new
//  set of restrictions: nothing changes for him until he turns something off.
//

import Foundation

enum OrbitCapability: String, CaseIterable {
    case calendar        = "orbitMac.capCalendar"
    case reminders       = "orbitMac.capReminders"
    case notes           = "orbitMac.capNotes"
    case apps            = "orbitMac.capApps"
    case browser         = "orbitMac.capBrowser"
    case media           = "orbitMac.capMedia"
    case systemSettings  = "orbitMac.capSystem"
    case files           = "orbitMac.capFiles"
    case smartHome       = "orbitMac.capSmartHome"
    case terminal        = "orbitMac.capTerminal"

    /// What ORBIT calls it when explaining that it's switched off.
    var displayName: String {
        switch self {
        case .calendar:       return "Calendar"
        case .reminders:      return "Reminders"
        case .notes:          return "Notes"
        case .apps:           return "Opening apps"
        case .browser:        return "Web browsing"
        case .media:          return "Music control"
        case .systemSettings: return "System settings"
        case .files:          return "Files & folders"
        case .smartHome:      return "Smart home"
        case .terminal:       return "Terminal commands"
        }
    }

    /// Terminal is the one capability that is off unless asked for: it runs arbitrary shell
    /// commands, and it already carries a confirmation ceremony on the phrase path.
    var defaultsToOn: Bool { self != .terminal }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: rawValue) as? Bool ?? defaultsToOn
    }
}

enum OrbitCapabilities {

    /// Which capability a brain tool needs. Unlisted tools are read-only or harmless
    /// (battery, weather, focus status) and are always allowed.
    static func required(for tool: String) -> OrbitCapability? {
        switch tool {
        case "create_calendar_event", "list_calendar_events",
             "delete_calendar_event", "update_calendar_event":
            return .calendar
        case "create_reminder", "list_reminders", "delete_reminder", "complete_reminder":
            return .reminders
        case "create_note", "append_note":
            return .notes
        case "open_app", "quit_app":
            return .apps
        case "open_website", "web_search":
            return .browser
        case "control_music":
            return .media
        case "control_volume", "control_brightness", "set_system_feature", "lock_screen":
            return .systemSettings
        case "find_file", "open_folder":
            return .files
        case "run_shortcut":
            return .smartHome
        default:
            return nil
        }
    }

    static func isAllowed(tool: String) -> Bool {
        required(for: tool)?.isEnabled ?? true
    }

    /// Plain, non-blaming refusal that names the switch. ORBIT must not report this as a
    /// failure — nothing broke, it simply isn't allowed, and he is the one who decides.
    static func refusal(for tool: String) -> String {
        guard let capability = required(for: tool) else {
            return "I'm not able to do that one right now."
        }
        return "\(capability.displayName) is switched off in ORBIT's settings, so I didn't do "
             + "that. You can turn it back on under the gear menu → Capabilities."
    }
}
