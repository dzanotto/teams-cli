import XCTest
@testable import TeamsCore

final class CameraStatusTests: XCTestCase {
    func testActionLabelsDescribeTheOppositeOfCurrentState() {
        let on = assess(call(1, "Turn camera off"))
        XCTAssertEqual(on.state, .on)
        XCTAssertNil(on.reason)

        let off = assess(call(2, "Turn camera on"))
        XCTAssertEqual(off.state, .off)
        XCTAssertNil(off.reason)
        XCTAssertEqual(off.windows, [WindowCameraStatus(window: 2, state: .off)])
    }

    func testItalianLabelsAndKeyboardShortcutSuffixes() {
        for label in ["Disattiva videocamera", "Turn camera off (⇧⌘O)", "Turn camera off (Command+Shift+O)"] {
            XCTAssertEqual(assess(call(1, label)).state, .on, label)
        }
        for label in ["Attiva videocamera", "Turn camera on (Ctrl + Shift + O)", "Attiva videocamera (Comando+Maiusc+O)"] {
            XCTAssertEqual(assess(call(1, label)).state, .off, label)
        }
    }

    func testCaseAndWhitespaceAreNormalized() {
        XCTAssertEqual(assess(call(1, "  TURN\n CAMERA\tOFF  ")).state, .on)
    }

    func testMicrophoneStateDoesNotDetermineCameraState() {
        for microphoneLabel in ["Mute mic", "Unmute mic"] {
            let microphone = ControlSnapshot(role: "AXButton", identifier: "microphone-button", label: microphoneLabel)
            XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup, microphone, camera("Turn camera on")])).state,
                           .off)
            XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup, microphone, camera("Turn camera off")])).state,
                           .on)
            XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup, microphone])).reason,
                           "camera_control_missing")
        }
    }

    func testPrejoinCameraDoesNotEstablishCallStatus() {
        let result = assess(WindowSnapshot(index: 1, controls: [camera("Turn camera on")]))
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "no_call_controls")
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testHangupMustBeInTheSameWindow() {
        let result = CameraClassifier.assess([
            WindowSnapshot(index: 1, controls: [camera("Turn camera off")]),
            WindowSnapshot(index: 2, controls: [hangup]),
        ], complete: true)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "camera_control_missing")
        XCTAssertEqual(result.windows, [WindowCameraStatus(window: 2, state: .unknown)])
    }

    func testParticipantControlsAndSimilarIdentifiersAreIgnored() {
        let unrelated = [
            ControlSnapshot(role: "AXButton", identifier: "participant-video-button", label: "Turn camera on"),
            ControlSnapshot(role: "AXStaticText", identifier: "video-button", label: "Turn camera on"),
            ControlSnapshot(role: "AXButton", identifier: "video-button-extra", label: "Turn camera off"),
            ControlSnapshot(role: "AXButton", identifier: "camera-button", label: "Turn camera on"),
        ]
        let result = assess(WindowSnapshot(index: 3, controls: [hangup] + unrelated))
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "camera_control_missing")
    }

    func testHangupRequiresAnExactButtonIdentifierAndRole() {
        for fake in [
            ControlSnapshot(role: "AXButton", identifier: "hangup-button-extra", label: "Leave"),
            ControlSnapshot(role: "AXStaticText", identifier: "hangup-button", label: "Leave"),
        ] {
            let result = assess(WindowSnapshot(index: 1, controls: [fake, camera("Turn camera off")]))
            XCTAssertEqual(result.reason, "no_call_controls")
        }
    }

    func testHeldCallIsExcludedAndActiveWindowIndexIsPreserved() {
        let result = CameraClassifier.assess([heldCall(2), call(5, "Turn camera off")], complete: true)
        XCTAssertEqual(result.state, .on)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.windows, [WindowCameraStatus(window: 5, state: .on)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testAllHeldCallsReportUnknownWithoutCameraStates() {
        let result = CameraClassifier.assess([heldCall(4), heldCall(8)], complete: true)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "all_calls_on_hold")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.excludedWindows, [
            ExcludedWindow(window: 4, reason: "on_hold"),
            ExcludedWindow(window: 8, reason: "on_hold"),
        ])
    }

    func testIncompleteInspectionKeepsWindowStatesButOverallStateIsUnknown() {
        let result = CameraClassifier.assess([heldCall(2), call(5, "Turn camera off")], complete: false)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "inspection_incomplete")
        XCTAssertEqual(result.windows, [WindowCameraStatus(window: 5, state: .on)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testIncompleteInspectionTakesPrecedenceOverOtherSelectionFailures() {
        for windows in [[], [heldCall(2)], [call(1, "Turn camera off"), call(2, "Turn camera on")]] {
            let result = CameraClassifier.assess(windows, complete: false)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.reason, "inspection_incomplete")
        }
    }

    func testMultipleActiveCallWindowsAreAmbiguousEvenWhenStatesAgree() {
        let result = CameraClassifier.assess([heldCall(2), call(4, "Turn camera off"), call(8, "Turn camera off")], complete: true)
        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertEqual(result.reason, "multiple_call_windows")
        XCTAssertEqual(result.windows, [
            WindowCameraStatus(window: 4, state: .on),
            WindowCameraStatus(window: 8, state: .on),
        ])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testConflictingCameraControlsInOneWindowAreAmbiguous() {
        let result = assess(WindowSnapshot(index: 1, controls: [hangup, camera("Turn camera off"), camera("Turn camera on")]))
        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertEqual(result.reason, "conflicting_camera_controls")
    }

    func testDuplicateControlsWithTheSameStateRemainDefinitive() {
        let result = assess(WindowSnapshot(index: 1, controls: [hangup, camera("Turn camera off"), camera("Turn camera off")]))
        XCTAssertEqual(result.state, .on)
        XCTAssertNil(result.reason)
    }

    func testUnknownLabelsCannotBeGuessedFromPartialText() {
        for label in ["", "Camera off", "Turn camera on for Alice", "Turn camera off (for everyone)", "Turn camera on (O)"] {
            let result = assess(call(1, label))
            XCTAssertEqual(result.state, .unknown, label)
            XCTAssertEqual(result.reason, "unrecognized_camera_label", label)
        }
        let mixed = WindowSnapshot(index: 1, controls: [hangup, camera("Turn camera off"), camera("Camera")])
        XCTAssertEqual(assess(mixed).state, .unknown)
        XCTAssertEqual(assess(mixed).reason, "unrecognized_camera_label")
    }

    private var hangup: ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave")
    }

    private func heldCall(_ index: Int) -> WindowSnapshot {
        let resume = ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")
        return WindowSnapshot(index: index, controls: [hangup, camera("Turn camera on"), resume])
    }

    private func camera(_ label: String) -> ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "video-button", label: label)
    }

    private func call(_ index: Int, _ label: String) -> WindowSnapshot {
        WindowSnapshot(index: index, controls: [hangup, camera(label)])
    }

    private func assess(_ window: WindowSnapshot) -> CameraAssessment {
        CameraClassifier.assess([window], complete: true)
    }
}
