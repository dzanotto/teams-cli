/// Serializes cooperating action commands and changes your own hand state.
public enum TeamsHandCommands {
    public static func set(_ target: HandTarget) throws -> HandActionResult {
        try set(target, environment: .live)
    }

    /// Inverts the first confirmed hand state within the shared command lock.
    public static func toggle() throws -> HandActionResult {
        try toggle(environment: .live)
    }

    static func set<Focus: MediaCommandFocus>(
        _ target: HandTarget, environment: MediaActionEnvironment<Focus>
    ) throws -> HandActionResult {
        try perform({ try $0.set(target) }, environment: environment)
    }

    static func toggle<Focus: MediaCommandFocus>(environment: MediaActionEnvironment<Focus>) throws -> HandActionResult {
        try perform({ try $0.toggle() }, environment: environment)
    }

    private static func perform<Focus: MediaCommandFocus>(
        _ operation: (HandController) throws -> HandActionResult,
        environment: MediaActionEnvironment<Focus>
    ) throws -> HandActionResult {
        try TeamsMediaCommandSupport.perform({ focus in
            let backend = AccessibilityHandBackend(accessibility: environment.makeAccessibility(),
                                                   checkFocus: focus.preserved, waitForUpdate: environment.waitForUpdate)
            return try operation(HandController(backend: backend))
        }, environment: environment.lifecycle, onFinalizationFailure: { result, reason, focus in
            HandActionResult(state: .unknown, reason: reason,
                             changed: result.actionAttempted ? nil : false,
                             actionAttempted: result.actionAttempted, focusUnchanged: focus,
                             windows: result.windows, excludedWindows: result.excludedWindows,
                             success: false)
        })
    }
}

private final class AccessibilityHandBackend: HandBackend {
    private let native: NativeMediaBackend<HandAssessment, HandState>
    private let wait: () -> Void

    init(accessibility: any MediaAccessibilityClient, checkFocus: @escaping () -> Bool?,
         waitForUpdate: @escaping () -> Void) {
        wait = waitForUpdate
        native = NativeMediaBackend(control: .hand, accessibility: accessibility, checkFocus: checkFocus,
                                    stateChangedReason: "hand_state_changed",
                                    classify: HandClassifier.assess) { assessment in
            guard assessment.state == .raised || assessment.state == .lowered,
                  assessment.windows.count == 1 else { return nil }
            return MediaSelection(state: assessment.state, window: assessment.windows[0].window)
        }
    }

    func sample() throws -> HandObservation {
        let observation = try native.sample()
        return HandObservation(assessment: observation.assessment, targetID: observation.targetID,
                               canPress: observation.canPress)
    }

    func press(targetID: String, expectedState: HandState) throws {
        try native.press(targetID: targetID, expectedState: expectedState)
    }

    func focusPreserved() -> Bool? { native.focusPreserved() }
    func waitForUpdate() { wait() }
}
