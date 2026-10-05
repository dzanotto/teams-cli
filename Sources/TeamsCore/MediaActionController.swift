import Foundation

/// An observation retains its media-specific assessment for the public result.
protocol MediaObservation {
    associatedtype State: Equatable
    var state: State { get }
    var reason: String? { get }
    var windowStates: [State] { get }
    var targetID: String? { get }
    var canPress: Bool { get }
}

struct MediaActionOutcome<Observation: MediaObservation> {
    let state: Observation.State
    let reason: String?
    let changed: Bool?
    let actionAttempted: Bool
    let focusUnchanged: Bool?
    let observation: Observation
    let success: Bool
}

/// A backend rejection that guarantees no AXPress was dispatched.
struct MediaPressRejected: Error {
    let reason: String
}

/// Shared safety rules for controls that offer a toggle rather than a desired-state API.
struct MediaActionController<Observation: MediaObservation> {
    let unknownState: Observation.State
    let knownStates: [Observation.State]
    let stateUnavailableReason: String
    let verificationSamples: Int
    let requiresReadyControlToConfirm: Bool
    let sample: () throws -> Observation
    let press: (String, Observation.State) throws -> Void
    let focusPreserved: () -> Bool?
    let waitForUpdate: () -> Void

    func set(_ target: Observation.State) throws -> MediaActionOutcome<Observation> {
        var observation = try sample()
        var focus = focusPreserved()

        func result(state: Observation.State, reason: String?, attempted: Bool = false,
                    changed: Bool? = false, success: Bool = false) -> MediaActionOutcome<Observation> {
            MediaActionOutcome(state: state, reason: reason, changed: changed,
                               actionAttempted: attempted, focusUnchanged: focus,
                               observation: observation, success: success)
        }

        if let reason = selectionFailure(observation) {
            return result(state: observation.state, reason: reason)
        }
        guard let targetID = observation.targetID else {
            return result(state: unknownState, reason: "control_unavailable")
        }
        if let reason = focusFailure(focus) { return result(state: unknownState, reason: reason) }
        if observation.state == target {
            return result(state: target, reason: nil, success: true)
        }

        // Re-read before dispatch: a replacement call must never inherit an action.
        observation = try sample()
        focus = focusPreserved()
        if let reason = selectionFailure(observation) {
            return result(state: observation.state, reason: reason)
        }
        guard observation.targetID == targetID else {
            return result(state: unknownState, reason: "target_changed")
        }
        if let reason = focusFailure(focus) { return result(state: unknownState, reason: reason) }
        if observation.state == target {
            return result(state: target, reason: nil, success: true)
        }
        guard observation.canPress else {
            return result(state: unknownState, reason: "control_unavailable")
        }

        // Only a typed pre-dispatch rejection guarantees no action was sent.
        // Every other error may mean Teams acted; never retry the press.
        do {
            try press(targetID, observation.state)
        } catch let rejection as MediaPressRejected {
            focus = focusPreserved()
            return result(state: unknownState, reason: rejection.reason)
        } catch {
            focus = focusPreserved()
            return result(state: unknownState, reason: "action_outcome_unknown", attempted: true, changed: nil)
        }
        focus = focusPreserved()
        if let reason = focusFailure(focus) {
            return result(state: unknownState, reason: reason, attempted: true, changed: nil)
        }

        var consecutiveMatches = 0
        for _ in 0..<verificationSamples {
            waitForUpdate()
            do {
                observation = try sample()
            } catch {
                focus = focusPreserved()
                return result(state: unknownState, reason: "action_outcome_unknown", attempted: true, changed: nil)
            }
            focus = focusPreserved()
            if let reason = focusFailure(focus) {
                return result(state: unknownState, reason: reason, attempted: true, changed: nil)
            }
            if let reason = selectionFailure(observation) {
                return result(state: unknownState, reason: reason, attempted: true, changed: nil)
            }
            guard observation.targetID == targetID else {
                return result(state: unknownState, reason: "target_changed", attempted: true, changed: nil)
            }
            let settled = observation.state == target && (!requiresReadyControlToConfirm || observation.canPress)
            consecutiveMatches = settled ? consecutiveMatches + 1 : 0
            if consecutiveMatches == 2 {
                return result(state: target, reason: nil, attempted: true, changed: true, success: true)
            }
        }
        return result(state: unknownState, reason: "verification_timeout", attempted: true, changed: nil)
    }

    private func focusFailure(_ focus: Bool?) -> String? {
        guard let focus else { return "focus_unavailable" }
        return focus ? nil : "focus_changed"
    }

    private func selectionFailure(_ observation: Observation) -> String? {
        if let reason = observation.reason { return reason }
        guard observation.windowStates.count == 1 else {
            return observation.windowStates.isEmpty ? "no_call_controls" : "multiple_call_windows"
        }
        guard knownStates.contains(observation.state), observation.windowStates[0] == observation.state else {
            return stateUnavailableReason
        }
        return nil
    }
}
