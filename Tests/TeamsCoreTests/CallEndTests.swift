import XCTest
@testable import TeamsCore

final class CallEndTests: XCTestCase {
    func testLeaveLabelsAndShortcutSuffixesAreRecognized() {
        for label in ["Leave", "Hang up", "  LEAVE  ", "Leave (⌘⇧H)", "Esci", "Abbandona"] {
            let assessment = CallEndClassifier.assess([call(1, label: label)], complete: true)
            XCTAssertEqual(assessment.state, .active, label)
            XCTAssertNil(assessment.reason, label)
        }
    }

    func testEndForEveryoneAndUnknownLabelsAreNotPressed() {
        for label in ["End meeting", "End meeting for all", "Leave everyone", "Leave (all)", "", "Call"] {
            let assessment = CallEndClassifier.assess([call(1, label: label)], complete: true)
            XCTAssertEqual(assessment.state, .unknown, label)
            XCTAssertEqual(assessment.reason, "unrecognized_hangup_label", label)
        }
    }

    func testExactButtonRoleAndIdentifierAreRequired() {
        for control in [
            ControlSnapshot(role: "AXStaticText", identifier: "hangup-button", label: "Leave"),
            ControlSnapshot(role: "AXButton", identifier: "hangup-button-menu", label: "Leave"),
            ControlSnapshot(role: "AXButton", identifier: "microphone-button", label: "Leave"),
        ] {
            let assessment = CallEndClassifier.assess([WindowSnapshot(index: 1, controls: [control])], complete: true)
            XCTAssertEqual(assessment.state, .unknown)
            XCTAssertEqual(assessment.reason, "no_call_controls")
        }
    }

    func testDuplicateLeaveButtonsAndMultipleActiveCallsAreAmbiguous() {
        let duplicate = WindowSnapshot(index: 1, controls: call(1).controls + call(1).controls)
        let sameWindow = CallEndClassifier.assess([duplicate], complete: true)
        XCTAssertEqual(sameWindow.state, .ambiguous)
        XCTAssertEqual(sameWindow.reason, "multiple_hangup_controls")
        let twoCalls = CallEndClassifier.assess([call(1), call(2)], complete: true)
        XCTAssertEqual(twoCalls.state, .ambiguous)
        XCTAssertEqual(twoCalls.reason, "multiple_call_windows")
    }

    func testHeldCallsAreExcludedWithoutUsingMediaState() {
        let assessment = CallEndClassifier.assess([call(1, held: true), call(2)], complete: true)
        XCTAssertEqual(assessment.state, .active)
        XCTAssertEqual(assessment.windows, [WindowCallStatus(window: 2, state: .active)])
        XCTAssertEqual(assessment.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        let heldOnly = CallEndClassifier.assess([call(1, held: true)], complete: true)
        XCTAssertEqual(heldOnly.state, .unknown)
        XCTAssertEqual(heldOnly.reason, "all_calls_on_hold")
    }

    func testMissingControlsNeverMeanAlreadyEnded() {
        for windows in [[], [WindowSnapshot(index: 1, controls: [])]] {
            let assessment = CallEndClassifier.assess(windows, complete: true)
            XCTAssertEqual(assessment.state, .unknown)
            XCTAssertEqual(assessment.reason, "no_call_controls")
        }
    }

    func testIncompleteInspectionTakesPrecedenceOverOtherStates() {
        for windows in [[], [call(1)], [call(1), call(2)], [call(1, held: true)]] {
            let assessment = CallEndClassifier.assess(windows, complete: false)
            XCTAssertEqual(assessment.state, .unknown)
            XCTAssertEqual(assessment.reason, "inspection_incomplete")
        }
    }

    func testLeavePressesOnceAndRequiresTwoConsecutiveWindowClosures() throws {
        let backend = FakeCallEndBackend([observed()], verifications: [present(), closed(), closed()])
        let result = try CallEndController(backend: backend).end()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.state, .ended)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.changed, true)
        XCTAssertTrue(result.actionAttempted)
        XCTAssertEqual(result.focusUnchanged, true)
        XCTAssertEqual(backend.presses, ["call-a"])
        XCTAssertEqual(backend.sampleCount, 2)
        XCTAssertEqual(backend.verificationTargets, Array(repeating: "call-a", count: 3))
        XCTAssertEqual(backend.waitCount, 3)
    }

    func testFocusChangesAndUnavailableFocusAreAllowedAndReported() throws {
        let focusValues: [[Bool?]] = [[false], [nil], [true, true, false], [true, true, nil]]
        for values in focusValues {
            let backend = FakeCallEndBackend([observed()], verifications: [closed()], focusValues: values)
            let result = try CallEndController(backend: backend).end()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.focusUnchanged, values.last!)
            XCTAssertEqual(backend.presses.count, 1)
        }
    }

    func testUnknownPresenceAndOnlyOneClosedObservationCannotConfirmSuccess() throws {
        let missingControls = CallEndVerification(assessment: assessed([]), presence: .unconfirmed)
        for verifications in [
            [present()], [missingControls],
            Array(repeating: present(), count: 19) + [closed()],
        ] {
            let backend = FakeCallEndBackend([observed()], verifications: verifications)
            assertUncertain(try CallEndController(backend: backend).end(), reason: "verification_timeout")
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.waitCount, 20)
        }
    }

    func testUnconfirmedObservationResetsClosureConfirmationWithoutAnotherPress() throws {
        let backend = FakeCallEndBackend([observed()], verifications: [
            closed(), CallEndVerification(assessment: assessed([]), presence: .unconfirmed), closed(), closed(),
        ])
        XCTAssertTrue(try CallEndController(backend: backend).end().success)
        XCTAssertEqual(backend.waitCount, 4)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testInvalidSelectionsRefuseInitiallyAndBeforeDispatch() throws {
        let cases: [(CallAssessment, String)] = [
            (assessed([]), "no_call_controls"),
            (assessed([call(1, held: true)]), "all_calls_on_hold"),
            (assessed([call(1), call(2)]), "multiple_call_windows"),
            (assessed([call(1)], complete: false), "inspection_incomplete"),
            (assessed([call(1, label: "End meeting for all")]), "unrecognized_hangup_label"),
            (assessed([WindowSnapshot(index: 1, controls: call(1).controls + call(1).controls)]), "multiple_hangup_controls"),
        ]
        for (assessment, reason) in cases {
            let invalid = CallEndObservation(assessment: assessment, targetID: nil, canPress: false)
            for samples in [[invalid], [observed(), invalid]] {
                let backend = FakeCallEndBackend(samples)
                assertNotAttempted(try CallEndController(backend: backend).end(), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty)
            }
        }
    }

    func testMissingIdentityDisabledControlAndReplacementCallCannotReceiveAPress() throws {
        let cases: [([CallEndObservation], String)] = [
            ([observed(id: nil)], "control_unavailable"),
            ([observed(canPress: false)], "control_unavailable"),
            ([observed(), observed(canPress: false)], "control_unavailable"),
            ([observed(), observed(id: "call-b")], "target_changed"),
        ]
        for (samples, reason) in cases {
            let backend = FakeCallEndBackend(samples)
            assertNotAttempted(try CallEndController(backend: backend).end(), reason: reason)
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testReplacementTargetDuringVerificationCannotConfirmSuccess() throws {
        let backend = FakeCallEndBackend([observed()], verifications: [
            CallEndVerification(assessment: assessed([]), presence: .changed),
        ])
        assertUncertain(try CallEndController(backend: backend).end(), reason: "target_changed")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.waitCount, 1)
    }

    func testHeldCallRemainsExcludedAfterTheSelectedCallCloses() throws {
        let before = CallEndObservation(assessment: assessed([call(1, held: true), call(2)]), targetID: "call-a", canPress: true)
        let reordered = CallEndObservation(assessment: assessed([call(1, held: true), call(3)]), targetID: "call-a", canPress: true)
        let backend = FakeCallEndBackend([before, reordered], verifications: [
            CallEndVerification(assessment: assessed([call(1, held: true)]), presence: .windowClosed),
        ])
        let result = try CallEndController(backend: backend).end()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.state, .ended)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(backend.presses, ["call-a"])
    }

    func testHeldOrUnreadableTargetAfterPressRemainsUncertain() throws {
        let cases: [(CallAssessment, String)] = [
            (assessed([call(1, held: true)]), "all_calls_on_hold"),
            (assessed([], complete: false), "inspection_incomplete"),
            (assessed([call(1, label: "Call")]), "unrecognized_hangup_label"),
            (assessed([call(1), call(2)]), "multiple_call_windows"),
        ]
        for (assessment, reason) in cases {
            let backend = FakeCallEndBackend([observed()], verifications: [
                CallEndVerification(assessment: assessment, presence: .sameCall),
            ])
            assertUncertain(try CallEndController(backend: backend).end(), reason: reason)
            XCTAssertEqual(backend.presses.count, 1)
        }
    }

    func testWindowClosureCannotOverrideAnIncompleteScan() throws {
        let backend = FakeCallEndBackend([observed()], verifications: [
            CallEndVerification(assessment: assessed([], complete: false), presence: .windowClosed),
        ])
        assertUncertain(try CallEndController(backend: backend).end(), reason: "inspection_incomplete")
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testPreDispatchRejectionsAreNotAttemptedAndNeverRetried() throws {
        for reason in ["preflight_failed", "target_changed", "control_unavailable", "all_calls_on_hold", "unrecognized_hangup_label"] {
            let backend = FakeCallEndBackend([observed()])
            backend.rejectionReason = reason
            assertNotAttempted(try CallEndController(backend: backend).end(), reason: reason)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.waitCount, 0)
        }
    }

    func testPressErrorIsUncertainAndNeverRetried() throws {
        let backend = FakeCallEndBackend([observed()])
        backend.throwOnPress = true
        assertUncertain(try CallEndController(backend: backend).end(), reason: "action_outcome_unknown")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.waitCount, 0)
    }

    func testReadErrorsBeforePressPropagateWithoutAnAction() {
        for index in [0, 1] {
            let backend = FakeCallEndBackend([observed()])
            backend.sampleErrorAt = index
            XCTAssertThrowsError(try CallEndController(backend: backend).end())
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testVerificationReadErrorLeavesOutcomeUncertain() throws {
        let backend = FakeCallEndBackend([observed()], verifications: [closed()])
        backend.throwOnVerification = true
        assertUncertain(try CallEndController(backend: backend).end(), reason: "action_outcome_unknown")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.waitCount, 1)
    }

    func testInconsistentAssessmentCannotSelectACall() throws {
        for windows in [[], [WindowCallStatus(window: 1, state: .unknown)],
                        [WindowCallStatus(window: 1, state: .active), WindowCallStatus(window: 2, state: .active)]] {
            let assessment = CallAssessment(state: .active, reason: nil, windows: windows, excludedWindows: [])
            let backend = FakeCallEndBackend([CallEndObservation(assessment: assessment, targetID: "call-a", canPress: true)])
            assertNotAttempted(try CallEndController(backend: backend).end(), reason: "call_state_unavailable")
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testFinalizationReportsFocusAfterCleanupWithoutFailingForFocusChanges() throws {
        let backend = FakeCallEndBackend([observed()], verifications: [closed()])
        let result = try CallEndController(backend: backend).end()
        let values: [Bool?] = [true, false, nil]
        for focus in values {
            let finalized = result.finalized(restored: true, focus: focus)
            XCTAssertTrue(finalized.success)
            XCTAssertEqual(finalized.state, .ended)
            XCTAssertEqual(finalized.changed, true)
            XCTAssertEqual(finalized.focusUnchanged, focus)
        }
    }

    func testCleanupFailureCannotReportSuccessOrClaimNoPress() throws {
        let backend = FakeCallEndBackend([observed()], verifications: [closed()])
        let result = try CallEndController(backend: backend).end()
        let failed = result.finalized(restored: false, focus: false)
        assertUncertain(failed, reason: "accessibility_cleanup_failed")
        XCTAssertEqual(failed.focusUnchanged, false)

        let refusedBackend = FakeCallEndBackend([observed(id: nil)])
        let refused = try CallEndController(backend: refusedBackend).end()
        assertNotAttempted(refused.finalized(restored: false, focus: nil), reason: "accessibility_cleanup_failed")
    }

    private func assertNotAttempted(_ result: CallEndResult, reason: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertEqual(result.changed, false, file: file, line: line)
        XCTAssertFalse(result.actionAttempted, file: file, line: line)
    }

    private func assertUncertain(_ result: CallEndResult, reason: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, .unknown, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertNil(result.changed, file: file, line: line)
        XCTAssertTrue(result.actionAttempted, file: file, line: line)
    }

    private func observed(id: String? = "call-a", canPress: Bool = true) -> CallEndObservation {
        CallEndObservation(assessment: assessed([call(1)]), targetID: id, canPress: canPress)
    }

    private func present() -> CallEndVerification {
        CallEndVerification(assessment: assessed([call(1)]), presence: .sameCall)
    }

    private func closed() -> CallEndVerification {
        CallEndVerification(assessment: assessed([]), presence: .windowClosed)
    }

    private func assessed(_ windows: [WindowSnapshot], complete: Bool = true) -> CallAssessment {
        CallEndClassifier.assess(windows, complete: complete)
    }

    private func call(_ index: Int, label: String = "Leave", held: Bool = false) -> WindowSnapshot {
        var controls = [ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: label)]
        if held { controls.append(ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")) }
        return WindowSnapshot(index: index, controls: controls)
    }
}

private final class FakeCallEndBackend: CallEndBackend {
    enum Failure: Error { case expected }

    let observations: [CallEndObservation]
    let verifications: [CallEndVerification]
    let focusValues: [Bool?]
    var sampleCount = 0
    var focusCount = 0
    var waitCount = 0
    var presses: [String] = []
    var verificationTargets: [String] = []
    var sampleErrorAt: Int?
    var throwOnPress = false
    var throwOnVerification = false
    var rejectionReason: String?

    init(_ observations: [CallEndObservation], verifications: [CallEndVerification] = [], focusValues: [Bool?] = [true]) {
        self.observations = observations
        self.verifications = verifications
        self.focusValues = focusValues
    }

    func sample() throws -> CallEndObservation {
        let index = sampleCount
        sampleCount += 1
        if sampleErrorAt == index { throw Failure.expected }
        return observations[min(index, observations.count - 1)]
    }

    func press(targetID: String) throws {
        presses.append(targetID)
        if let rejectionReason { throw CallEndPressRejected(reason: rejectionReason) }
        if throwOnPress { throw Failure.expected }
    }

    func verify(targetID: String) throws -> CallEndVerification {
        let index = verificationTargets.count
        verificationTargets.append(targetID)
        if throwOnVerification { throw Failure.expected }
        return verifications[min(index, verifications.count - 1)]
    }

    func focusPreserved() -> Bool? {
        let index = focusCount
        focusCount += 1
        return focusValues[min(index, focusValues.count - 1)]
    }

    func waitForUpdate() { waitCount += 1 }
}
