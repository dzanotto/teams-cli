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
typealias MicrophonePressRejected = MediaPressRejected

extension MicrophoneObservation: MediaObservation {
    var state: MicrophoneState { assessment.state }
    var reason: String? { assessment.reason }
    var windowStates: [MicrophoneState] { assessment.windows.map(\.state) }
}

/// Sets a known state through Teams' toggle control without retrying an action.
struct MicrophoneController {
    let backend: any MicrophoneBackend

    func set(_ target: MicrophoneTarget) throws -> MicrophoneActionResult {
        let controller = MediaActionController(
            unknownState: MicrophoneState.unknown, knownStates: [.muted, .unmuted],
            stateUnavailableReason: "microphone_state_unavailable", verificationSamples: 8,
            requiresReadyControlToConfirm: false, sample: backend.sample,
            press: backend.press, focusPreserved: backend.focusPreserved,
            waitForUpdate: backend.waitForUpdate)
        let result = try controller.set(target.state)
        return MicrophoneActionResult(state: result.state, reason: result.reason,
                                      changed: result.changed, actionAttempted: result.actionAttempted,
                                      focusUnchanged: result.focusUnchanged,
                                      windows: result.observation.assessment.windows,
                                      excludedWindows: result.observation.assessment.excludedWindows,
                                      success: result.success)
    }
}
