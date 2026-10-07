import XCTest
@testable import TeamsCore

final class CLIStatusTests: XCTestCase {
    func testAllSixKnownStatesReturnZeroWithOneWordOnStdout() {
        for (media, window, state) in [
            ("mic", cliWindow(microphone: "Unmute mic"), "muted"),
            ("mic", cliWindow(microphone: "Mute mic"), "unmuted"),
            ("camera", cliWindow(camera: "Turn camera on"), "off"),
            ("camera", cliWindow(camera: "Turn camera off"), "on"),
            ("hand", cliWindow(raised: false), "lowered"),
            ("hand", cliWindow(raised: true), "raised")
        ] {
            let stub = CLIStub()
            stub.snapshot = TeamsSnapshot(windows: [window], complete: true, focusUnchanged: true)
            let result = stub.run([media, "status"])
            XCTAssertEqual(result.code, 0)
            XCTAssertEqual(result.stdout, state + "\n")
            XCTAssertEqual(result.stderr, "")
        }
    }

    func testStatusJSONUsesOnlyTheControlSpecificStateKeyAndStatusFields() throws {
        for (media, key, state) in [("mic", "microphone", "unmuted"), ("camera", "camera", "on"),
                                   ("hand", "hand", "lowered")] {
            let result = CLIStub().run([media, "status", "--json"])
            XCTAssertEqual(result.code, 0)
            try assertCLIJSON(result, equals: [key: state, "windows": [["window": 1, "state": state]],
                                              "excluded_windows": [], "focus_unchanged": true])
        }
    }

    func testJSONIsPrettyPrintedSortedAndTerminatedByOneNewline() throws {
        let result = CLIStub().run(["mic", "status", "--json"])
        XCTAssertTrue(result.stdout.hasPrefix("{\n"))
        XCTAssertTrue(result.stdout.hasSuffix("}\n"))
        let keys = ["excluded_windows", "focus_unchanged", "microphone", "windows"]
        let positions = try keys.map { key in
            try XCTUnwrap(result.stdout.range(of: "\"\(key)\"")).lowerBound
        }
        XCTAssertEqual(positions, positions.sorted())
    }

    func testFocusIsOmittedWhenUnknownAndPreservesFalseWithoutChangingStatusExitCode() throws {
        for focus: Bool? in [nil, false] {
            let stub = CLIStub()
            stub.snapshot = TeamsSnapshot(windows: [cliWindow()], complete: true, focusUnchanged: focus)
            let result = stub.run(["mic", "status", "--json"])
            let json = try cliJSON(result)
            XCTAssertEqual(result.code, 0)
            XCTAssertEqual(json["focus_unchanged"] as? Bool, focus)
            if focus == nil { XCTAssertNil(json["focus_unchanged"]) }
        }
    }

    func testUnknownStatusReturnsTwoAndSeparatesReasonFromStdout() {
        for media in ["mic", "camera", "hand"] {
            let stub = CLIStub()
            stub.snapshot = TeamsSnapshot(windows: [], complete: true, focusUnchanged: nil)
            let result = stub.run([media, "status"])
            XCTAssertEqual(result.code, 2)
            XCTAssertEqual(result.stdout, "unknown\n")
            XCTAssertEqual(result.stderr, "Reason: no_call_controls\n")
        }
    }

    func testAmbiguousTextListsWindowsAndSelectionGuidanceOnStderr() {
        for (media, state) in [("mic", "unmuted"), ("camera", "on"), ("hand", "lowered")] {
            let stub = CLIStub()
            stub.snapshot = TeamsSnapshot(windows: [cliWindow(4), cliWindow(9)], complete: true, focusUnchanged: true)
            let result = stub.run([media, "status"])
            XCTAssertEqual(result.code, 2)
            XCTAssertEqual(result.stdout, "ambiguous\n")
            XCTAssertEqual(result.stderr, "Reason: multiple_call_windows\nWindow 4: \(state)\nWindow 9: \(state)\n" +
                           "Use --window N to read one window. Indices can change when Teams windows open or close.\n")
        }
    }

    func testAmbiguousJSONPreservesPerWindowStatesAndEmitsNoTextDiagnostics() throws {
        let stub = CLIStub()
        stub.snapshot = TeamsSnapshot(windows: [cliWindow(3, microphone: "Unmute mic"), cliWindow(7)],
                                      complete: true, focusUnchanged: false)
        let result = stub.run(["mic", "status", "--json"])
        XCTAssertEqual(result.code, 2)
        try assertCLIJSON(result, equals: ["microphone": "ambiguous", "reason": "multiple_call_windows",
                                          "windows": [["window": 3, "state": "muted"], ["window": 7, "state": "unmuted"]],
                                          "excluded_windows": [], "focus_unchanged": false])
    }

    func testWindowSelectionUsesReportedIndexAndRetainsThatIndex() throws {
        for (media, key, state) in [("mic", "microphone", "unmuted"), ("camera", "camera", "on"),
                                   ("hand", "hand", "lowered")] {
            let stub = CLIStub()
            stub.snapshot = TeamsSnapshot(windows: [cliWindow(12), cliWindow(3)], complete: true, focusUnchanged: true)
            let result = stub.run([media, "status", "--window", "3", "--json"])
            XCTAssertEqual(result.code, 0)
            try assertCLIJSON(result, equals: [key: state, "windows": [["window": 3, "state": state]],
                                              "excluded_windows": [], "focus_unchanged": true])
        }
    }

    func testUnknownWindowReportsWindowNotFoundWithoutInventingObservations() throws {
        for selected in ["2", String(Int.max)] {
            let result = CLIStub().run(["mic", "status", "--window", selected, "--json"])
            XCTAssertEqual(result.code, 2)
            try assertCLIJSON(result, equals: ["microphone": "unknown", "reason": "window_not_found",
                                              "windows": [], "excluded_windows": [], "focus_unchanged": true])
        }
    }

    func testWindowNotFoundTextUsesNormalDiagnosticChannel() {
        let result = CLIStub().run(["hand", "status", "--window", "2"])
        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.stdout, "unknown\n")
        XCTAssertEqual(result.stderr, "Reason: window_not_found\n")
    }

    func testSelectingKnownWindowDoesNotOverrideIncompleteInspection() throws {
        let stub = CLIStub()
        stub.snapshot = TeamsSnapshot(windows: [cliWindow(8)], complete: false, focusUnchanged: true)
        let result = stub.run(["mic", "status", "--window", "8", "--json"])
        XCTAssertEqual(result.code, 2)
        try assertCLIJSON(result, equals: ["microphone": "unknown", "reason": "inspection_incomplete",
                                          "windows": [["window": 8, "state": "unmuted"]],
                                          "excluded_windows": [], "focus_unchanged": true])
    }

    func testHeldWindowsRemainExcludedWhenExplicitlySelected() throws {
        for (media, key) in [("mic", "microphone"), ("camera", "camera"), ("hand", "hand")] {
            let stub = CLIStub()
            stub.snapshot = TeamsSnapshot(windows: [cliWindow(), cliWindow(8, held: true)],
                                          complete: true, focusUnchanged: true)
            let result = stub.run([media, "status", "--window", "8", "--json"])
            XCTAssertEqual(result.code, 2)
            try assertCLIJSON(result, equals: [key: "unknown", "reason": "all_calls_on_hold", "windows": [],
                                              "excluded_windows": [["window": 8, "reason": "on_hold"]],
                                              "focus_unchanged": true])
        }
    }

    func testActiveStatusIncludesExcludedHeldWindows() throws {
        let stub = CLIStub()
        stub.snapshot = TeamsSnapshot(windows: [cliWindow(2, held: true), cliWindow(5)],
                                      complete: true, focusUnchanged: true)
        let result = stub.run(["camera", "status", "--json"])
        XCTAssertEqual(result.code, 0)
        try assertCLIJSON(result, equals: ["camera": "on", "windows": [["window": 5, "state": "on"]],
                                          "excluded_windows": [["window": 2, "reason": "on_hold"]],
                                          "focus_unchanged": true])
    }

    func testStatusJSONDoesNotExposeAccessibilityLabels() throws {
        let stub = CLIStub()
        let privateLabel = "Myself video, Private Participant, Video is off, Has context menu"
        stub.snapshot = TeamsSnapshot(windows: [WindowSnapshot(index: 1, controls: [
            ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave"),
            ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise your hand"),
            ControlSnapshot(role: "AXImage", identifier: "", label: privateLabel)
        ])], complete: true, focusUnchanged: true)
        let result = stub.run(["hand", "status", "--json"])
        XCTAssertEqual(try cliJSON(result)["hand"] as? String, "lowered")
        XCTAssertFalse(result.stdout.contains("Private Participant"))
        XCTAssertFalse(result.stdout.contains("Myself video"))
    }
}
