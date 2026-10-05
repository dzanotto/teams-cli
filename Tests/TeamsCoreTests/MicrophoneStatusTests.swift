import XCTest
@testable import TeamsCore

final class MicrophoneStatusTests: XCTestCase {
    func testActionLabelsDescribeTheOppositeOfCurrentState() {
        XCTAssertEqual(assess(call(1, "Mute mic")).state, .unmuted)
        XCTAssertEqual(assess(call(1, "Unmute mic")).state, .muted)
        XCTAssertNil(assess(call(1, "Unmute mic")).reason)
    }

    func testItalianLabelsAndKeyboardShortcutSuffixes() {
        for label in ["Disattiva microfono", "Mute mic (⇧⌘M)", "Mute mic (Command+Shift+M)"] {
            XCTAssertEqual(assess(call(1, label)).state, .unmuted, label)
        }
        for label in ["Attiva microfono", "Unmute mic (Ctrl + Shift + M)", "Attiva microfono (Comando+Maiusc+M)"] {
            XCTAssertEqual(assess(call(1, label)).state, .muted, label)
        }
    }

    func testPrejoinMicrophoneDoesNotEstablishCallStatus() {
        let prejoin = WindowSnapshot(index: 1, controls: [microphone("Unmute mic")])
        let result = assess(prejoin)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "no_call_controls")
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testHangupMustBeInTheSameWindow() {
        let result = MicrophoneClassifier.assess([
            WindowSnapshot(index: 1, controls: [microphone("Unmute mic")]),
            WindowSnapshot(index: 2, controls: [hangup]),
        ], complete: true)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "microphone_control_missing")
        XCTAssertEqual(result.windows, [WindowMicrophoneStatus(window: 2, state: .unknown)])
    }

    func testParticipantLabelsAndSimilarIdentifiersAreIgnored() {
        let participants = [
            ControlSnapshot(role: "AXButton", identifier: "participant-microphone-button", label: "Unmute mic"),
            ControlSnapshot(role: "AXStaticText", identifier: "microphone-button", label: "Unmute mic"),
            ControlSnapshot(role: "AXButton", identifier: "participant-42", label: "Mute mic"),
        ]
        let result = assess(WindowSnapshot(index: 3, controls: [hangup] + participants))
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "microphone_control_missing")
    }

    func testHangupRequiresAnExactButtonIdentifierAndRole() {
        for fake in [
            ControlSnapshot(role: "AXButton", identifier: "hangup-button-extra", label: "Leave"),
            ControlSnapshot(role: "AXStaticText", identifier: "hangup-button", label: "Leave"),
        ] {
            XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [fake, microphone("Mute mic")])).reason,
                           "no_call_controls")
        }
    }

    func testMultipleCallWindowsAreAmbiguousEvenWhenStatesAgree() {
        let result = MicrophoneClassifier.assess([call(4, "Mute mic"), call(8, "Mute mic")], complete: true)
        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertEqual(result.reason, "multiple_call_windows")
        XCTAssertEqual(result.windows, [
            WindowMicrophoneStatus(window: 4, state: .unmuted),
            WindowMicrophoneStatus(window: 8, state: .unmuted),
        ])
    }

    func testConflictingMicrophonesInOneWindowAreAmbiguous() {
        let result = assess(WindowSnapshot(index: 1, controls: [hangup, microphone("Mute mic"), microphone("Unmute mic")]))
        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertEqual(result.reason, "conflicting_microphone_controls")
    }

    func testDuplicateControlsWithTheSameStateRemainDefinitive() {
        XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup, microphone("Mute mic"), microphone("Mute mic")])).state,
                       .unmuted)
    }

    func testUnknownLabelsCannotBeGuessedFromPartialText() {
        for label in ["", "Microphone muted", "Unmute mic for Alice", "Mute mic (for everyone)", "Mute mic (M)"] {
            let result = assess(call(1, label))
            XCTAssertEqual(result.state, .unknown, label)
            XCTAssertEqual(result.reason, "unrecognized_microphone_label", label)
        }
        let mixed = WindowSnapshot(index: 1, controls: [hangup, microphone("Mute mic"), microphone("Microphone")])
        XCTAssertEqual(assess(mixed).state, .unknown)
    }

    func testIncompleteInspectionCannotReportARecognizedState() {
        for windows in [[call(1, "Mute mic")], [call(1, "Mute mic"), call(2, "Unmute mic")], []] {
            let result = MicrophoneClassifier.assess(windows, complete: false)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.reason, "inspection_incomplete")
        }
    }

    func testMissingCallControlsDoNotClaimThatThereIsNoCall() {
        let result = MicrophoneClassifier.assess([], complete: true)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "no_call_controls")
    }

    func testHeldCallIsExcludedAndActiveWindowIndexIsPreserved() {
        let result = MicrophoneClassifier.assess([heldCall(2), call(3, "Mute mic")], complete: true)
        XCTAssertEqual(result.state, .unmuted)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.windows, [WindowMicrophoneStatus(window: 3, state: .unmuted)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testAllHeldCallsReportUnknownWithAnExplicitReason() {
        let result = MicrophoneClassifier.assess([heldCall(4), heldCall(8)], complete: true)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "all_calls_on_hold")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.excludedWindows, [
            ExcludedWindow(window: 4, reason: "on_hold"),
            ExcludedWindow(window: 8, reason: "on_hold"),
        ])
    }

    func testExplicitlySelectedHeldWindowDoesNotReportItsMicrophoneState() {
        let result = assess(heldCall(8))
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "all_calls_on_hold")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 8, reason: "on_hold")])
    }

    func testHeldCallDetectionUsesIdentifierInsteadOfLocalizedLabel() {
        let resume = ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Riprendi")
        let result = assess(WindowSnapshot(index: 5, controls: [hangup, resume]))
        XCTAssertEqual(result.reason, "all_calls_on_hold")
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 5, reason: "on_hold")])
    }

    func testResumeRequiresAnExactButtonIdentifierAndRole() {
        for unrelated in [
            ControlSnapshot(role: "AXButton", identifier: "resume-button-extra", label: "Resume"),
            ControlSnapshot(role: "AXStaticText", identifier: "resume-button", label: "Resume"),
            ControlSnapshot(role: "AXButton", identifier: "resume-recording", label: "Resume"),
            ControlSnapshot(role: "AXStaticText", identifier: "participant-status", label: "On hold"),
        ] {
            let result = assess(WindowSnapshot(index: 1, controls: [hangup, microphone("Mute mic"), unrelated]))
            XCTAssertEqual(result.state, .unmuted, unrelated.identifier)
            XCTAssertTrue(result.excludedWindows.isEmpty, unrelated.identifier)
        }
    }

    func testResumeWithoutHangupDoesNotEstablishAHeldCall() {
        let unrelated = WindowSnapshot(index: 1, controls: [resume, microphone("Unmute mic")])
        let result = assess(unrelated)
        XCTAssertEqual(result.reason, "no_call_controls")
        XCTAssertTrue(result.excludedWindows.isEmpty)

        let withCall = MicrophoneClassifier.assess([unrelated, call(6, "Mute mic")], complete: true)
        XCTAssertEqual(withCall.state, .unmuted)
        XCTAssertEqual(withCall.windows, [WindowMicrophoneStatus(window: 6, state: .unmuted)])
        XCTAssertTrue(withCall.excludedWindows.isEmpty)
    }

    func testHeldCallsDoNotResolveAmbiguityBetweenOtherCallWindows() {
        let result = MicrophoneClassifier.assess([heldCall(2), call(3, "Mute mic"), call(7, "Unmute mic")], complete: true)
        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertEqual(result.reason, "multiple_call_windows")
        XCTAssertEqual(result.windows.map(\.window), [3, 7])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testIncompleteInspectionTakesPrecedenceOverHeldCallExclusion() {
        for windows in [[heldCall(2)], [heldCall(2), call(3, "Mute mic")]] {
            let result = MicrophoneClassifier.assess(windows, complete: false)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.reason, "inspection_incomplete")
            XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
        }
    }

    private var hangup: ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave")
    }

    private var resume: ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")
    }

    private func heldCall(_ index: Int) -> WindowSnapshot {
        WindowSnapshot(index: index, controls: [hangup, microphone("Unmute mic"), resume])
    }

    private func microphone(_ label: String) -> ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "microphone-button", label: label)
    }

    private func call(_ index: Int, _ label: String) -> WindowSnapshot {
        WindowSnapshot(index: index, controls: [hangup, microphone(label)])
    }

    private func assess(_ window: WindowSnapshot) -> MicrophoneAssessment {
        MicrophoneClassifier.assess([window], complete: true)
    }
}
