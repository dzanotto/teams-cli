import Foundation

public enum CameraTarget: String, Codable {
    case on
    case off

    var state: CameraState { self == .on ? .on : .off }
}

/// `changed` is nil when a press was attempted but its final outcome is uncertain.
public struct CameraActionResult: Codable {
    public let state: CameraState
    public let reason: String?
    public let changed: Bool?
    public let actionAttempted: Bool
    public let focusUnchanged: Bool?
    public let windows: [WindowCameraStatus]
    public let excludedWindows: [ExcludedWindow]
    public let success: Bool
}

struct CameraObservation {
    let assessment: CameraAssessment
    /// Stable identity of the call and camera control, never a window index.
    let targetID: String?
    let canPress: Bool
}

protocol CameraBackend {
    func sample() throws -> CameraObservation
    /// Recheck the target and expected state immediately before the single press.
    func press(targetID: String, expectedState: CameraState) throws
    func focusPreserved() -> Bool?
    func waitForUpdate()
}

/// A backend rejection that guarantees no AXPress was dispatched.
typealias CameraPressRejected = MediaPressRejected

extension CameraObservation: MediaObservation {
    var state: CameraState { assessment.state }
    var reason: String? { assessment.reason }
    var windowStates: [CameraState] { assessment.windows.map(\.state) }
}

/// Camera startup may briefly disable the control after its label has changed.
/// Confirm twice only after the desired state and a ready control are observed.
struct CameraController {
    let backend: any CameraBackend

    func set(_ target: CameraTarget) throws -> CameraActionResult {
        try perform { _ in target.state }
    }

    func toggle() throws -> CameraActionResult {
        try perform { $0 == .on ? .off : .on }
    }

    private func perform(targetFor resolveTarget: (CameraState) -> CameraState) throws -> CameraActionResult {
        let controller = MediaActionController(
            unknownState: CameraState.unknown, knownStates: [.on, .off],
            stateUnavailableReason: "camera_state_unavailable", verificationSamples: 20,
            requiresReadyControlToConfirm: true, sample: backend.sample,
            press: backend.press, focusPreserved: backend.focusPreserved,
            waitForUpdate: backend.waitForUpdate)
        let result = try controller.perform(targetFor: resolveTarget)
        return CameraActionResult(state: result.state, reason: result.reason,
                                  changed: result.changed, actionAttempted: result.actionAttempted,
                                  focusUnchanged: result.focusUnchanged,
                                  windows: result.observation.assessment.windows,
                                  excludedWindows: result.observation.assessment.excludedWindows,
                                  success: result.success)
    }
}
