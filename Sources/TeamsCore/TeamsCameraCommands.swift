/// Serializes cooperating media commands and changes the selected camera button.
public enum TeamsCameraCommands {
    public static func set(_ target: CameraTarget) throws -> CameraActionResult {
        try perform { try $0.set(target) }
    }

    /// Inverts the first confirmed camera state within the shared command lock.
    public static func toggle() throws -> CameraActionResult {
        try perform { try $0.toggle() }
    }

    private static func perform(
        _ operation: (CameraController) throws -> CameraActionResult
    ) throws -> CameraActionResult {
        try TeamsMediaCommandSupport.perform({ focus in
            try operation(CameraController(backend: AccessibilityCameraBackend(focus: focus)))
        }, onFinalizationFailure: { result, reason, focus in
            CameraActionResult(state: .unknown, reason: reason,
                               changed: result.actionAttempted ? nil : false,
                               actionAttempted: result.actionAttempted, focusUnchanged: focus,
                               windows: result.windows, excludedWindows: result.excludedWindows,
                               success: false)
        })
    }
}

private final class AccessibilityCameraBackend: CameraBackend {
    private let native: NativeMediaBackend<CameraAssessment, CameraState>

    init(focus: FocusMonitor) {
        native = NativeMediaBackend(control: .camera, focus: focus,
                                    stateChangedReason: "camera_state_changed",
                                    classify: CameraClassifier.assess) { assessment in
            guard assessment.state == .on || assessment.state == .off,
                  assessment.windows.count == 1 else { return nil }
            return MediaSelection(state: assessment.state, window: assessment.windows[0].window)
        }
    }

    func sample() throws -> CameraObservation {
        let observation = try native.sample()
        return CameraObservation(assessment: observation.assessment, targetID: observation.targetID,
                                 canPress: observation.canPress)
    }

    func press(targetID: String, expectedState: CameraState) throws {
        try native.press(targetID: targetID, expectedState: expectedState)
    }

    func focusPreserved() -> Bool? { native.focusPreserved() }
    func waitForUpdate() { native.waitForUpdate() }
}
