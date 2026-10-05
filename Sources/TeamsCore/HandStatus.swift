import Foundation

public enum HandState: String, Codable {
    case raised
    case lowered
    case unknown
    case ambiguous
}

public struct WindowHandStatus: Codable, Equatable {
    public let window: Int
    public let state: HandState

    public init(window: Int, state: HandState) {
        self.window = window
        self.state = state
    }
}

public struct HandAssessment {
    public let state: HandState
    public let reason: String?
    public let windows: [WindowHandStatus]
    public let excludedWindows: [ExcludedWindow]

    public init(state: HandState, reason: String?, windows: [WindowHandStatus],
                excludedWindows: [ExcludedWindow] = []) {
        self.state = state
        self.reason = reason
        self.windows = windows
        self.excludedWindows = excludedWindows
    }
}

/// Reads the user's own video-tile indicator. Button descriptions can remain stale after AXPress.
public enum HandClassifier {
    public static func assess(_ windows: [WindowSnapshot], complete: Bool) -> HandAssessment {
        let selection = CallWindowSelection(windows)
        let classifications = selection.active.map(classify)
        let statuses = zip(selection.active, classifications).map { window, result in
            WindowHandStatus(window: window.index, state: result.state)
        }
        if let reason = selection.failureReason(complete: complete) {
            return HandAssessment(state: reason == "multiple_call_windows" ? .ambiguous : .unknown,
                                  reason: reason, windows: statuses, excludedWindows: selection.excludedWindows)
        }
        let result = classifications[0]
        return HandAssessment(state: result.state, reason: result.reason, windows: statuses,
                              excludedWindows: selection.excludedWindows)
    }

    private static func classify(_ window: WindowSnapshot) -> (state: HandState, reason: String?) {
        let buttons = window.controls.filter {
            $0.role == "AXButton" && $0.identifier == "raisehands-button"
        }
        guard !buttons.isEmpty else { return (.unknown, "hand_control_missing") }
        let indicators = window.controls.filter { OwnVideoHandIndicator.matches($0) }
        guard !indicators.isEmpty else { return (.unknown, "own_video_missing") }
        guard indicators.count == 1 else { return (.ambiguous, "multiple_own_videos") }
        guard let state = OwnVideoHandIndicator.state(for: indicators[0].label) else {
            return (.unknown, "unrecognized_own_video_label")
        }
        return (state, nil)
    }
}

/// Only the explicit self-video description is eligible; participant names are never matched.
/// A complete recognized description is required before absence of the raised marker means lowered.
enum OwnVideoHandIndicator {
    static func matches(_ control: ControlSnapshot) -> Bool {
        control.role == "AXImage" && fields(control.label).first == "myself video"
    }

    static func state(for label: String) -> HandState? {
        let parts = fields(label)
        guard parts.first == "myself video", parts.last == "has context menu",
              let video = parts.lastIndex(where: { $0 == "video is on" || $0 == "video is off" }),
              video >= 2, video < parts.count - 1 else { return nil }
        // Skip the name and other metadata. A participant's name cannot supply a hand marker.
        let markers = parts[(video + 1)..<(parts.count - 1)].filter { $0.contains("hand") }
        if markers.isEmpty { return .lowered }
        guard markers.count == 1,
              markers[0].range(of: "^hand raised position [1-9][0-9]*$", options: .regularExpression) != nil else {
            return nil
        }
        return .raised
    }

    /// Used for the final live recheck as well as full scans; no tooltip/custom-content reads.
    static func read(value: (String) -> Any?) -> ControlSnapshot {
        ControlSnapshot(role: value("AXRole") as? String ?? "", identifier: "",
                        label: value("AXDescription") as? String ?? "")
    }

    private static func fields(_ label: String) -> [String] {
        label.lowercased().split(separator: ",", omittingEmptySubsequences: false).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}
