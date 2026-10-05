import Foundation

public enum MicrophoneTarget: String, Codable {
    case muted
    case unmuted

    var state: MicrophoneState { self == .muted ? .muted : .unmuted }
}

/// `changed` is nil when a press was attempted but its final outcome is uncertain.
public struct MicrophoneActionResult: Codable {
    public let state: MicrophoneState
    public let reason: String?
    public let changed: Bool?
    public let actionAttempted: Bool
    public let focusUnchanged: Bool?
    public let windows: [WindowMicrophoneStatus]
    public let excludedWindows: [ExcludedWindow]
    public let success: Bool
}

struct MicrophoneObservation {
    let assessment: MicrophoneAssessment
    /// Stable identity of the call and microphone control, never a window index.
    let targetID: String?
    let canPress: Bool
}

protocol MicrophoneBackend {
    func sample() throws -> MicrophoneObservation
    /// Recheck the target and expected state immediately before the single press.
    func press(targetID: String, expectedState: MicrophoneState) throws
    func focusPreserved() -> Bool?
    func waitForUpdate()
}

/// A backend rejection that guarantees no AXPress was dispatched.
struct MicrophonePressRejected: Error {
    let reason: String
}

/// Sets a known state through Teams' toggle control without retrying an action.
struct MicrophoneController {
    let backend: any MicrophoneBackend

    func set(_ target: MicrophoneTarget) throws -> MicrophoneActionResult {
        var observation = try backend.sample()
        var focus = backend.focusPreserved()

        func result(state: MicrophoneState, reason: String?, attempted: Bool = false,
                    changed: Bool? = false, success: Bool = false) -> MicrophoneActionResult {
            MicrophoneActionResult(state: state, reason: reason, changed: changed,
                                   actionAttempted: attempted, focusUnchanged: focus,
                                   windows: observation.assessment.windows,
                                   excludedWindows: observation.assessment.excludedWindows,
                                   success: success)
        }

        if let reason = selectionFailure(observation) {
            return result(state: observation.assessment.state, reason: reason)
        }
        guard let targetID = observation.targetID else {
            return result(state: .unknown, reason: "control_unavailable")
        }
        if let reason = focusFailure(focus) { return result(state: .unknown, reason: reason) }
        if observation.assessment.state == target.state {
            return result(state: target.state, reason: nil, success: true)
        }

        // Sampling again catches changes made since the initial state was read.
        // A control that moved to a different call must never inherit this action.
        observation = try backend.sample()
        focus = backend.focusPreserved()
        if let reason = selectionFailure(observation) {
            return result(state: observation.assessment.state, reason: reason)
        }
        guard observation.targetID == targetID else {
            return result(state: .unknown, reason: "target_changed")
        }
        if let reason = focusFailure(focus) { return result(state: .unknown, reason: reason) }
        if observation.assessment.state == target.state {
            return result(state: target.state, reason: nil, success: true)
        }
        guard observation.canPress else {
            return result(state: .unknown, reason: "control_unavailable")
        }

        // Only a typed pre-dispatch rejection guarantees no action was sent.
        // Every other error may mean Teams acted; never retry the press.
        do {
            try backend.press(targetID: targetID, expectedState: observation.assessment.state)
        } catch let rejection as MicrophonePressRejected {
            focus = backend.focusPreserved()
            return result(state: .unknown, reason: rejection.reason)
        } catch {
            focus = backend.focusPreserved()
            return result(state: .unknown, reason: "action_outcome_unknown", attempted: true, changed: nil)
        }
        focus = backend.focusPreserved()
        if let reason = focusFailure(focus) {
            return result(state: .unknown, reason: reason, attempted: true, changed: nil)
        }

        var consecutiveMatches = 0
        for _ in 0..<8 {
            backend.waitForUpdate()
            do {
                observation = try backend.sample()
            } catch {
                focus = backend.focusPreserved()
                return result(state: .unknown, reason: "action_outcome_unknown", attempted: true, changed: nil)
            }
            focus = backend.focusPreserved()
            if let reason = focusFailure(focus) {
                return result(state: .unknown, reason: reason, attempted: true, changed: nil)
            }
            if let reason = selectionFailure(observation) {
                return result(state: .unknown, reason: reason, attempted: true, changed: nil)
            }
            guard observation.targetID == targetID else {
                return result(state: .unknown, reason: "target_changed", attempted: true, changed: nil)
            }
            consecutiveMatches = observation.assessment.state == target.state ? consecutiveMatches + 1 : 0
            if consecutiveMatches == 2 {
                return result(state: target.state, reason: nil, attempted: true, changed: true, success: true)
            }
        }
        return result(state: .unknown, reason: "verification_timeout", attempted: true, changed: nil)
    }

    private func focusFailure(_ focus: Bool?) -> String? {
        guard let focus else { return "focus_unavailable" }
        return focus ? nil : "focus_changed"
    }

    private func selectionFailure(_ observation: MicrophoneObservation) -> String? {
        let assessment = observation.assessment
        if let reason = assessment.reason { return reason }
        guard assessment.windows.count == 1 else {
            return assessment.windows.isEmpty ? "no_call_controls" : "multiple_call_windows"
        }
        guard assessment.state == .muted || assessment.state == .unmuted,
              assessment.windows[0].state == assessment.state else {
            return "microphone_state_unavailable"
        }
        return nil
    }
}
