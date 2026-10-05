import Foundation
import Accessibility

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

/// Reads the user's own hand action, not participant indicators or the static "Raise" title.
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
        let states = buttons.map { button -> Set<HandState> in
            Set(([button.label] + (button.detailLabels ?? [])).compactMap(state))
        }
        let recognized = states.reduce(into: Set<HandState>()) { $0.formUnion($1) }
        if recognized.contains(.raised) && recognized.contains(.lowered) {
            return (.ambiguous, "conflicting_hand_controls")
        }
        guard states.allSatisfy({ !$0.isEmpty }), let state = recognized.first else {
            return (.unknown, "unrecognized_hand_label")
        }
        return (state, nil)
    }

    private static func state(for label: String) -> HandState? {
        let actions: [(String, HandState)] = [
            ("lower your hand", .raised), ("lower hand", .raised),
            ("raise your hand", .lowered), ("raise hand", .lowered),
            ("abbassa la mano", .raised), ("alza la mano", .lowered),
        ]
        for (action, state) in actions where ControlLabel.matches(label, action: action) { return state }
        return nil
    }
}

/// Chromium exposes the button's action description as securely archived AXCustomContent.
/// Only decode known value classes; malformed or unsupported content supplies no state.
enum AccessibilityCustomContent {
    static func labels(from raw: Any?) -> [String] {
        guard let data = raw as? Data, data.count <= 262_144 else { return [] }
        do {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
            decoder.requiresSecureCoding = true
            decoder.decodingFailurePolicy = .setErrorAndReturn
            defer { decoder.finishDecoding() }
            let classes: [AnyClass] = [NSArray.self, AXCustomContent.self, NSString.self,
                                       NSAttributedString.self, NSDictionary.self, NSNumber.self]
            guard let entries = decoder.decodeObject(of: classes, forKey: NSKeyedArchiveRootObjectKey) as? [AXCustomContent],
                  decoder.error == nil else { return [] }
            return entries.map(\.value)
        } catch {
            return []
        }
    }
}
