/// Serializes cooperating action commands and changes your own hand state.
public enum TeamsHandCommands {
    public static func set(_ target: HandTarget) throws -> HandActionResult {
        try TeamsMediaCommandSupport.perform({ focus in
            try HandController(backend: AccessibilityHandBackend(focus: focus)).set(target)
        }, onFinalizationFailure: { result, reason, focus in
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

    init(focus: FocusMonitor) {
        native = NativeMediaBackend(control: .hand, focus: focus,
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
    func waitForUpdate() { native.waitForUpdate() }
}
