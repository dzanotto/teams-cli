import Foundation

public enum CallState: String, Codable {
    case active
    case ended
    case unknown
    case ambiguous
}

public struct WindowCallStatus: Codable, Equatable {
    public let window: Int
    public let state: CallState
}

struct CallAssessment {
    let state: CallState
    let reason: String?
    let windows: [WindowCallStatus]
    let excludedWindows: [ExcludedWindow]
}

/// Missing controls alone never establish that a call has ended.
enum CallEndClassifier {
    static func assess(_ windows: [WindowSnapshot], complete: Bool) -> CallAssessment {
        let selection = CallWindowSelection(windows)
        let statuses = selection.active.map { WindowCallStatus(window: $0.index, state: .active) }
        func result(_ state: CallState, _ reason: String?) -> CallAssessment {
            CallAssessment(state: state, reason: reason, windows: statuses,
                           excludedWindows: selection.excludedWindows)
        }
        if let reason = selection.failureReason(complete: complete) {
            return result(reason == "multiple_call_windows" ? .ambiguous : .unknown, reason)
        }
        let buttons = selection.active[0].controls.filter {
            $0.role == "AXButton" && $0.identifier == "hangup-button"
        }
        guard buttons.count == 1 else { return result(.ambiguous, "multiple_hangup_controls") }
        guard isLeaveButton(buttons[0]) else { return result(.unknown, "unrecognized_hangup_label") }
        return result(.active, nil)
    }

    static func isLeaveButton(_ control: ControlSnapshot) -> Bool {
        control.role == "AXButton" && control.identifier == "hangup-button" &&
            ["Leave", "Hang up", "Esci", "Abbandona"].contains { ControlLabel.matches(control.label, action: $0.lowercased()) }
    }
}

/// `ended` confirms that the pinned call window closed, not that a meeting ended for everyone.
public struct CallEndResult: Codable {
    public let state: CallState
    public let reason: String?
    public let changed: Bool?
    public let actionAttempted: Bool
    public let focusUnchanged: Bool?
    public let windows: [WindowCallStatus]
    public let excludedWindows: [ExcludedWindow]
    public let success: Bool

    func finalized(restored: Bool, focus: Bool?) -> CallEndResult {
        let changedAfterCleanupFailure: Bool? = actionAttempted ? nil : false
        return CallEndResult(state: restored ? state : .unknown,
                             reason: restored ? reason : "accessibility_cleanup_failed",
                             changed: restored ? changed : changedAfterCleanupFailure,
                             actionAttempted: actionAttempted, focusUnchanged: focus,
                             windows: windows, excludedWindows: excludedWindows,
                             success: restored && success)
    }
}

struct CallEndObservation {
    let assessment: CallAssessment
    let targetID: String?
    let canPress: Bool
}

/// Evidence tied to the selected process, window, and Leave button.
enum CallEndPresence {
    case sameCall
    case windowClosed
    case unconfirmed
    case changed
}

struct CallEndVerification {
    let assessment: CallAssessment
    let presence: CallEndPresence
}

protocol CallEndBackend {
    func sample() throws -> CallEndObservation
    /// Recheck call eligibility, identity and the Leave button immediately before dispatch.
    func press(targetID: String) throws
    func verify(targetID: String) throws -> CallEndVerification
    func focusPreserved() -> Bool?
    func waitForUpdate()
}

typealias CallEndPressRejected = MediaPressRejected

/// Leaves one pinned call with at most one press. Focus changes are allowed and reported.
struct CallEndController {
    let backend: any CallEndBackend

    func end() throws -> CallEndResult {
        var observation = try backend.sample()
        var assessment = observation.assessment
        var focus = backend.focusPreserved()

        func result(_ state: CallState, reason: String?, attempted: Bool = false,
                    changed: Bool? = false, success: Bool = false) -> CallEndResult {
            CallEndResult(state: state, reason: reason, changed: changed,
                          actionAttempted: attempted, focusUnchanged: focus,
                          windows: assessment.windows, excludedWindows: assessment.excludedWindows,
                          success: success)
        }

        if let reason = selectionFailure(assessment) { return result(assessment.state, reason: reason) }
        guard let targetID = observation.targetID else { return result(.unknown, reason: "control_unavailable") }

        observation = try backend.sample()
        assessment = observation.assessment
        focus = backend.focusPreserved()
        if let reason = selectionFailure(assessment) { return result(assessment.state, reason: reason) }
        guard observation.targetID == targetID else { return result(.unknown, reason: "target_changed") }
        guard observation.canPress else { return result(.unknown, reason: "control_unavailable") }

        do {
            try backend.press(targetID: targetID)
        } catch let rejection as CallEndPressRejected {
            focus = backend.focusPreserved()
            return result(.unknown, reason: rejection.reason)
        } catch {
            focus = backend.focusPreserved()
            return result(.unknown, reason: "action_outcome_unknown", attempted: true, changed: nil)
        }

        var consecutiveMatches = 0
        for _ in 0..<20 {
            backend.waitForUpdate()
            let verification: CallEndVerification
            do { verification = try backend.verify(targetID: targetID) }
            catch {
                focus = backend.focusPreserved()
                return result(.unknown, reason: "action_outcome_unknown", attempted: true, changed: nil)
            }
            assessment = verification.assessment
            focus = backend.focusPreserved()
            if verification.presence == .changed {
                return result(.unknown, reason: "target_changed", attempted: true, changed: nil)
            }
            // Absence of call controls is useful only with independent window-closure evidence.
            let noActiveCalls = assessment.reason == "no_call_controls" ||
                (assessment.reason == "all_calls_on_hold" && verification.presence == .windowClosed)
            if let reason = assessment.reason, !noActiveCalls {
                return result(.unknown, reason: reason, attempted: true, changed: nil)
            }
            let ended = verification.presence == .windowClosed &&
                noActiveCalls && assessment.windows.isEmpty
            consecutiveMatches = ended ? consecutiveMatches + 1 : 0
            if consecutiveMatches == 2 {
                return result(.ended, reason: nil, attempted: true, changed: true, success: true)
            }
        }
        return result(.unknown, reason: "verification_timeout", attempted: true, changed: nil)
    }

    private func selectionFailure(_ assessment: CallAssessment) -> String? {
        if let reason = assessment.reason { return reason }
        guard assessment.state == .active, assessment.windows.count == 1,
              assessment.windows[0].state == .active else { return "call_state_unavailable" }
        return nil
    }
}
