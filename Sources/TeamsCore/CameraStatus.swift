import Foundation

public enum CameraState: String, Codable {
    case on
    case off
    case unknown
    case ambiguous
}

public struct WindowCameraStatus: Codable, Equatable {
    public let window: Int
    public let state: CameraState

    public init(window: Int, state: CameraState) {
        self.window = window
        self.state = state
    }
}

public struct CameraAssessment {
    public let state: CameraState
    public let reason: String?
    public let windows: [WindowCameraStatus]
    public let excludedWindows: [ExcludedWindow]

    public init(state: CameraState, reason: String?, windows: [WindowCameraStatus],
                excludedWindows: [ExcludedWindow] = []) {
        self.state = state
        self.reason = reason
        self.windows = windows
        self.excludedWindows = excludedWindows
    }
}

/// Interprets Teams' camera button action as the opposite of its current state.
/// Only established calls are considered; held calls are excluded.
public enum CameraClassifier {
    public static func assess(_ windows: [WindowSnapshot], complete: Bool) -> CameraAssessment {
        let selection = CallWindowSelection(windows)
        let classifications = selection.active.map(classify)
        let statuses = zip(selection.active, classifications).map { window, result in
            WindowCameraStatus(window: window.index, state: result.state)
        }

        if let reason = selection.failureReason(complete: complete) {
            return CameraAssessment(state: reason == "multiple_call_windows" ? .ambiguous : .unknown,
                                    reason: reason, windows: statuses,
                                    excludedWindows: selection.excludedWindows)
        }

        let result = classifications[0]
        return CameraAssessment(state: result.state, reason: result.reason, windows: statuses,
                                excludedWindows: selection.excludedWindows)
    }

    private static func classify(_ window: WindowSnapshot) -> (state: CameraState, reason: String?) {
        let cameras = window.controls.filter {
            $0.role == "AXButton" && $0.identifier == "video-button"
        }
        guard !cameras.isEmpty else {
            return (.unknown, "camera_control_missing")
        }
        let states = cameras.map { state(for: $0.label) }
        if states.contains(.on) && states.contains(.off) {
            return (.ambiguous, "conflicting_camera_controls")
        }
        guard !states.contains(.unknown) else {
            return (.unknown, "unrecognized_camera_label")
        }
        return (states[0], nil)
    }

    private static func state(for label: String) -> CameraState {
        let actions: [(String, CameraState)] = [
            ("turn camera off", .on),
            ("turn camera on", .off),
            ("disattiva videocamera", .on),
            ("attiva videocamera", .off),
        ]
        for (action, state) in actions where ControlLabel.matches(label, action: action) {
            return state
        }
        return .unknown
    }
}
