import Foundation

/// The same call eligibility rules apply to microphone and camera reads.
struct CallWindowSelection {
    let active: [WindowSnapshot]
    let excludedWindows: [ExcludedWindow]

    init(_ windows: [WindowSnapshot]) {
        let calls = windows.filter { window in
            window.controls.contains { $0.role == "AXButton" && $0.identifier == "hangup-button" }
        }
        func isHeld(_ window: WindowSnapshot) -> Bool {
            window.controls.contains { $0.role == "AXButton" && $0.identifier == "resume-button" }
        }
        active = calls.filter { !isHeld($0) }
        excludedWindows = calls.filter(isHeld).map { ExcludedWindow(window: $0.index, reason: "on_hold") }
    }

    func failureReason(complete: Bool) -> String? {
        if !complete { return "inspection_incomplete" }
        if active.isEmpty { return excludedWindows.isEmpty ? "no_call_controls" : "all_calls_on_hold" }
        if active.count > 1 { return "multiple_call_windows" }
        return nil
    }
}

enum ControlLabel {
    static func matches(_ label: String, action: String) -> Bool {
        let normalized = label.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ").lowercased()
        if normalized == action { return true }
        let prefix = action + " ("
        guard normalized.hasPrefix(prefix), normalized.hasSuffix(")") else { return false }
        let shortcut = String(normalized.dropFirst(prefix.count).dropLast())
        // A shortcut suffix is permitted; arbitrary extra descriptive text is not.
        let pattern = #"^(?:(?:⌘|⇧|⌃|⌥|command|cmd|control|ctrl|shift|option|alt|comando|controllo|maiusc)[ +\-]*)+[a-z0-9]$"#
        return shortcut.range(of: pattern, options: .regularExpression) != nil
    }
}
