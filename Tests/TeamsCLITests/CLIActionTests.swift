import XCTest
@testable import TeamsCore

final class CLIActionTests: XCTestCase {
    func testEveryActionDispatchesExactlyOneCorrectHandlerWithoutAStatusRead() throws {
        for route in cliActionRoutes {
            let stub = CLIStub()
            let result = stub.run(route.arguments + ["--json"])
            XCTAssertEqual(stub.calls, [route.handler])
            XCTAssertEqual(result.code, 0)
            let key = route.arguments[0] == "mic" ? "microphone" : route.arguments[0]
            let state = ["mic": "muted", "camera": "off", "hand": "raised", "call": "ended"][route.arguments[0]]!
            try assertCLIJSON(result, equals: [key: state, "action": route.arguments[1], "changed": true,
                                              "action_attempted": true, "success": true, "focus_unchanged": true,
                                              "windows": [], "excluded_windows": []])
        }
    }

    func testSuccessfulActionJSONPreservesAllResultFieldsForEveryControl() throws {
        for (media, action, key, state) in [("mic", "unmute", "microphone", "unmuted"),
                                           ("camera", "on", "camera", "on"),
                                           ("hand", "lower", "hand", "lowered"),
                                           ("call", "end", "call", "ended")] {
            let stub = CLIStub()
            stub.useActionResults(success: true, changed: true, attempted: true, focus: true)
            let result = stub.run([media, action, "--json"])
            XCTAssertEqual(result.code, 0)
            try assertCLIJSON(result, equals: [key: state, "action": action, "changed": true,
                                              "action_attempted": true, "success": true, "focus_unchanged": true,
                                              "windows": [["window": 7, "state": state]],
                                              "excluded_windows": [["window": 12, "reason": "on_hold"]]])
        }
    }

    func testSuccessfulNoOpsRetainFalseChangedAndAttemptedFlags() throws {
        for arguments in [["mic", "unmute"], ["camera", "on"], ["hand", "lower"]] {
            let stub = CLIStub()
            stub.useActionResults(success: true, changed: false, attempted: false, focus: true)
            let result = stub.run(arguments + ["--json"])
            XCTAssertEqual(result.code, 0)
            let json = try cliJSON(result)
            XCTAssertEqual(json["changed"] as? Bool, false)
            XCTAssertEqual(json["action_attempted"] as? Bool, false)
            XCTAssertEqual(json["success"] as? Bool, true)
            XCTAssertEqual(stub.calls.count, 1)
        }
    }

    func testRefusedActionsReturnSixWithoutClaimingAnAttemptOrChange() throws {
        for arguments in [["mic", "toggle"], ["camera", "toggle"], ["hand", "toggle"], ["call", "end"]] {
            let stub = CLIStub()
            stub.useActionResults(success: false, changed: false, attempted: false, focus: true,
                                  reason: "control_unavailable", unknown: true)
            let result = stub.run(arguments + ["--json"])
            XCTAssertEqual(result.code, 6)
            let json = try cliJSON(result)
            XCTAssertEqual(json[arguments[0] == "mic" ? "microphone" : arguments[0]] as? String, "unknown")
            XCTAssertEqual(json["reason"] as? String, "control_unavailable")
            XCTAssertEqual(json["changed"] as? Bool, false)
            XCTAssertEqual(json["action_attempted"] as? Bool, false)
            XCTAssertEqual(json["success"] as? Bool, false)
            XCTAssertEqual(stub.calls.count, 1)
        }
    }

    func testUncertainAttemptEncodesChangedAsNullAndRetainsPartialWindows() throws {
        for (media, key, windowState) in [("mic", "microphone", "unmuted"), ("camera", "camera", "on"),
                                         ("hand", "hand", "lowered"), ("call", "call", "active")] {
            let stub = CLIStub()
            stub.useActionResults(success: false, changed: nil, attempted: true, focus: nil,
                                  reason: "verification_timeout", unknown: true)
            let action = media == "call" ? "end" : "toggle"
            let result = stub.run([media, action, "--json"])
            XCTAssertEqual(result.code, 6)
            try assertCLIJSON(result, equals: [key: "unknown", "action": action, "changed": NSNull(),
                                              "action_attempted": true, "success": false,
                                              "reason": "verification_timeout",
                                              "windows": [["window": 7, "state": windowState]],
                                              "excluded_windows": [["window": 12, "reason": "on_hold"]]])
            XCTAssertEqual(stub.calls.count, 1)
        }
    }

    func testFailedActionReturnsSixEvenWhenReportedStateIsKnown() throws {
        let stub = CLIStub()
        stub.useActionResults(success: false, changed: true, attempted: true, focus: false, reason: "focus_changed")
        let result = stub.run(["mic", "unmute", "--json"])
        XCTAssertEqual(result.code, 6)
        let json = try cliJSON(result)
        XCTAssertEqual(json["microphone"] as? String, "unmuted")
        XCTAssertEqual(json["success"] as? Bool, false)
        XCTAssertEqual(json["focus_unchanged"] as? Bool, false)
        XCTAssertEqual(json["reason"] as? String, "focus_changed")
    }

    func testVerifiedCallEndAllowsReportedFocusChange() throws {
        let stub = CLIStub()
        stub.useActionResults(success: true, changed: true, attempted: true, focus: false)
        let result = stub.run(["call", "end", "--json"])
        XCTAssertEqual(result.code, 0)
        let json = try cliJSON(result)
        XCTAssertEqual(json["call"] as? String, "ended")
        XCTAssertEqual(json["focus_unchanged"] as? Bool, false)
        XCTAssertEqual(json["success"] as? Bool, true)
    }

    func testSuccessfulActionTextIsOneStatusWord() {
        for (arguments, state) in [(["mic", "mute"], "muted"), (["camera", "off"], "off"),
                                   (["hand", "raise"], "raised"), (["call", "end"], "ended")] {
            let result = CLIStub().run(arguments)
            XCTAssertEqual(result.code, 0)
            XCTAssertEqual(result.stdout, state + "\n")
            XCTAssertEqual(result.stderr, "")
        }
    }

    func testUncertainActionTextSeparatesFailureReason() {
        let stub = CLIStub()
        stub.useActionResults(success: false, changed: nil, attempted: true, focus: true,
                              reason: "verification_timeout", unknown: true)
        let result = stub.run(["hand", "toggle"])
        XCTAssertEqual(result.code, 6)
        XCTAssertEqual(result.stdout, "unknown\n")
        XCTAssertEqual(result.stderr, "Reason: verification_timeout\n")
        XCTAssertEqual(stub.calls, ["hand:toggle"])
    }

    func testAmbiguousCallEndTextListsWindowsWithoutStatusSelectionAdvice() {
        let stub = CLIStub()
        stub.call = CallEndResult(state: .ambiguous, reason: "multiple_call_windows", changed: false,
                                  actionAttempted: false, focusUnchanged: true,
                                  windows: [.init(window: 2, state: .active), .init(window: 5, state: .active)],
                                  excludedWindows: [], success: false)
        let result = stub.run(["call", "end"])
        XCTAssertEqual(result.code, 6)
        XCTAssertEqual(result.stdout, "ambiguous\n")
        XCTAssertEqual(result.stderr, "Reason: multiple_call_windows\nWindow 2: active\nWindow 5: active\n")
    }

    func testJSONEscapesReasonTextWithoutAddingDiagnosticsOrChangingItsValue() throws {
        let stub = CLIStub()
        let reason = "échec \"quoted\"\nsecond line\\path"
        stub.useActionResults(success: false, changed: false, attempted: false, focus: nil,
                              reason: reason, unknown: true)
        let result = stub.run(["camera", "toggle", "--json"])
        XCTAssertEqual(result.code, 6)
        XCTAssertEqual(try cliJSON(result)["reason"] as? String, reason)
    }
}
