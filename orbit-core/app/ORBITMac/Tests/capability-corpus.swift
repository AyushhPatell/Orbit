//
//  capability-corpus.swift
//  Capability gates — what ORBIT is allowed to DO
//
//      orbit-core/app/ORBITMac/Tests/run-capability-corpus.sh
//
//  Ayush asked for guardrails months ago. Five privacy toggles existed but guarded only the
//  phrase-matched paths; when the brain got a full tool belt it could open apps, run
//  shortcuts, read files and change system state with nothing checking. ORBIT.md recorded the
//  hole plainly: "the brain can use any tool whenever the backing handler is allowed."
//
//  Two properties:
//    1. EVERY tool that acts on his machine or his data is behind a capability. A tool with
//       no gate is a tool nobody can switch off.
//    2. Defaults preserve today's behaviour exactly — this is a control panel, not a new set
//       of restrictions — except Terminal, which runs arbitrary shell commands.
//

import Foundation

@main
enum CapabilityCorpus {
    static func main() {
        var fails = 0

        // Every tool the brain can call, from ORBIT_TOOLS in brain.py.
        let acting = [
            "create_calendar_event", "list_calendar_events", "delete_calendar_event",
            "update_calendar_event", "create_reminder", "list_reminders", "delete_reminder",
            "complete_reminder", "create_note", "append_note", "open_app", "quit_app",
            "open_website", "web_search", "control_music", "control_volume",
            "control_brightness", "set_system_feature", "find_file", "open_folder",
            "run_shortcut", "lock_screen",
        ]
        // Read-only and harmless — no switch needed.
        let readOnly = ["get_battery_status", "get_weather", "get_focus_status"]

        for tool in acting where OrbitCapabilities.required(for: tool) == nil {
            print("❌ ungated tool — nobody can switch it off: \(tool)")
            fails += 1
        }
        for tool in readOnly where OrbitCapabilities.required(for: tool) != nil {
            print("❌ read-only tool should not need a capability: \(tool)")
            fails += 1
        }

        // Defaults must not change anything for him today.
        for capability in OrbitCapability.allCases {
            let expected = capability != .terminal
            if capability.defaultsToOn != expected {
                print("❌ \(capability.rawValue) default is \(capability.defaultsToOn), want \(expected)")
                fails += 1
            }
        }

        // Every capability has a name a person can read in a refusal.
        for capability in OrbitCapability.allCases where capability.displayName.isEmpty {
            print("❌ \(capability.rawValue) has no display name")
            fails += 1
        }

        // A refusal names the switch and does not read as a malfunction — ORBIT must not
        // report "failed" for something he deliberately turned off.
        for tool in ["open_app", "run_shortcut", "find_file", "control_volume"] {
            let text = OrbitCapabilities.refusal(for: tool)
            if !text.contains("switched off") || !text.lowercased().contains("gear menu") {
                print("❌ refusal doesn't name the switch for \(tool): \(text)")
                fails += 1
            }
            for word in ["error", "failed", "couldn't", "unable"] where text.lowercased().contains(word) {
                print("❌ refusal reads as a failure for \(tool): contains \"\(word)\"")
                fails += 1
            }
        }

        // Unknown tools are allowed through rather than silently blocked — a new tool must
        // not become invisible just because nobody added it to the table.
        if !OrbitCapabilities.isAllowed(tool: "some_future_tool") {
            print("❌ an unlisted tool should not be blocked by default")
            fails += 1
        }

        let total = acting.count + readOnly.count + OrbitCapability.allCases.count * 2 + 4 + 1
        print("capabilities: \(acting.count) acting tools · \(readOnly.count) read-only · \(OrbitCapability.allCases.count) switches")
        print(fails == 0
              ? "✅ capability corpus: all \(total) checks behave correctly"
              : "❌ \(fails) failure(s)")
        exit(fails == 0 ? 0 : 1)
    }
}
