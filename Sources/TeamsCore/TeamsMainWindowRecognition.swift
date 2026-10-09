/// Recognizes the Teams main shell from fixed, nonlocalized control identifiers.
/// A match identifies the shell, not the absence of call controls elsewhere in its tree.
struct TeamsMainWindowRecognition {
    enum Result: String, Encodable {
        case unknown
        case mainShell = "main_shell"
        case callSurface = "call_surface"
        case conflicting
        case incomplete
    }

    private(set) var hasProfile = false
    private(set) var hasSearch = false
    private(set) var hasCallControls = false
    private var failed = false

    var result: Result {
        guard !failed else { return .incomplete }
        if hasCallControls { return hasProfile && hasSearch ? .conflicting : .callSurface }
        return hasProfile && hasSearch ? .mainShell : .unknown
    }

    mutating func observe(role: String, identifiers: [String], complete: Bool = true) {
        guard complete else {
            failed = true
            return
        }
        if role == "AXButton" {
            hasProfile = hasProfile || identifiers.contains("idna-me-control-avatar-trigger")
            hasCallControls = hasCallControls || identifiers.contains {
                ["microphone-button", "video-button", "hangup-button", "resume-button", "raisehands-button"].contains($0)
            }
        } else if role == "AXComboBox" {
            hasSearch = hasSearch || identifiers.contains("ms-searchux-input")
        }
    }
}
