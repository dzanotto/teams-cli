/// Serializes cooperating media commands and changes the selected camera button.
public enum TeamsCameraCommands {
    public static func set(_ target: CameraTarget) throws -> CameraActionResult {
        try set(target, environment: .live)
    }

    /// Inverts the first confirmed camera state within the shared command lock.
    public static func toggle() throws -> CameraActionResult {
        try toggle(environment: .live)
    }

    static func set<Focus: MediaCommandFocus>(
        _ target: CameraTarget, environment: MediaActionEnvironment<Focus>
    ) throws -> CameraActionResult {
        try perform({ try $0.set(target) }, environment: environment)
    }

    static func toggle<Focus: MediaCommandFocus>(environment: MediaActionEnvironment<Focus>) throws -> CameraActionResult {
        try perform({ try $0.toggle() }, environment: environment)
    }

    private static func perform<Focus: MediaCommandFocus>(
        _ operation: (CameraController) throws -> CameraActionResult,
        environment: MediaActionEnvironment<Focus>
    ) throws -> CameraActionResult {
        try TeamsMediaCommandSupport.perform({ focus in
            let backend = AccessibilityCameraBackend(accessibility: environment.makeAccessibility(),
                                                     checkFocus: focus.preserved, waitForUpdate: environment.waitForUpdate)
            return try operation(CameraController(backend: backend))
        }, environment: environment.lifecycle, onFinalizationFailure: { result, reason, focus in
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
    private let wait: () -> Void

    init(accessibility: any MediaAccessibilityClient, checkFocus: @escaping () -> Bool?,
         waitForUpdate: @escaping () -> Void) {
        wait = waitForUpdate
        native = NativeMediaBackend(control: .camera, accessibility: accessibility, checkFocus: checkFocus,
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
    func waitForUpdate() { wait() }
}
