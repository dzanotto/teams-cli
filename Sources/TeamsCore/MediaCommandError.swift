/// Shared failures while acquiring the command lock or managing Accessibility exposure.
public enum MediaCommandError: Error {
    case commandInProgress
    case lockUnavailable
    case accessibilitySetupUnavailable
    case accessibilityCleanupFailed
}

/// Source-compatible name retained for callers of the original microphone API.
public typealias MicrophoneCommandError = MediaCommandError
