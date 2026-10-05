import XCTest
@testable import TeamsCore

final class HandStatusTests: XCTestCase {
    func testOwnVideoReportsBothStatesWithStaleButtonDescriptions() {
        for state in [HandState.raised, .lowered] {
            let stale = state == .raised ? "Raise your hand" : "Lower your hand"
            let result = assess([hangup, hand(stale), ownVideo(state)])
            XCTAssertEqual(result.state, state)
            XCTAssertNil(result.reason)
            XCTAssertEqual(result.windows, [WindowHandStatus(window: 1, state: state)])
        }
    }

    func testButtonDescriptionsNeverSupplyStateWithoutOwnVideo() {
        for label in ["Raise", "Lower your hand", "Raise your hand", "Alza la mano", "Abbassa la mano"] {
            let button = ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: label,
                                         detailLabels: ["Lower your hand"])
            XCTAssertEqual(assess([hangup, button]).state, .unknown)
            XCTAssertEqual(assess([hangup, button]).reason, "own_video_missing")
        }
    }

    func testConflictingButtonTooltipsCannotOverrideOwnVideo() {
        XCTAssertEqual(assess([hangup, ownVideo(.raised), hand("Raise your hand"), hand("Lower your hand")]).state, .raised)
    }

    func testOtherParticipantsAndWrongRolesDoNotEstablishOwnState() {
        for control in [
            ControlSnapshot(role: "AXImage", identifier: "", label: "Someone video, Test, video is on, Hand raised position 1, Has context menu"),
            ControlSnapshot(role: "AXStaticText", identifier: "", label: ownVideo(.raised).label),
            ControlSnapshot(role: "AXButton", identifier: "", label: ownVideo(.raised).label),
        ] {
            XCTAssertEqual(assess([hangup, hand("Raise"), control]).reason, "own_video_missing")
        }
    }

    func testParticipantNameCannotSupplyHandMarker() {
        XCTAssertEqual(state("Myself video, Hand raised position 1, Example, Unmuted, video is on, Fill frame, Has context menu"), .lowered)
    }

    func testOwnVideoRequiresRecognizedCompleteDescription() {
        for label in ["Myself video", "Myself video, Example", "Myself video, Example, Hand raised position 1",
                      "Myself video, Example, video is on", "Myself video, Example, Has context menu",
                      "Myself video, Example, video is on, Hand raised position 1, Has context menu, truncated",
                      "Myself video, Example, video is loading, Has context menu"] {
            let result = assess([hangup, hand("Raise"), ControlSnapshot(role: "AXImage", identifier: "", label: label)])
            XCTAssertEqual(result.state, .unknown, label)
            XCTAssertEqual(result.reason, "unrecognized_own_video_label", label)
        }
    }

    func testUnknownHandMarkersCannotBeAssumedLowered() {
        for marker in ["Hand raised", "Hand raised position 0", "Hand raised position -1", "Hand raised position one",
                       "Hand lowered", "Hand status unavailable", "Hand raised position 1 extra",
                       "Hand raised position 1, Hand raised position 2"] {
            XCTAssertNil(state("Myself video, Example, video is on, \(marker), Has context menu"))
        }
    }

    func testRaisedPositionsAreNotLimitedToFirstInQueue() {
        for position in [1, 2, 15, 250] {
            XCTAssertEqual(state("Myself video, Example, video is on, Hand raised position \(position), Has context menu"), .raised)
        }
    }

    func testCaseWhitespaceAndVideoOffDoNotChangeHandState() {
        XCTAssertEqual(state(" MYSELF VIDEO , Example , MUTED , VIDEO IS OFF , Fill frame , HAND  RAISED POSITION 2 , HAS CONTEXT MENU "), .raised)
        XCTAssertEqual(state("Myself video, Example, Muted, video is off, Fill frame, Has context menu"), .lowered)
    }

    func testMultipleOwnVideosAreAmbiguousEvenWhenStatesAgree() {
        for state in [HandState.raised, .lowered] {
            let result = assess([hangup, hand("Raise"), ownVideo(.raised), ownVideo(state)])
            XCTAssertEqual(result.state, .ambiguous)
            XCTAssertEqual(result.reason, "multiple_own_videos")
        }
    }

    func testExactHandButtonStillRequired() {
        for control in [ControlSnapshot(role: "AXButton", identifier: "participant-raisehands-button", label: "Raise"),
                        ControlSnapshot(role: "AXStaticText", identifier: "raisehands-button", label: "Raise")] {
            XCTAssertEqual(assess([hangup, control, ownVideo(.raised)]).reason, "hand_control_missing")
        }
    }

    func testExactHangupMustBeInSameWindow() {
        for controls in [[hand("Raise"), ownVideo(.raised)],
                         [hand("Raise"), ownVideo(.raised), ControlSnapshot(role: "AXStaticText", identifier: "hangup-button", label: "Leave")]] {
            XCTAssertEqual(assess(controls).reason, "no_call_controls")
        }
        let result = HandClassifier.assess([WindowSnapshot(index: 1, controls: [ownVideo(.raised)]),
                                           WindowSnapshot(index: 2, controls: [hangup, hand("Raise")])], complete: true)
        XCTAssertEqual(result.reason, "own_video_missing")
    }

    func testHeldCallsAreExcludedAndIndicesPreserved() {
        let result = HandClassifier.assess([call(2, .lowered, held: true), call(5, .raised)], complete: true)
        XCTAssertEqual(result.state, .raised)
        XCTAssertEqual(result.windows, [WindowHandStatus(window: 5, state: .raised)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testAllHeldIncludingExplicitlySelectedWindowIsUnknown() {
        for windows in [[call(2, .raised, held: true)], [call(2, .raised, held: true), call(3, .lowered, held: true)]] {
            let result = HandClassifier.assess(windows, complete: true)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.reason, "all_calls_on_hold")
            XCTAssertTrue(result.windows.isEmpty)
        }
    }

    func testIncompleteScanCannotConfirmRecognizedIndicator() {
        let result = HandClassifier.assess([call(2, .lowered, held: true), call(5, .raised)], complete: false)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "inspection_incomplete")
        XCTAssertEqual(result.windows, [WindowHandStatus(window: 5, state: .raised)])
    }

    func testMultipleActiveCallsRemainAmbiguous() {
        for state in [HandState.raised, .lowered] {
            let result = HandClassifier.assess([call(1, .raised), call(2, state)], complete: true)
            XCTAssertEqual(result.state, .ambiguous)
            XCTAssertEqual(result.reason, "multiple_call_windows")
        }
    }

    func testMissingOwnVideoNeverMeansLowered() {
        XCTAssertEqual(assess([hangup, hand("Raise your hand")]).state, .unknown)
    }

    func testLegacySnapshotDecodingRemainsCompatible() throws {
        let data = Data(#"{"role":"AXButton","identifier":"raisehands-button","label":"Raise","detailLabels":["Lower your hand"]}"#.utf8)
        let control = try JSONDecoder().decode(ControlSnapshot.self, from: data)
        XCTAssertEqual(control.detailLabels, ["Lower your hand"])
        XCTAssertEqual(assess([hangup, control]).state, .unknown)
    }

    private var hangup: ControlSnapshot { ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave") }
    private func hand(_ description: String) -> ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise", detailLabels: [description])
    }
    private func ownVideo(_ state: HandState) -> ControlSnapshot {
        ControlSnapshot(role: "AXImage", identifier: "", label: "Myself video, Example, Unmuted, video is on, Fill frame" +
            (state == .raised ? ", Hand raised position 1" : "") + ", Has context menu")
    }
    private func call(_ index: Int, _ state: HandState, held: Bool = false) -> WindowSnapshot {
        var controls = [hangup, hand("Raise"), ownVideo(state)]
        if held { controls.append(ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")) }
        return WindowSnapshot(index: index, controls: controls)
    }
    private func assess(_ controls: [ControlSnapshot]) -> HandAssessment {
        HandClassifier.assess([WindowSnapshot(index: 1, controls: controls)], complete: true)
    }
    private func state(_ label: String) -> HandState? { OwnVideoHandIndicator.state(for: label) }
}
