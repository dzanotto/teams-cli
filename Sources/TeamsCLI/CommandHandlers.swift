import TeamsCore

/// Typed command boundaries keep live Accessibility actions out of CLI contract tests.
struct CommandHandlers {
    let readStatus: (MediaControl) throws -> TeamsSnapshot
    let setMicrophone: (MicrophoneTarget) throws -> MicrophoneActionResult
    let toggleMicrophone: () throws -> MicrophoneActionResult
    let setCamera: (CameraTarget) throws -> CameraActionResult
    let toggleCamera: () throws -> CameraActionResult
    let setHand: (HandTarget) throws -> HandActionResult
    let toggleHand: () throws -> HandActionResult
    let endCall: () throws -> CallEndResult

    static var live: Self {
        Self(readStatus: { try TeamsAccessibilityReader().read(control: $0) },
             setMicrophone: TeamsMicrophoneCommands.set, toggleMicrophone: TeamsMicrophoneCommands.toggle,
             setCamera: TeamsCameraCommands.set, toggleCamera: TeamsCameraCommands.toggle,
             setHand: TeamsHandCommands.set, toggleHand: TeamsHandCommands.toggle,
             endCall: TeamsCallCommands.end)
    }
}
