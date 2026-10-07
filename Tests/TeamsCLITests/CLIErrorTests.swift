import XCTest
@testable import TeamsCore

final class CLIErrorTests: XCTestCase {
    private let readFailures: [(Error, String, String, Int32)] = [
        (TeamsReadError.accessibilityDenied, "permission_denied", "accessibility_permission_required", 3),
        (TeamsReadError.notRunning, "not_running", "teams_not_running", 4),
        (TeamsReadError.accessibilityFailure(-25204), "unknown", "accessibility_error_-25204", 5),
        (CLIStubError.unexpected, "unknown", "read_failed", 5)
    ]

    private let commandFailures: [(Error, String, String, Int32)] = [
        (MicrophoneCommandError.commandInProgress, "unknown", "command_in_progress", 6),
        (MicrophoneCommandError.lockUnavailable, "unknown", "command_lock_unavailable", 6),
        (MicrophoneCommandError.accessibilitySetupUnavailable, "unknown", "accessibility_setup_unavailable", 6),
        (MicrophoneCommandError.accessibilityCleanupFailed, "unknown", "accessibility_cleanup_failed", 6)
    ]

    func testReadErrorsMapToDocumentedStatusJSONAndExitCodesForEveryControl() throws {
        for (error, state, reason, code) in readFailures {
            for (media, key, control) in [("mic", "microphone", "microphone-button"),
                                          ("camera", "camera", "video-button"),
                                          ("hand", "hand", "raisehands-button")] {
                let stub = CLIStub()
                stub.error = error
                let result = stub.run([media, "status", "--json"])
                XCTAssertEqual(result.code, code)
                try assertCLIJSON(result, equals: [key: state, "reason": reason, "windows": [], "excluded_windows": []])
                XCTAssertEqual(stub.calls, ["read:\(control)"])
            }
        }
    }

    func testErrorsBeforeActionResultsMapToFailureMetadataWithoutRetrying() throws {
        for (error, state, reason, code) in readFailures + commandFailures {
            for route in cliActionRoutes {
                let stub = CLIStub()
                stub.error = error
                let result = stub.run(route.arguments + ["--json"])
                XCTAssertEqual(result.code, code)
                let key = route.arguments[0] == "mic" ? "microphone" : route.arguments[0]
                try assertCLIJSON(result, equals: [key: state, "reason": reason, "windows": [], "excluded_windows": [],
                                                  "action": route.arguments[1], "changed": false,
                                                  "action_attempted": false, "success": false])
                XCTAssertEqual(stub.calls, [route.handler])
            }
        }
    }

    func testPermissionDeniedTextAddsSetupGuidanceOnlyOnStderr() {
        for arguments in [["mic", "status"], ["camera", "on"], ["hand", "toggle"], ["call", "end"]] {
            let stub = CLIStub()
            stub.error = TeamsReadError.accessibilityDenied
            let result = stub.run(arguments)
            XCTAssertEqual(result.code, 3)
            XCTAssertEqual(result.stdout, "permission_denied\n")
            XCTAssertEqual(result.stderr, "Reason: accessibility_permission_required\n" +
                           "Enable Accessibility for the terminal or launcher running this command in System Settings > " +
                           "Privacy & Security > Accessibility, then retry. See README.md for setup.\n")
        }
    }

    func testOtherErrorsEmitOnlyStateAndReasonInTextMode() {
        for (error, state, reason, code) in Array(readFailures.dropFirst()) + commandFailures {
            let stub = CLIStub()
            stub.error = error
            let result = stub.run(["mic", "toggle"])
            XCTAssertEqual(result.code, code)
            XCTAssertEqual(result.stdout, state + "\n")
            XCTAssertEqual(result.stderr, "Reason: \(reason)\n")
        }
    }
}
