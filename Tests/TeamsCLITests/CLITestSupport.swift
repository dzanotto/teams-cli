import Foundation
import XCTest
@testable import TeamsCLI
@testable import TeamsCore

struct CLIResult {
    let code: Int32
    let stdout: String
    let stderr: String
}

enum CLIStubError: Error { case unexpected }

let cliActionRoutes: [(arguments: [String], handler: String)] = [
    (["mic", "mute"], "mic:muted"), (["mic", "unmute"], "mic:unmuted"), (["mic", "toggle"], "mic:toggle"),
    (["camera", "on"], "camera:on"), (["camera", "off"], "camera:off"), (["camera", "toggle"], "camera:toggle"),
    (["hand", "raise"], "hand:raised"), (["hand", "lower"], "hand:lowered"), (["hand", "toggle"], "hand:toggle"),
    (["call", "end"], "call:end")
]

func cliWindow(_ index: Int = 1, microphone: String = "Mute mic", camera: String = "Turn camera off",
               raised: Bool = false, held: Bool = false) -> WindowSnapshot {
    let handMarker = raised ? ", Hand raised position 1" : ""
    var controls = [
        ControlSnapshot(role: "AXButton", identifier: "microphone-button", label: microphone),
        ControlSnapshot(role: "AXButton", identifier: "video-button", label: camera),
        ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave"),
        ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise your hand"),
        ControlSnapshot(role: "AXImage", identifier: "",
                        label: "Myself video, Test User, Video is off\(handMarker), Has context menu")
    ]
    if held { controls.append(ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")) }
    return WindowSnapshot(index: index, controls: controls)
}

func cliJSON(_ result: CLIResult, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    XCTAssertEqual(result.stderr, "", file: file, line: line)
    XCTAssertTrue(result.stdout.hasSuffix("\n"), file: file, line: line)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                         file: file, line: line)
}

func assertCLIJSON(_ result: CLIResult, equals expected: [String: Any],
                   file: StaticString = #filePath, line: UInt = #line) throws {
    let actual = try cliJSON(result, file: file, line: line)
    XCTAssertEqual(actual as NSDictionary, expected as NSDictionary, file: file, line: line)
}

final class CLIStub {
    var snapshot = TeamsSnapshot(windows: [cliWindow()], complete: true, focusUnchanged: true)
    var microphone = MicrophoneActionResult(state: .muted, reason: nil, changed: true, actionAttempted: true,
                                           focusUnchanged: true, windows: [], excludedWindows: [], success: true)
    var camera = CameraActionResult(state: .off, reason: nil, changed: true, actionAttempted: true,
                                   focusUnchanged: true, windows: [], excludedWindows: [], success: true)
    var hand = HandActionResult(state: .raised, reason: nil, changed: true, actionAttempted: true,
                               focusUnchanged: true, windows: [], excludedWindows: [], success: true)
    var call = CallEndResult(state: .ended, reason: nil, changed: true, actionAttempted: true,
                            focusUnchanged: true, windows: [], excludedWindows: [], success: true)
    var error: Error?
    private(set) var calls: [String] = []

    func useActionResults(success: Bool, changed: Bool?, attempted: Bool, focus: Bool?,
                          reason: String? = nil, unknown: Bool = false) {
        let excluded = [ExcludedWindow(window: 12, reason: "on_hold")]
        microphone = MicrophoneActionResult(state: unknown ? .unknown : .unmuted, reason: reason, changed: changed,
                                           actionAttempted: attempted, focusUnchanged: focus,
                                           windows: [WindowMicrophoneStatus(window: 7, state: .unmuted)],
                                           excludedWindows: excluded, success: success)
        camera = CameraActionResult(state: unknown ? .unknown : .on, reason: reason, changed: changed,
                                   actionAttempted: attempted, focusUnchanged: focus,
                                   windows: [WindowCameraStatus(window: 7, state: .on)],
                                   excludedWindows: excluded, success: success)
        hand = HandActionResult(state: unknown ? .unknown : .lowered, reason: reason, changed: changed,
                               actionAttempted: attempted, focusUnchanged: focus,
                               windows: [WindowHandStatus(window: 7, state: .lowered)],
                               excludedWindows: excluded, success: success)
        call = CallEndResult(state: unknown ? .unknown : .ended, reason: reason, changed: changed,
                            actionAttempted: attempted, focusUnchanged: focus,
                            windows: [WindowCallStatus(window: 7, state: unknown ? .active : .ended)],
                            excludedWindows: excluded, success: success)
    }

    func run(_ arguments: [String]) -> CLIResult {
        var stdout = ""
        var stderr = ""
        let runner = CommandRunner(handlers: handlers, writeStdout: { stdout += $0 }, writeStderr: { stderr += $0 })
        let code = runner.run(arguments)
        return CLIResult(code: code, stdout: stdout, stderr: stderr)
    }

    private func record(_ name: String) throws {
        calls.append(name)
        if let error { throw error }
    }

    private var handlers: CommandHandlers {
        CommandHandlers(readStatus: {
            try self.record("read:\($0.rawValue)")
            return self.snapshot
        }, setMicrophone: {
            try self.record("mic:\($0.rawValue)")
            return self.microphone
        }, toggleMicrophone: {
            try self.record("mic:toggle")
            return self.microphone
        }, setCamera: {
            try self.record("camera:\($0.rawValue)")
            return self.camera
        }, toggleCamera: {
            try self.record("camera:toggle")
            return self.camera
        }, setHand: {
            try self.record("hand:\($0.rawValue)")
            return self.hand
        }, toggleHand: {
            try self.record("hand:toggle")
            return self.hand
        }, endCall: {
            try self.record("call:end")
            return self.call
        })
    }
}
