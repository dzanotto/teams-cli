import Foundation

public enum MicrophoneCommandError: Error {
    case commandInProgress
    case lockUnavailable
    case accessibilitySetupUnavailable
    case accessibilityCleanupFailed
}

/// Serializes cooperating media commands and changes the selected microphone button.
public enum TeamsMicrophoneCommands {
    public static func set(_ target: MicrophoneTarget) throws -> MicrophoneActionResult {
        try set(target, environment: .live)
    }

    /// Inverts the first confirmed microphone state within the shared command lock.
    public static func toggle() throws -> MicrophoneActionResult {
        try toggle(timings: nil)
    }

    /// Collect optional diagnostics without changing the action or its result.
    public static func toggle(timings: CommandTimings?) throws -> MicrophoneActionResult {
        try toggle(environment: .recordingTimings(timings), timings: timings)
    }

    static func set<Focus: MediaCommandFocus>(
        _ target: MicrophoneTarget, environment: MediaActionEnvironment<Focus>
    ) throws -> MicrophoneActionResult {
        try perform({ try $0.set(target) }, environment: environment)
    }

    static func toggle<Focus: MediaCommandFocus>(
        environment: MediaActionEnvironment<Focus>, timings: CommandTimings? = nil
    ) throws -> MicrophoneActionResult {
        try perform({ try $0.toggle() }, environment: environment, timings: timings)
    }

    private static func perform<Focus: MediaCommandFocus>(
        _ operation: (MicrophoneController) throws -> MicrophoneActionResult,
        environment: MediaActionEnvironment<Focus>, timings: CommandTimings? = nil
    ) throws -> MicrophoneActionResult {
        try TeamsMediaCommandSupport.perform({ focus in
            let backend = AccessibilityMicrophoneBackend(accessibility: environment.makeAccessibility(),
                                                         checkFocus: focus.preserved,
                                                         wait: environment.wait, timings: timings)
            return try operation(MicrophoneController(backend: backend, timings: timings))
        }, environment: environment.lifecycle, timings: timings, onFinalizationFailure: { result, reason, focus in
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
    private let wait: (TimeInterval) -> Void

    init(accessibility: any MediaAccessibilityClient, checkFocus: @escaping () -> Bool?,
         wait: @escaping (TimeInterval) -> Void, timings: CommandTimings?) {
        self.wait = wait
        native = NativeMediaBackend(control: .microphone, accessibility: accessibility, checkFocus: checkFocus,
                                    stateChangedReason: "microphone_state_changed",
                                    classify: MicrophoneClassifier.assess, timings: timings) { assessment in
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
    var verificationTimeRemaining: TimeInterval { native.verificationTimeRemaining }

    func waitForUpdate() {
        let remaining = verificationTimeRemaining
        guard remaining > 0 else { return }
        wait(min(MediaVerificationLimit.pollingInterval, remaining))
    }
}
