import XCTest
@testable import TeamsCore

final class HandControllerTests: XCTestCase {
    func testRaiseAndLowerPressOnceAndConfirmTwoSamples() throws {
        for target in [HandTarget.raised, .lowered] {
            let initial: HandState = target == .raised ? .lowered : .raised
            let backend = FakeHandBackend([
                observed(initial), observed(initial), observed(target.state), observed(target.state),
            ])
            let result = try HandController(backend: backend).set(target)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target.state)
            XCTAssertEqual(result.changed, true)
            XCTAssertTrue(result.actionAttempted)
            XCTAssertEqual(result.focusUnchanged, true)
            XCTAssertNil(result.reason)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.presses.first?.targetID, "call-a")
            XCTAssertEqual(backend.presses.first?.expectedState, initial)
            XCTAssertEqual(backend.sampleCount, 4)
            XCTAssertEqual(backend.waitCount, 2)
        }
    }

    func testAlreadyRequestedStateIsANoOpEvenWhenDisabled() throws {
        for target in [HandTarget.raised, .lowered] {
            let backend = FakeHandBackend([observed(target.state, canPress: false)])
            let result = try HandController(backend: backend).set(target)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target.state)
            XCTAssertEqual(result.changed, false)
            XCTAssertFalse(result.actionAttempted)
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testRepeatedRaiseOrLowerDoesNotToggleBack() throws {
        for target in [HandTarget.raised, .lowered] {
            let initial: HandState = target == .raised ? .lowered : .raised
            let backend = FakeHandBackend([
                observed(initial), observed(initial), observed(target.state), observed(target.state),
            ])
            let controller = HandController(backend: backend)
            XCTAssertEqual(try controller.set(target).changed, true)
            let repeated = try controller.set(target)
            XCTAssertTrue(repeated.success)
            XCTAssertEqual(repeated.changed, false)
            XCTAssertFalse(repeated.actionAttempted)
            XCTAssertEqual(backend.presses.count, 1)
        }
    }

    func testConcurrentChangeToDesiredStateIsNotUndone() throws {
        for target in [HandTarget.raised, .lowered] {
            let initial: HandState = target == .raised ? .lowered : .raised
            let backend = FakeHandBackend([observed(initial), observed(target.state, canPress: false)])
            let result = try HandController(backend: backend).set(target)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.changed, false)
            XCTAssertFalse(result.actionAttempted)
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testUnavailableSelectionsAreRefusedInitiallyAndBeforePress() throws {
        let cases: [(HandObservation, String)] = [
            (classified([]), "no_call_controls"),
            (classified([call(1, .lowered), call(2, .lowered)]), "multiple_call_windows"),
            (classified([call(1, .lowered, held: true)]), "all_calls_on_hold"),
            (classified([call(1, .lowered)], complete: false), "inspection_incomplete"),
            (classified([call(1, .unknown)]), "unrecognized_own_video_label"),
            (classified([WindowSnapshot(index: 1, controls: [hangup])]), "hand_control_missing"),
            (classified([WindowSnapshot(index: 1, controls: [hangup,
                ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise your hand")])]), "own_video_missing"),
            (observed(.ambiguous), "hand_state_unavailable"),
        ]
        for (invalid, reason) in cases {
            for observations in [[invalid], [observed(.lowered), invalid]] {
                let backend = FakeHandBackend(observations)
                assertNotAttempted(try HandController(backend: backend).set(.raised), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty, reason)
            }
        }
    }

    func testHeldCallsAreExcludedAndWindowReorderingKeepsTheStableTarget() throws {
        let backend = FakeHandBackend([
            classified([call(1, .raised, held: true), call(2, .lowered)]),
            classified([call(1, .raised, held: true), call(3, .lowered)]),
            classified([call(1, .raised, held: true), call(3, .raised)]),
            classified([call(1, .raised, held: true), call(3, .raised)]),
        ])
        let result = try HandController(backend: backend).set(.raised)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.windows, [WindowHandStatus(window: 3, state: .raised)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testMissingIdentityAndDisabledControlCannotDispatch() throws {
        for observations in [
            [observed(.lowered, id: nil)],
            [observed(.raised, id: nil)],
            [observed(.lowered, canPress: false)],
            [observed(.lowered), observed(.lowered, canPress: false)],
        ] {
            let backend = FakeHandBackend(observations)
            assertNotAttempted(try HandController(backend: backend).set(.raised), reason: "control_unavailable")
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testReplacementCallCannotReceiveOrConfirmTheAction() throws {
        let before = FakeHandBackend([observed(.lowered), observed(.raised, id: "call-b")])
        assertNotAttempted(try HandController(backend: before).set(.raised), reason: "target_changed")
        XCTAssertTrue(before.presses.isEmpty)
        let after = FakeHandBackend([observed(.lowered), observed(.lowered), observed(.raised, id: "call-b")])
        assertUncertain(try HandController(backend: after).set(.raised), reason: "target_changed")
        XCTAssertEqual(after.presses.count, 1)
    }

    func testFocusMustBePreservedBeforeAndAfterPress() throws {
        let failures: [Bool?] = [false, nil]
        for badFocus in failures {
            let reason = badFocus == nil ? "focus_unavailable" : "focus_changed"
            for focus in [[badFocus], [true, badFocus]] {
                let backend = FakeHandBackend([observed(.lowered)], focusValues: focus)
                assertNotAttempted(try HandController(backend: backend).set(.raised), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty)
            }
            for focus in [[true, true, badFocus], [true, true, true, badFocus]] {
                let backend = FakeHandBackend([
                    observed(.lowered), observed(.lowered), observed(.raised), observed(.raised),
                ], focusValues: focus)
                assertUncertain(try HandController(backend: backend).set(.raised), reason: reason)
                XCTAssertEqual(backend.presses.count, 1)
            }
            let noOp = FakeHandBackend([observed(.raised)], focusValues: [badFocus])
            assertNotAttempted(try HandController(backend: noOp).set(.raised), reason: reason)
        }
    }

    func testCallBecomingHeldAfterPressLeavesOutcomeUncertain() throws {
        let backend = FakeHandBackend([
            observed(.lowered), observed(.lowered), classified([call(1, .raised, held: true)]),
        ])
        let result = try HandController(backend: backend).set(.raised)
        assertUncertain(result, reason: "all_calls_on_hold")
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testVerificationRequiresConsecutiveMatchesWithoutAnotherPress() throws {
        let backend = FakeHandBackend([
            observed(.lowered), observed(.lowered), observed(.raised), observed(.lowered),
            observed(.raised), observed(.raised),
        ])
        XCTAssertTrue(try HandController(backend: backend).set(.raised).success)
        XCTAssertEqual(backend.waitCount, 4)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testTimeoutAndOneMatchingSampleDoNotRetry() throws {
        for observations in [[observed(.lowered)],
                             Array(repeating: observed(.lowered), count: 9) + [observed(.raised)]] {
            let backend = FakeHandBackend(observations)
            assertUncertain(try HandController(backend: backend).set(.raised), reason: "verification_timeout")
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.waitCount, 8)
        }
    }

    func testReadFailuresNeverCauseAnAdditionalPress() throws {
        for index in [0, 1, 2] {
            let backend = FakeHandBackend([observed(.lowered)])
            backend.sampleErrorAt = index
            if index < 2 {
                XCTAssertThrowsError(try HandController(backend: backend).set(.raised))
                XCTAssertTrue(backend.presses.isEmpty)
            } else {
                assertUncertain(try HandController(backend: backend).set(.raised), reason: "action_outcome_unknown")
                XCTAssertEqual(backend.presses.count, 1)
            }
        }
    }

    func testPressFailureIsUncertainAndNeverRetried() throws {
        let backend = FakeHandBackend([observed(.lowered)])
        backend.throwOnPress = true
        assertUncertain(try HandController(backend: backend).set(.raised), reason: "action_outcome_unknown")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.waitCount, 0)
    }

    func testLastMomentRejectionReportsNoActionAndDoesNotRetry() throws {
        for reason in ["hand_state_changed", "target_changed", "preflight_failed", "control_unavailable",
                       "focus_changed", "focus_unavailable"] {
            let backend = FakeHandBackend([observed(.lowered)])
            backend.rejectionReason = reason
            assertNotAttempted(try HandController(backend: backend).set(.raised), reason: reason)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.waitCount, 0)
        }
    }

    func testPreDispatchSnapshotReadsOwnVideoForBothStatesWithoutReadingTooltip() {
        let buttonAttributes = ["AXRole": "AXButton", "AXDOMIdentifier": "raisehands-button", "AXDescription": "Raise"]
        let button = MediaButtonSnapshot.read(control: .hand) {
            XCTAssertNotEqual($0, "AXCustomContent")
            return buttonAttributes[$0]
        }
        for state in [HandState.raised, .lowered] {
            let attributes = ["AXRole": "AXImage", "AXDescription": ownVideo(state).label]
            let indicator = OwnVideoHandIndicator.read { attributes[$0] }
            XCTAssertEqual(HandClassifier.assess([WindowSnapshot(index: 1, controls: [hangup, button, indicator])],
                                                complete: true).state, state)
        }
    }

    func testPreDispatchSnapshotRejectsMissingOrChangedOwnIndicator() {
        for attributes in [[:], ["AXRole": "AXStaticText", "AXDescription": ownVideo(.raised).label],
                           ["AXRole": "AXImage", "AXDescription": "Participant video, Example, Hand raised position 1"]] {
            let indicator = OwnVideoHandIndicator.read { attributes[$0] }
            let button = ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Lower your hand")
            XCTAssertEqual(HandClassifier.assess([WindowSnapshot(index: 1, controls: [hangup, button, indicator])],
                                                complete: true).state, .unknown)
        }
    }

    func testPreDispatchSnapshotRejectsWrongHandIdentityEvenWithOwnIndicator() {
        for attributes in [["AXRole": "AXButton", "AXDOMIdentifier": "participant-raisehands-button"],
                           ["AXRole": "AXStaticText", "AXDOMIdentifier": "raisehands-button"]] {
            let button = MediaButtonSnapshot.read(control: .hand) { attributes[$0] }
            XCTAssertEqual(HandClassifier.assess([WindowSnapshot(index: 1, controls: [hangup, button, ownVideo(.raised)])],
                                                complete: true).reason, "hand_control_missing")
        }
    }

    func testStaleTooltipDoesNotCauseTimeoutOrReverseRepeatedRequest() throws {
        for target in [HandTarget.raised, .lowered] {
            let initial: HandState = target == .raised ? .lowered : .raised
            let backend = FakeHandBackend([classified([call(1, initial)]), classified([call(1, initial)]),
                                           classified([call(1, target.state)]), classified([call(1, target.state)])])
            let controller = HandController(backend: backend)
            XCTAssertTrue(try controller.set(target).success)
            let repeated = try controller.set(target)
            XCTAssertTrue(repeated.success)
            XCTAssertEqual(repeated.changed, false)
            XCTAssertEqual(backend.presses.count, 1)
        }
    }

    func testIncompleteVerificationResetsConfirmationAndThenRecovers() throws {
        let partial = classified([call(1, .raised)], complete: false)
        let backend = FakeHandBackend([observed(.lowered), observed(.lowered), observed(.raised), partial,
                                       observed(.raised), observed(.raised)])
        let result = try HandController(backend: backend).set(.raised)
        XCTAssertTrue(result.success)
        XCTAssertEqual(backend.waitCount, 4)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testPersistentIncompleteVerificationStaysUnknownAndNeverRetriesPress() throws {
        let backend = FakeHandBackend([observed(.lowered), observed(.lowered),
                                       classified([call(1, .raised)], complete: false)])
        assertUncertain(try HandController(backend: backend).set(.raised), reason: "inspection_incomplete")
        XCTAssertEqual(backend.waitCount, 8)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testIncompleteVerificationDoesNotHideFocusLossOrReplacementCall() throws {
        let partial = classified([call(1, .raised)], complete: false)
        let lostFocus = FakeHandBackend([observed(.lowered), observed(.lowered), partial],
                                       focusValues: [true, true, true, false])
        assertUncertain(try HandController(backend: lostFocus).set(.raised), reason: "focus_changed")
        XCTAssertEqual(lostFocus.waitCount, 1)
        let replacement = FakeHandBackend([observed(.lowered), observed(.lowered), partial, observed(.raised, id: "call-b")])
        assertUncertain(try HandController(backend: replacement).set(.raised), reason: "target_changed")
        XCTAssertEqual(replacement.presses.count, 1)
    }

    func testOtherMediaPreDispatchSnapshotsKeepTheirLabelBehavior() {
        for control in [MediaControl.microphone, .camera] {
            var requested: [String] = []
            let attributes = ["AXRole": "AXButton", "AXIdentifier": control.rawValue,
                              "AXDescription": "", "AXTitle": "Main action", "AXHelp": "Other action"]
            let button = MediaButtonSnapshot.read(control: control) {
                requested.append($0)
                return attributes[$0]
            }
            XCTAssertEqual(button.identifier, control.rawValue)
            XCTAssertEqual(button.label, "Main action")
            XCTAssertNil(button.detailLabels)
            XCTAssertFalse(requested.contains("AXCustomContent"))
        }
    }

    private func assertNotAttempted(_ result: HandActionResult, reason: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertEqual(result.changed, false, file: file, line: line)
        XCTAssertFalse(result.actionAttempted, file: file, line: line)
    }

    private func assertUncertain(_ result: HandActionResult, reason: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, .unknown, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertNil(result.changed, file: file, line: line)
        XCTAssertTrue(result.actionAttempted, file: file, line: line)
    }

    private func observed(_ state: HandState, id: String? = "call-a", canPress: Bool = true) -> HandObservation {
        HandObservation(assessment: HandAssessment(state: state, reason: nil,
                                                  windows: [WindowHandStatus(window: 1, state: state)]),
                        targetID: id, canPress: canPress)
    }

    private func classified(_ windows: [WindowSnapshot], complete: Bool = true) -> HandObservation {
        let assessment = HandClassifier.assess(windows, complete: complete)
        return HandObservation(assessment: assessment,
                               targetID: [.raised, .lowered].contains(assessment.state) ? "call-a" : nil,
                               canPress: true)
    }

    private var hangup: ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave")
    }

    private func call(_ index: Int, _ state: HandState, held: Bool = false) -> WindowSnapshot {
        // Deliberately keep the action description stale across hand transitions.
        var controls = [hangup, ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise",
                                               detailLabels: ["Lower your hand"]), ownVideo(state)]
        if held { controls.append(ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")) }
        return WindowSnapshot(index: index, controls: controls)
    }

    private func ownVideo(_ state: HandState) -> ControlSnapshot {
        let marker = state == .raised ? ", Hand raised position 1" : state == .lowered ? "" : ", Hand unavailable"
        return ControlSnapshot(role: "AXImage", identifier: "",
            label: "Myself video, Example, Unmuted, video is on, Fill frame" + marker + ", Has context menu")
    }
}

private final class FakeHandBackend: HandBackend {
    struct Press {
        let targetID: String
        let expectedState: HandState
    }

    enum Failure: Error { case expected }

    let observations: [HandObservation]
    let focusValues: [Bool?]
    var sampleCount = 0
    var focusCount = 0
    var waitCount = 0
    var presses: [Press] = []
    var sampleErrorAt: Int?
    var throwOnPress = false
    var rejectionReason: String?

    init(_ observations: [HandObservation], focusValues: [Bool?] = [true]) {
        self.observations = observations
        self.focusValues = focusValues
    }

    func sample() throws -> HandObservation {
        let index = sampleCount
        sampleCount += 1
        if sampleErrorAt == index { throw Failure.expected }
        return observations[min(index, observations.count - 1)]
    }

    func press(targetID: String, expectedState: HandState) throws {
        presses.append(Press(targetID: targetID, expectedState: expectedState))
        if let rejectionReason { throw MediaPressRejected(reason: rejectionReason) }
        if throwOnPress { throw Failure.expected }
    }

    func focusPreserved() -> Bool? {
        let index = focusCount
        focusCount += 1
        return focusValues[min(index, focusValues.count - 1)]
    }

    func waitForUpdate() { waitCount += 1 }
}
