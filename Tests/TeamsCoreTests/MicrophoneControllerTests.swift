import XCTest
@testable import TeamsCore

final class MicrophoneControllerTests: XCTestCase {
    func testToggleInBothDirectionsPressesOnceAndConfirmsTwoSamples() throws {
        for initial in [MicrophoneState.muted, .unmuted] {
            let target: MicrophoneState = initial == .muted ? .unmuted : .muted
            let backend = FakeMicrophoneBackend([
                observed(initial), observed(initial), observed(target), observed(target),
            ])
            let result = try MicrophoneController(backend: backend).toggle()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target)
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

    func testRepeatedToggleResolvesANewTargetForEachInvocation() throws {
        let backend = FakeMicrophoneBackend([
            observed(.muted), observed(.muted), observed(.unmuted), observed(.unmuted),
            observed(.unmuted), observed(.unmuted), observed(.muted), observed(.muted),
        ])
        let controller = MicrophoneController(backend: backend)
        let first = try controller.toggle()
        let second = try controller.toggle()
        XCTAssertTrue(first.success)
        XCTAssertTrue(second.success)
        XCTAssertEqual(first.state, .unmuted)
        XCTAssertEqual(second.state, .muted)
        XCTAssertEqual(backend.presses.map(\.expectedState), [.muted, .unmuted])
    }

    func testToggleDoesNotUndoAConcurrentChangeBeforePress() throws {
        for initial in [MicrophoneState.muted, .unmuted] {
            let target: MicrophoneState = initial == .muted ? .unmuted : .muted
            let backend = FakeMicrophoneBackend([
                observed(initial), observed(target, canPress: false),
            ])
            let result = try MicrophoneController(backend: backend).toggle()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target)
            XCTAssertEqual(result.changed, false)
            XCTAssertFalse(result.actionAttempted)
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testToggleRejectsInvalidSelectionsInitiallyAndBeforePress() throws {
        let cases: [(MicrophoneObservation, String)] = [
            (classified([]), "no_call_controls"),
            (classified([call(1, .muted), call(2, .muted)]), "multiple_call_windows"),
            (classified([call(1, .muted, held: true)]), "all_calls_on_hold"),
            (classified([call(1, .muted)], complete: false), "inspection_incomplete"),
            (classified([call(1, .unknown)]), "unrecognized_microphone_label"),
            (observed(.ambiguous), "microphone_state_unavailable"),
        ]
        for (invalid, reason) in cases {
            for observations in [[invalid], [observed(.muted), invalid]] {
                let backend = FakeMicrophoneBackend(observations)
                assertNotAttempted(try MicrophoneController(backend: backend).toggle(), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty, reason)
            }
        }
    }

    func testToggleExcludesHeldCallsAndPreservesTheActiveTargetAcrossWindowReordering() throws {
        let backend = FakeMicrophoneBackend([
            classified([call(1, .muted, held: true), call(2, .unmuted)]),
            classified([call(1, .muted, held: true), call(3, .unmuted)]),
            classified([call(1, .muted, held: true), call(3, .muted)]),
            classified([call(1, .muted, held: true), call(3, .muted)]),
        ])
        let result = try MicrophoneController(backend: backend).toggle()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.windows, [WindowMicrophoneStatus(window: 3, state: .muted)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testToggleRejectsMissingIdentityAndDisabledControls() throws {
        let cases: [[MicrophoneObservation]] = [
            [observed(.muted, id: nil)],
            [observed(.muted, canPress: false)],
            [observed(.muted), observed(.muted, canPress: false)],
        ]
        for observations in cases {
            let backend = FakeMicrophoneBackend(observations)
            assertNotAttempted(try MicrophoneController(backend: backend).toggle(), reason: "control_unavailable")
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testToggleRejectsReplacementCallsBeforeAndAfterPress() throws {
        let before = FakeMicrophoneBackend([observed(.muted), observed(.unmuted, id: "call-b")])
        assertNotAttempted(try MicrophoneController(backend: before).toggle(), reason: "target_changed")
        XCTAssertTrue(before.presses.isEmpty)

        let after = FakeMicrophoneBackend([
            observed(.muted), observed(.muted), observed(.unmuted, id: "call-b"),
        ])
        assertUncertain(try MicrophoneController(backend: after).toggle(), reason: "target_changed")
        XCTAssertEqual(after.presses.count, 1)
    }

    func testToggleRequiresPreservedFocusBeforeAndAfterPress() throws {
        let failures: [Bool?] = [false, nil]
        for badFocus in failures {
            let reason = badFocus == nil ? "focus_unavailable" : "focus_changed"
            for focusValues in [[badFocus], [true, badFocus]] {
                let backend = FakeMicrophoneBackend([observed(.muted)], focusValues: focusValues)
                assertNotAttempted(try MicrophoneController(backend: backend).toggle(), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty)
            }
            for focusValues in [[true, true, badFocus], [true, true, true, badFocus]] {
                let backend = FakeMicrophoneBackend([
                    observed(.muted), observed(.muted), observed(.unmuted), observed(.unmuted),
                ], focusValues: focusValues)
                assertUncertain(try MicrophoneController(backend: backend).toggle(), reason: reason)
                XCTAssertEqual(backend.presses.count, 1)
            }
        }
    }

    func testToggleRequiresConsecutiveMatchesWithoutRepeatingThePress() throws {
        let backend = FakeMicrophoneBackend([
            observed(.muted), observed(.muted), observed(.unmuted), observed(.muted),
            observed(.unmuted), observed(.unmuted),
        ])
        let result = try MicrophoneController(backend: backend).toggle()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.state, .unmuted)
        XCTAssertEqual(backend.waitCount, 4)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testToggleTimeoutAndUncertainPressAreNeverRetried() throws {
        let timeout = FakeMicrophoneBackend([observed(.muted)])
        assertUncertain(try MicrophoneController(backend: timeout).toggle(), reason: "verification_timeout")
        XCTAssertEqual(timeout.presses.count, 1)
        XCTAssertEqual(timeout.waitCount, 160)

        let pressError = FakeMicrophoneBackend([observed(.muted)])
        pressError.throwOnPress = true
        assertUncertain(try MicrophoneController(backend: pressError).toggle(), reason: "action_outcome_unknown")
        XCTAssertEqual(pressError.presses.count, 1)
        XCTAssertEqual(pressError.sampleCount, 2)
    }

    func testToggleReadErrorsDoNotCauseAnotherPress() throws {
        for failureIndex in [0, 1, 2] {
            let backend = FakeMicrophoneBackend([observed(.muted)])
            backend.sampleErrorAt = failureIndex
            if failureIndex < 2 {
                XCTAssertThrowsError(try MicrophoneController(backend: backend).toggle())
                XCTAssertTrue(backend.presses.isEmpty)
            } else {
                assertUncertain(try MicrophoneController(backend: backend).toggle(), reason: "action_outcome_unknown")
                XCTAssertEqual(backend.presses.count, 1)
            }
        }
    }

    func testToggleRejectsALastMomentStateChangeWithoutRetrying() throws {
        let backend = FakeMicrophoneBackend([observed(.muted)])
        backend.rejectionReason = "microphone_state_changed"
        assertNotAttempted(try MicrophoneController(backend: backend).toggle(), reason: "microphone_state_changed")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.waitCount, 0)
    }

    func testBothCommandsAreIdempotentEvenWhenTheControlCannotBePressed() throws {
        for target in [MicrophoneTarget.muted, .unmuted] {
            let backend = FakeMicrophoneBackend([observed(target.state, canPress: false)])
            let result = try MicrophoneController(backend: backend).set(target)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target.state)
            XCTAssertEqual(result.changed, false)
            XCTAssertFalse(result.actionAttempted)
            XCTAssertEqual(result.focusUnchanged, true)
            XCTAssertNil(result.reason)
            XCTAssertTrue(backend.presses.isEmpty)
            XCTAssertEqual(backend.sampleCount, 1)
        }
    }

    func testEachDirectionPressesExactlyOnceAndRequiresTwoConfirmedSamples() throws {
        for target in [MicrophoneTarget.muted, .unmuted] {
            let original: MicrophoneState = target == .muted ? .unmuted : .muted
            let backend = FakeMicrophoneBackend([
                observed(original), observed(original), observed(target.state), observed(target.state),
            ])
            let result = try MicrophoneController(backend: backend).set(target)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target.state)
            XCTAssertEqual(result.changed, true)
            XCTAssertTrue(result.actionAttempted)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.presses.first?.targetID, "call-a")
            XCTAssertEqual(backend.presses.first?.expectedState, original)
            XCTAssertEqual(backend.sampleCount, 4)
            XCTAssertEqual(backend.waitCount, 2)
        }
    }

    func testStateChangedBySomeoneElseBeforePressBecomesANoop() throws {
        let backend = FakeMicrophoneBackend([observed(.unmuted), observed(.muted)])
        let result = try MicrophoneController(backend: backend).set(.muted)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.changed, false)
        XCTAssertFalse(result.actionAttempted)
        XCTAssertTrue(backend.presses.isEmpty)
    }

    func testTargetIdentityChangeBeforePressAbortsEvenIfNewCallHasDesiredState() throws {
        let backend = FakeMicrophoneBackend([observed(.unmuted), observed(.muted, id: "call-b")])
        assertNotAttempted(try MicrophoneController(backend: backend).set(.muted), reason: "target_changed")
        XCTAssertTrue(backend.presses.isEmpty)
    }

    func testWindowIndexChangesDoNotChangeTheStableTargetIdentity() throws {
        let backend = FakeMicrophoneBackend([
            observed(.unmuted, window: 1), observed(.unmuted, window: 3),
            observed(.muted, window: 3), observed(.muted, window: 3),
        ])
        let result = try MicrophoneController(backend: backend).set(.muted)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.windows, [WindowMicrophoneStatus(window: 3, state: .muted)])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testMissingTargetIdentityCannotBeUsedEvenForANoop() throws {
        let backend = FakeMicrophoneBackend([observed(.muted, id: nil)])
        assertNotAttempted(try MicrophoneController(backend: backend).set(.muted), reason: "control_unavailable")
        XCTAssertTrue(backend.presses.isEmpty)
    }

    func testDisabledControlAtFinalReadIsNotPressed() throws {
        let backend = FakeMicrophoneBackend([observed(.unmuted), observed(.unmuted, canPress: false)])
        assertNotAttempted(try MicrophoneController(backend: backend).set(.muted), reason: "control_unavailable")
        XCTAssertTrue(backend.presses.isEmpty)
    }

    func testInvalidCallSelectionsAreRejectedInitiallyAndWhenRechecked() throws {
        let cases: [(MicrophoneObservation, String)] = [
            (classified([call(1, .muted), call(2, .muted)]), "multiple_call_windows"),
            (classified([call(1, .muted, held: true)]), "all_calls_on_hold"),
            (classified([]), "no_call_controls"),
            (classified([call(1, .unmuted)], complete: false), "inspection_incomplete"),
            (classified([call(1, .unknown)]), "unrecognized_microphone_label"),
        ]
        for (invalid, reason) in cases {
            for observations in [[invalid], [observed(.unmuted), invalid]] {
                let backend = FakeMicrophoneBackend(observations)
                assertNotAttempted(try MicrophoneController(backend: backend).set(.muted), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty, reason)
            }
        }
    }

    func testHeldCallExclusionsArePreservedWhileActiveCallChanges() throws {
        let backend = FakeMicrophoneBackend([
            classified([call(1, .muted, held: true), call(2, .unmuted)]),
            classified([call(1, .muted, held: true), call(2, .unmuted)]),
            classified([call(1, .muted, held: true), call(2, .muted)]),
            classified([call(1, .muted, held: true), call(2, .muted)]),
        ])
        let result = try MicrophoneController(backend: backend).set(.muted)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(result.windows, [WindowMicrophoneStatus(window: 2, state: .muted)])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testControllerRejectsInconsistentAssessmentInsteadOfTrustingKnownOverallState() throws {
        let cases = [
            MicrophoneAssessment(state: .muted, reason: nil, windows: []),
            MicrophoneAssessment(state: .muted, reason: nil, windows: [
                WindowMicrophoneStatus(window: 1, state: .muted),
                WindowMicrophoneStatus(window: 2, state: .muted),
            ]),
            MicrophoneAssessment(state: .muted, reason: nil, windows: [
                WindowMicrophoneStatus(window: 1, state: .unknown),
            ]),
        ]
        for assessment in cases {
            let backend = FakeMicrophoneBackend([
                MicrophoneObservation(assessment: assessment, targetID: "call-a", canPress: true),
            ])
            let result = try MicrophoneController(backend: backend).set(.muted)
            XCTAssertFalse(result.success)
            XCTAssertFalse(result.actionAttempted)
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testUnconfirmedFocusInitiallyOrBeforePressPreventsMutation() throws {
        let failures: [(Bool?, String)] = [(false, "focus_changed"), (nil, "focus_unavailable")]
        for (badFocus, reason) in failures {
            for focusValues in [[badFocus], [true, badFocus]] {
                let backend = FakeMicrophoneBackend([observed(.unmuted)], focusValues: focusValues)
                assertNotAttempted(try MicrophoneController(backend: backend).set(.muted), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty)
            }
        }
    }

    func testNoopStillRequiresConfirmedUnchangedFocus() throws {
        let backend = FakeMicrophoneBackend([observed(.muted)], focusValues: [nil])
        assertNotAttempted(try MicrophoneController(backend: backend).set(.muted), reason: "focus_unavailable")
        XCTAssertTrue(backend.presses.isEmpty)
    }

    func testFocusLossAfterPressOrDuringVerificationLeavesOutcomeUnknown() throws {
        let failures: [(Bool?, String)] = [(false, "focus_changed"), (nil, "focus_unavailable")]
        for (badFocus, reason) in failures {
            for focusValues in [[true, true, badFocus], [true, true, true, badFocus]] {
                let backend = FakeMicrophoneBackend([
                    observed(.unmuted), observed(.unmuted), observed(.muted), observed(.muted),
                ], focusValues: focusValues)
                assertUncertain(try MicrophoneController(backend: backend).set(.muted), reason: reason)
                XCTAssertEqual(backend.presses.count, 1)
                XCTAssertLessThanOrEqual(backend.waitCount, 1)
            }
        }
    }

    func testAChangedTargetAfterPressCannotConfirmTheRequestedOutcome() throws {
        let backend = FakeMicrophoneBackend([
            observed(.unmuted), observed(.unmuted), observed(.muted, id: "call-b"),
        ])
        assertUncertain(try MicrophoneController(backend: backend).set(.muted), reason: "target_changed")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.sampleCount, 3)
    }

    func testCallBecomingHeldAfterPressLeavesOutcomeUnknownWithoutResumingIt() throws {
        let backend = FakeMicrophoneBackend([
            observed(.unmuted), observed(.unmuted), classified([call(1, .muted, held: true)]),
        ])
        let result = try MicrophoneController(backend: backend).set(.muted)
        assertUncertain(result, reason: "all_calls_on_hold")
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testVerificationNeedsConsecutiveMatchesAndDoesNotToggleAgain() throws {
        let backend = FakeMicrophoneBackend([
            observed(.unmuted), observed(.unmuted), observed(.muted), observed(.unmuted),
            observed(.muted), observed(.muted),
        ])
        let result = try MicrophoneController(backend: backend).set(.muted)
        XCTAssertTrue(result.success)
        XCTAssertEqual(backend.waitCount, 4)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testVerificationTimeoutDoesNotRetryEvenIfStateStillAppearsUnchanged() throws {
        let backend = FakeMicrophoneBackend([observed(.unmuted)])
        assertUncertain(try MicrophoneController(backend: backend).set(.muted), reason: "verification_timeout")
        XCTAssertEqual(backend.sampleCount, 161)
        XCTAssertEqual(backend.waitCount, 160)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testOneMatchingSampleAtDeadlineDoesNotEstablishSuccess() throws {
        let backend = FakeMicrophoneBackend(Array(repeating: observed(.unmuted), count: 160) + [observed(.muted)])
        assertUncertain(try MicrophoneController(backend: backend).set(.muted), reason: "verification_timeout")
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testReadErrorsBeforeAnyActionPropagateWithoutPressing() {
        for failureIndex in [0, 1] {
            let backend = FakeMicrophoneBackend([observed(.unmuted)])
            backend.sampleErrorAt = failureIndex
            XCTAssertThrowsError(try MicrophoneController(backend: backend).set(.muted))
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testPressErrorIsAnUnknownOutcomeAndIsNeverRetried() throws {
        let backend = FakeMicrophoneBackend([observed(.unmuted)])
        backend.throwOnPress = true
        assertUncertain(try MicrophoneController(backend: backend).set(.muted), reason: "action_outcome_unknown")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.sampleCount, 2)
        XCTAssertEqual(backend.waitCount, 0)
    }

    func testPreDispatchRejectionReportsNoActionAndRefreshesFocusWithoutRetrying() throws {
        for reason in ["preflight_failed", "target_changed", "microphone_state_changed",
                       "control_unavailable", "focus_changed", "focus_unavailable"] {
            let backend = FakeMicrophoneBackend([observed(.unmuted)], focusValues: [true, true, false])
            backend.rejectionReason = reason
            let result = try MicrophoneController(backend: backend).set(.muted)
            assertNotAttempted(result, reason: reason)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.focusUnchanged, false)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.sampleCount, 2)
            XCTAssertEqual(backend.waitCount, 0)
        }
    }

    func testReadErrorAfterActionIsAnUnknownOutcomeAndIsNeverRetried() throws {
        let backend = FakeMicrophoneBackend([observed(.unmuted)])
        backend.sampleErrorAt = 2
        assertUncertain(try MicrophoneController(backend: backend).set(.muted), reason: "action_outcome_unknown")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.waitCount, 1)
    }

    private func assertNotAttempted(_ result: MicrophoneActionResult, reason: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertEqual(result.changed, false, file: file, line: line)
        XCTAssertFalse(result.actionAttempted, file: file, line: line)
    }

    private func assertUncertain(_ result: MicrophoneActionResult, reason: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, .unknown, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertNil(result.changed, file: file, line: line)
        XCTAssertTrue(result.actionAttempted, file: file, line: line)
    }

    private func observed(_ state: MicrophoneState, id: String? = "call-a", canPress: Bool = true,
                          window: Int = 1) -> MicrophoneObservation {
        MicrophoneObservation(assessment: MicrophoneAssessment(
            state: state, reason: nil, windows: [WindowMicrophoneStatus(window: window, state: state)]
        ), targetID: id, canPress: canPress)
    }

    private func classified(_ windows: [WindowSnapshot], complete: Bool = true) -> MicrophoneObservation {
        MicrophoneObservation(assessment: MicrophoneClassifier.assess(windows, complete: complete),
                              targetID: "call-a", canPress: true)
    }

    private func call(_ index: Int, _ state: MicrophoneState, held: Bool = false) -> WindowSnapshot {
        var controls = [
            ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave"),
            ControlSnapshot(role: "AXButton", identifier: "microphone-button",
                            label: state == .muted ? "Unmute mic" : state == .unmuted ? "Mute mic" : "Microphone"),
        ]
        if held { controls.append(ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")) }
        return WindowSnapshot(index: index, controls: controls)
    }
}

private final class FakeMicrophoneBackend: MicrophoneBackend {
    struct Press {
        let targetID: String
        let expectedState: MicrophoneState
    }

    enum Failure: Error { case expected }

    let observations: [MicrophoneObservation]
    let focusValues: [Bool?]
    var sampleCount = 0
    var focusCount = 0
    var waitCount = 0
    var presses: [Press] = []
    var sampleErrorAt: Int?
    var throwOnPress = false
    var rejectionReason: String?

    init(_ observations: [MicrophoneObservation], focusValues: [Bool?] = [true]) {
        self.observations = observations
        self.focusValues = focusValues
    }

    func sample() throws -> MicrophoneObservation {
        let index = sampleCount
        sampleCount += 1
        if sampleErrorAt == index { throw Failure.expected }
        return observations[min(index, observations.count - 1)]
    }

    func press(targetID: String, expectedState: MicrophoneState) throws {
        presses.append(Press(targetID: targetID, expectedState: expectedState))
        if let rejectionReason { throw MicrophonePressRejected(reason: rejectionReason) }
        if throwOnPress { throw Failure.expected }
    }

    func focusPreserved() -> Bool? {
        let index = focusCount
        focusCount += 1
        return focusValues[min(index, focusValues.count - 1)]
    }

    var verificationTimeRemaining: TimeInterval { max(0, 8 - Double(waitCount) * 0.05) }
    func waitForUpdate() { waitCount += 1 }
}
