public enum HandTarget: String, Codable {
    case raised
    case lowered

    var state: HandState { self == .raised ? .raised : .lowered }
}

/// `changed` is nil when a press was attempted but its final outcome is uncertain.
public struct HandActionResult: Codable {
    public let state: HandState
    public let reason: String?
    public let changed: Bool?
    public let actionAttempted: Bool
    public let focusUnchanged: Bool?
    public let windows: [WindowHandStatus]
    public let excludedWindows: [ExcludedWindow]
    public let success: Bool
}

struct HandObservation: MediaObservation {
    let assessment: HandAssessment
    /// Stable identity of the call and own-hand control, never a window index.
    let targetID: String?
    let canPress: Bool

    var state: HandState { assessment.state }
    var reason: String? { assessment.reason }
    var windowStates: [HandState] { assessment.windows.map(\.state) }
}

protocol HandBackend {
    func sample() throws -> HandObservation
    /// Consume the latest sample, then recheck live state, process and focus before pressing.
    func press(targetID: String, expectedState: HandState) throws
    func focusPreserved() -> Bool?
    func waitForUpdate()
}

/// Sets your own hand state through Teams' toggle control without retrying a press.
struct HandController {
    let backend: any HandBackend

    func set(_ target: HandTarget) throws -> HandActionResult {
        try perform { _ in target.state }
    }

    func toggle() throws -> HandActionResult {
        try perform { $0 == .raised ? .lowered : .raised }
    }

    private func perform(targetFor resolveTarget: (HandState) -> HandState) throws -> HandActionResult {
        let controller = MediaActionController(
            unknownState: HandState.unknown, knownStates: [.raised, .lowered],
            stateUnavailableReason: "hand_state_unavailable", verificationSamples: 8,
            requiresReadyControlToConfirm: false, sample: backend.sample,
            press: backend.press, focusPreserved: backend.focusPreserved,
            waitForUpdate: backend.waitForUpdate, retryIncompleteVerification: true)
        let result = try controller.perform(targetFor: resolveTarget)
        return HandActionResult(state: result.state, reason: result.reason,
                                changed: result.changed, actionAttempted: result.actionAttempted,
                                focusUnchanged: result.focusUnchanged,
                                windows: result.observation.assessment.windows,
                                excludedWindows: result.observation.assessment.excludedWindows,
                                success: result.success)
    }
}
