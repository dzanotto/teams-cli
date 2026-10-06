import Foundation
import TeamsCore

private let usage = """
Usage: teams-cli mic status [--json] [--window N]
       teams-cli mic <mute|unmute|toggle> [--json]
       teams-cli camera status [--json] [--window N]
       teams-cli camera <on|off|toggle> [--json]
       teams-cli hand status [--json] [--window N]
       teams-cli hand <raise|lower|toggle> [--json]
       teams-cli call end [--json]

Status output: mic = muted/unmuted; camera = on/off; hand = raised/lowered.
Call end reports ended after verified closure of the selected call window.
Inconclusive reads report unknown or ambiguous, with a reason.

Hand status reads your own hand and does not raise or lower it.
Mic, camera, and hand commands set a desired state and verify it, acting only when a change is needed.
Toggle requests the opposite of the first confirmed state for the chosen control.
Call end leaves your call; Teams may change focus when the call window closes.
Calls on hold are excluded, including when selected with --window.
Never explicitly activates Teams, sends keys, or shows permission dialogs.

  --json       Print machine-readable status and per-window results.
  --window N   Status only: inspect a window using its 1-based index from --json.
  -h, --help   Show this help, also after a command group or full command.

Exit codes: 0 known state or verified action; 2 unknown/ambiguous; 3 accessibility denied;
            4 Teams not running; 5 read failure; 6 action refused/unverified;
            64 invalid arguments.
"""

private enum MediaCommand: String { case mic, camera, call, hand }
private enum Operation: String { case status, mute, unmute, toggle, on, off, end, raise, lower }

private struct Options {
    let media: MediaCommand
    let operation: Operation
    var json = false
    var window: Int?

    init(_ arguments: [String]) throws {
        guard arguments.count >= 2, let media = MediaCommand(rawValue: arguments[0]),
              let operation = Operation(rawValue: arguments[1]) else { throw UsageError.invalid }
        switch (media, operation) {
        case (.mic, .status), (.camera, .status), (.hand, .status), (.mic, .toggle), (.camera, .toggle),
             (.mic, .mute), (.mic, .unmute), (.camera, .on), (.camera, .off), (.call, .end),
             (.hand, .raise), (.hand, .lower), (.hand, .toggle): break
        default: throw UsageError.invalid
        }
        self.media = media
        self.operation = operation
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                guard !json else { throw UsageError.invalid }
                json = true
            case "--window":
                guard window == nil, index + 1 < arguments.count,
                      let number = Int(arguments[index + 1]), number > 0 else { throw UsageError.invalid }
                window = number
                index += 1
            default: throw UsageError.invalid
            }
            index += 1
        }
        guard operation == .status || window == nil else { throw UsageError.invalid }
    }
}

private enum UsageError: Error { case invalid }

private struct WindowOutput: Encodable {
    let window: Int
    let state: String
}

private struct Output: Encodable {
    let media: MediaCommand
    let state: String
    let reason: String?
    let windows: [WindowOutput]
    let focusUnchanged: Bool?
    var excludedWindows: [ExcludedWindow] = []
    var action: String?
    var changed: Bool?
    var actionAttempted: Bool?
    var success: Bool?

    enum CodingKeys: String, CodingKey {
        case microphone, camera, call, hand, reason, windows, action, changed, success
        case focusUnchanged = "focus_unchanged"
        case excludedWindows = "excluded_windows"
        case actionAttempted = "action_attempted"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let stateKey: CodingKeys
        switch media {
        case .mic: stateKey = .microphone
        case .camera: stateKey = .camera
        case .call: stateKey = .call
        case .hand: stateKey = .hand
        }
        try container.encode(state, forKey: stateKey)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(focusUnchanged, forKey: .focusUnchanged)
        try container.encode(excludedWindows, forKey: .excludedWindows)
        if let action {
            try container.encode(action, forKey: .action)
            try container.encode(changed, forKey: .changed)
            try container.encodeIfPresent(actionAttempted, forKey: .actionAttempted)
            try container.encodeIfPresent(success, forKey: .success)
        }
    }
}

private func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func emit(_ output: Output, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(output)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            stderr("Could not encode status: \(error)")
            exit(5)
        }
    } else {
        print(output.state)
        if let reason = output.reason { stderr("Reason: \(reason)") }
        if output.state == "ambiguous" {
            for window in output.windows { stderr("Window \(window.window): \(window.state)") }
            if output.media != .call {
                stderr("Use --window N to read one window. Indices can change when Teams windows open or close.")
            }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let last = arguments.last, ["--help", "-h"].contains(last),
   arguments.count == 1 ||
    (arguments.count == 2 && MediaCommand(rawValue: arguments[0]) != nil) ||
    (arguments.count == 3 && (try? Options(Array(arguments.prefix(2)))) != nil) {
    print(usage)
    exit(0)
}

private let options: Options
do { options = try Options(arguments) }
catch { stderr(usage); exit(64) }

do {
    if options.operation != .status {
        let output: Output
        switch options.media {
        case .mic:
            let result = try options.operation == .toggle ? TeamsMicrophoneCommands.toggle() :
                TeamsMicrophoneCommands.set(options.operation == .mute ? .muted : .unmuted)
            output = Output(media: .mic, state: result.state.rawValue, reason: result.reason,
                            windows: result.windows.map { WindowOutput(window: $0.window, state: $0.state.rawValue) },
                            focusUnchanged: result.focusUnchanged, excludedWindows: result.excludedWindows,
                            action: options.operation.rawValue, changed: result.changed,
                            actionAttempted: result.actionAttempted, success: result.success)
        case .camera:
            let result = try options.operation == .toggle ? TeamsCameraCommands.toggle() :
                TeamsCameraCommands.set(options.operation == .on ? .on : .off)
            output = Output(media: .camera, state: result.state.rawValue, reason: result.reason,
                            windows: result.windows.map { WindowOutput(window: $0.window, state: $0.state.rawValue) },
                            focusUnchanged: result.focusUnchanged, excludedWindows: result.excludedWindows,
                            action: options.operation.rawValue, changed: result.changed,
                            actionAttempted: result.actionAttempted, success: result.success)
        case .call:
            let result = try TeamsCallCommands.end()
            output = Output(media: .call, state: result.state.rawValue, reason: result.reason,
                            windows: result.windows.map { WindowOutput(window: $0.window, state: $0.state.rawValue) },
                            focusUnchanged: result.focusUnchanged, excludedWindows: result.excludedWindows,
                            action: options.operation.rawValue, changed: result.changed,
                            actionAttempted: result.actionAttempted, success: result.success)
        case .hand:
            let result = try options.operation == .toggle ? TeamsHandCommands.toggle() :
                TeamsHandCommands.set(options.operation == .raise ? .raised : .lowered)
            output = Output(media: .hand, state: result.state.rawValue, reason: result.reason,
                            windows: result.windows.map { WindowOutput(window: $0.window, state: $0.state.rawValue) },
                            focusUnchanged: result.focusUnchanged, excludedWindows: result.excludedWindows,
                            action: options.operation.rawValue, changed: result.changed,
                            actionAttempted: result.actionAttempted, success: result.success)
        }
        emit(output, json: options.json)
        exit(output.success == true ? 0 : 6)
    }
    let control: MediaControl
    switch options.media {
    case .mic: control = .microphone
    case .camera: control = .camera
    case .hand: control = .hand
    case .call: throw UsageError.invalid
    }
    let snapshot = try TeamsAccessibilityReader().read(control: control)
    let windows = options.window.map { selected in snapshot.windows.filter { $0.index == selected } } ?? snapshot.windows
    if options.window != nil && windows.isEmpty {
        emit(Output(media: options.media, state: "unknown", reason: "window_not_found", windows: [],
                    focusUnchanged: snapshot.focusUnchanged), json: options.json)
        exit(2)
    }
    let output: Output
    switch options.media {
    case .mic:
        let assessment = MicrophoneClassifier.assess(windows, complete: snapshot.complete)
        output = Output(media: .mic, state: assessment.state.rawValue, reason: assessment.reason,
                        windows: assessment.windows.map { WindowOutput(window: $0.window, state: $0.state.rawValue) },
                        focusUnchanged: snapshot.focusUnchanged, excludedWindows: assessment.excludedWindows)
    case .camera:
        let assessment = CameraClassifier.assess(windows, complete: snapshot.complete)
        output = Output(media: .camera, state: assessment.state.rawValue, reason: assessment.reason,
                        windows: assessment.windows.map { WindowOutput(window: $0.window, state: $0.state.rawValue) },
                        focusUnchanged: snapshot.focusUnchanged, excludedWindows: assessment.excludedWindows)
    case .call:
        throw UsageError.invalid
    case .hand:
        let assessment = HandClassifier.assess(windows, complete: snapshot.complete)
        output = Output(media: .hand, state: assessment.state.rawValue, reason: assessment.reason,
                        windows: assessment.windows.map { WindowOutput(window: $0.window, state: $0.state.rawValue) },
                        focusUnchanged: snapshot.focusUnchanged, excludedWindows: assessment.excludedWindows)
    }
    emit(output, json: options.json)
    exit(["muted", "unmuted", "on", "off", "raised", "lowered"].contains(output.state) ? 0 : 2)
} catch {
    if error is UsageError { stderr(usage); exit(64) }
    let status: String
    let reason: String
    let code: Int32
    switch error {
    case TeamsReadError.accessibilityDenied:
        status = "permission_denied"
        reason = "accessibility_permission_required"
        code = 3
    case TeamsReadError.notRunning:
        status = "not_running"
        reason = "teams_not_running"
        code = 4
    case TeamsReadError.accessibilityFailure(let axCode):
        status = "unknown"
        reason = "accessibility_error_\(axCode)"
        code = 5
    case MicrophoneCommandError.commandInProgress:
        status = "unknown"
        reason = "command_in_progress"
        code = 6
    case MicrophoneCommandError.lockUnavailable:
        status = "unknown"
        reason = "command_lock_unavailable"
        code = 6
    case MicrophoneCommandError.accessibilitySetupUnavailable:
        status = "unknown"
        reason = "accessibility_setup_unavailable"
        code = 6
    case MicrophoneCommandError.accessibilityCleanupFailed:
        status = "unknown"
        reason = "accessibility_cleanup_failed"
        code = 6
    default:
        status = "unknown"
        reason = "read_failed"
        code = 5
    }
    var output = Output(media: options.media, state: status, reason: reason, windows: [], focusUnchanged: nil)
    if options.operation != .status {
        output.action = options.operation.rawValue
        output.actionAttempted = false
        output.changed = false
        output.success = false
    }
    emit(output, json: options.json)
    if !options.json && code == 3 {
        stderr("Enable Accessibility for the terminal or launcher running this command in System Settings > Privacy & Security > Accessibility, then retry. See README.md for setup.")
    }
    exit(code)
}
