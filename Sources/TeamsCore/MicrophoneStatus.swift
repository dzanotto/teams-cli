import Foundation

public struct ControlSnapshot: Codable, Equatable {
    public let role: String
    public let identifier: String
    public let label: String

    public init(role: String, identifier: String, label: String) {
        self.role = role
        self.identifier = identifier
        self.label = label
    }
}

public struct WindowSnapshot: Codable, Equatable {
    public let index: Int
    public let controls: [ControlSnapshot]

    public init(index: Int, controls: [ControlSnapshot]) {
        self.index = index
        self.controls = controls
    }
}

public enum MicrophoneState: String, Codable {
    case muted
    case unmuted
    case unknown
    case ambiguous
}

public struct WindowMicrophoneStatus: Codable, Equatable {
    public let window: Int
    public let state: MicrophoneState

    public init(window: Int, state: MicrophoneState) {
        self.window = window
        self.state = state
    }
}

public struct ExcludedWindow: Codable, Equatable {
    public let window: Int
    public let reason: String

    public init(window: Int, reason: String) {
        self.window = window
        self.reason = reason
    }
}

public struct MicrophoneAssessment {
    public let state: MicrophoneState
    public let reason: String?
    public let windows: [WindowMicrophoneStatus]
    public let excludedWindows: [ExcludedWindow]

    public init(state: MicrophoneState, reason: String?, windows: [WindowMicrophoneStatus],
                excludedWindows: [ExcludedWindow] = []) {
        self.state = state
        self.reason = reason
        self.windows = windows
        self.excludedWindows = excludedWindows
    }
}

/// Interprets the action offered by Teams' microphone button as its current state.
/// A hang-up button in the same window is required to exclude pre-join controls.
/// A call's exact resume button identifies a held window to exclude from selection.
public enum MicrophoneClassifier {
    public static func assess(_ windows: [WindowSnapshot], complete: Bool) -> MicrophoneAssessment {
        let selection = CallWindowSelection(windows)
        let calls = selection.active
        let excludedWindows = selection.excludedWindows
        let classifications = calls.map(classify)
        let statuses = zip(calls, classifications).map { window, result in
            WindowMicrophoneStatus(window: window.index, state: result.state)
        }

        // A missed surface could contain another call, so partial inspection cannot
        // establish a definitive overall state, even when one button was readable.
        if let reason = selection.failureReason(complete: complete) {
            return MicrophoneAssessment(state: reason == "multiple_call_windows" ? .ambiguous : .unknown,
                                        reason: reason, windows: statuses,
                                        excludedWindows: excludedWindows)
        }
        let result = classifications[0]
        return MicrophoneAssessment(state: result.state, reason: result.reason, windows: statuses,
                                    excludedWindows: excludedWindows)
    }

    private static func classify(_ window: WindowSnapshot) -> (state: MicrophoneState, reason: String?) {
        let microphones = window.controls.filter { isButton($0, identifier: "microphone-button") }
        guard !microphones.isEmpty else {
            return (.unknown, "microphone_control_missing")
        }
        let states = microphones.map { state(for: $0.label) }
        if states.contains(.muted) && states.contains(.unmuted) {
            return (.ambiguous, "conflicting_microphone_controls")
        }
        guard !states.contains(.unknown) else {
            return (.unknown, "unrecognized_microphone_label")
        }
        return (states[0], nil)
    }

    private static func isButton(_ control: ControlSnapshot, identifier: String) -> Bool {
        control.role == "AXButton" && control.identifier == identifier
    }

    private static func state(for label: String) -> MicrophoneState {
        let actions: [(String, MicrophoneState)] = [
            ("mute mic", .unmuted),
            ("unmute mic", .muted),
            ("disattiva microfono", .unmuted),
            ("attiva microfono", .muted),
        ]
        for (action, state) in actions {
            if ControlLabel.matches(label, action: action) { return state }
        }
        return .unknown
    }

}
