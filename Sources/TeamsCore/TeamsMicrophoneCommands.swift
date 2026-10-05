public enum MicrophoneCommandError: Error {
    case commandInProgress
    case lockUnavailable
    case accessibilitySetupUnavailable
    case accessibilityCleanupFailed
}

/// Serializes cooperating media commands and changes the selected microphone button.
public enum TeamsMicrophoneCommands {
    public static func set(_ target: MicrophoneTarget) throws -> MicrophoneActionResult {
        try perform { try $0.set(target) }
    }

    /// Inverts the first confirmed microphone state within the shared command lock.
    public static func toggle() throws -> MicrophoneActionResult {
        try perform { try $0.toggle() }
    }

    private static func perform(
        _ operation: (MicrophoneController) throws -> MicrophoneActionResult
    ) throws -> MicrophoneActionResult {
        try TeamsMediaCommandSupport.perform({ focus in
            try operation(MicrophoneController(backend: AccessibilityMicrophoneBackend(focus: focus)))
        }, onFinalizationFailure: { result, reason, focus in
            MicrophoneActionResult(state: .unknown, reason: reason,
                                   changed: result.actionAttempted ? nil : false,
                                   actionAttempted: result.actionAttempted, focusUnchanged: focus,
                                   windows: result.windows, excludedWindows: result.excludedWindows,
                                   success: false)
        })
    }
}

private final class AccessibilityMicrophoneBackend: MicrophoneBackend {
    private let native: NativeMediaBackend<MicrophoneAssessment, MicrophoneState>

    init(focus: FocusMonitor) {
        native = NativeMediaBackend(control: .microphone, focus: focus,
                                    stateChangedReason: "microphone_state_changed",
                                    classify: MicrophoneClassifier.assess) { assessment in
            guard assessment.state == .muted || assessment.state == .unmuted,
                  assessment.windows.count == 1 else { return nil }
            return MediaSelection(state: assessment.state, window: assessment.windows[0].window)
        }
    }

    func sample() throws -> MicrophoneObservation {
        let observation = try native.sample()
        return MicrophoneObservation(assessment: observation.assessment, targetID: observation.targetID,
                                     canPress: observation.canPress)
    }

    func press(targetID: String, expectedState: MicrophoneState) throws {
        try native.press(targetID: targetID, expectedState: expectedState)
    }

    func focusPreserved() -> Bool? { native.focusPreserved() }
    func waitForUpdate() { native.waitForUpdate() }
}
