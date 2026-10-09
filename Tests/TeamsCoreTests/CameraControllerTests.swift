import XCTest
@testable import TeamsCore

final class CameraControllerTests: XCTestCase {
    func testToggleBothDirectionsPressOnceAndRequireTwoConsecutiveReadySamples() throws {
        for initial in [CameraState.on, .off] {
            let target: CameraState = initial == .on ? .off : .on
            let backend = FakeCameraBackend([
                observed(initial), observed(initial), observed(target, ready: false),
                observed(target), observed(target, ready: false), observed(target), observed(target),
            ])
            let result = try CameraController(backend: backend).toggle()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target)
            XCTAssertEqual(result.changed, true)
            XCTAssertTrue(result.actionAttempted)
            XCTAssertEqual(result.focusUnchanged, true)
            XCTAssertNil(result.reason)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.presses.first?.targetID, "call-a")
            XCTAssertEqual(backend.presses.first?.expectedState, initial)
            XCTAssertEqual(backend.sampleCount, 7)
            XCTAssertEqual(backend.waitCount, 5)
        }
    }

    func testRepeatedToggleResolvesANewTargetForEachInvocation() throws {
        let backend = FakeCameraBackend([
            observed(.off), observed(.off), observed(.on), observed(.on),
            observed(.on), observed(.on), observed(.off), observed(.off),
        ])
        let controller = CameraController(backend: backend)
        let first = try controller.toggle()
        let second = try controller.toggle()
        XCTAssertTrue(first.success)
        XCTAssertTrue(second.success)
        XCTAssertEqual(first.state, .on)
        XCTAssertEqual(second.state, .off)
        XCTAssertEqual(backend.presses.map(\.expectedState), [.off, .on])
    }

    func testToggleDoesNotUndoAConcurrentChangeBeforePress() throws {
        for initial in [CameraState.on, .off] {
            let target: CameraState = initial == .on ? .off : .on
            let backend = FakeCameraBackend([observed(initial), observed(target, ready: false)])
            let result = try CameraController(backend: backend).toggle()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target)
            XCTAssertEqual(result.changed, false)
            XCTAssertFalse(result.actionAttempted)
            XCTAssertTrue(backend.presses.isEmpty)
        }
    }

    func testToggleWaitsThroughDelayedCameraStartup() throws {
        let backend = FakeCameraBackend(
            [observed(.off), observed(.off)] +
            Array(repeating: observed(.off, ready: false), count: 8) +
            Array(repeating: observed(.on, ready: false), count: 8) +
            [observed(.on), observed(.on)])
        let result = try CameraController(backend: backend).toggle()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(result.changed, true)
        XCTAssertEqual(backend.waitCount, 18)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testToggleTimeoutNeverRetriesOrConfirmsAnUnsettledCamera() throws {
        for observations in [
            [observed(.off)],
            [observed(.off), observed(.off), observed(.on, ready: false)],
            Array(repeating: observed(.off), count: 160) + [observed(.on)],
        ] {
            let backend = FakeCameraBackend(observations)
            assertUncertain(try CameraController(backend: backend).toggle(), reason: "verification_timeout")
            XCTAssertEqual(backend.waitCount, 160)
            XCTAssertEqual(backend.presses.count, 1)
        }
    }

    func testToggleRejectsInvalidSelectionsInitiallyAndBeforePress() throws {
        let cases: [(CameraObservation, String)] = [
            (classified([]), "no_call_controls"),
            (classified([call(1, .off), call(2, .off)]), "multiple_call_windows"),
            (classified([call(1, .off, held: true)]), "all_calls_on_hold"),
            (classified([call(1, .off)], complete: false), "inspection_incomplete"),
            (classified([call(1, .unknown)]), "unrecognized_camera_label"),
            (observed(.ambiguous), "camera_state_unavailable"),
        ]
        for (invalid, reason) in cases {
            for observations in [[invalid], [observed(.off), invalid]] {
                let backend = FakeCameraBackend(observations)
                assertNotAttempted(try CameraController(backend: backend).toggle(), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty, reason)
            }
        }
    }

    func testToggleRejectsUnavailableControlsAndReplacementCalls() throws {
        let cases: [([CameraObservation], String)] = [
            ([observed(.off, id: nil)], "control_unavailable"),
            ([observed(.off, ready: false)], "control_unavailable"),
            ([observed(.off), observed(.off, ready: false)], "control_unavailable"),
            ([observed(.off), observed(.on, id: "call-b")], "target_changed"),
        ]
        for (observations, reason) in cases {
            let backend = FakeCameraBackend(observations)
            assertNotAttempted(try CameraController(backend: backend).toggle(), reason: reason)
            XCTAssertTrue(backend.presses.isEmpty)
        }
        let after = FakeCameraBackend([observed(.off), observed(.off), observed(.on, id: "call-b")])
        assertUncertain(try CameraController(backend: after).toggle(), reason: "target_changed")
        XCTAssertEqual(after.presses.count, 1)
    }

    func testToggleExcludesHeldCallsAndRetainsTheTargetAcrossWindowReordering() throws {
        let backend = FakeCameraBackend([
            classified([call(1, .off, held: true), call(2, .off)]),
            classified([call(1, .off, held: true), call(3, .off)]),
            classified([call(1, .off, held: true), call(3, .on)]),
            classified([call(1, .off, held: true), call(3, .on)]),
        ])
        let result = try CameraController(backend: backend).toggle()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.windows, [WindowCameraStatus(window: 3, state: .on)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testToggleRequiresPreservedFocusBeforeAndAfterPress() throws {
        let failures: [(Bool?, String)] = [(false, "focus_changed"), (nil, "focus_unavailable")]
        for (focus, reason) in failures {
            for values in [[focus], [true, focus]] {
                let backend = FakeCameraBackend([observed(.off)], focusValues: values)
                assertNotAttempted(try CameraController(backend: backend).toggle(), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty)
            }
            for values in [[true, true, focus], [true, true, true, focus]] {
                let backend = FakeCameraBackend([
                    observed(.off), observed(.off), observed(.on, ready: false),
                ], focusValues: values)
                assertUncertain(try CameraController(backend: backend).toggle(), reason: reason)
                XCTAssertEqual(backend.presses.count, 1)
                XCTAssertLessThanOrEqual(backend.waitCount, 1)
            }
        }
    }

    func testTogglePreDispatchRejectionsDoNotRetry() throws {
        for reason in ["preflight_failed", "target_changed", "camera_state_changed", "control_unavailable"] {
            let backend = FakeCameraBackend([observed(.off)])
            backend.rejectionReason = reason
            assertNotAttempted(try CameraController(backend: backend).toggle(), reason: reason)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.waitCount, 0)
        }
    }

    func testToggleReadErrorsDoNotCauseAnotherPress() throws {
        for failureIndex in [0, 1, 2] {
            let backend = FakeCameraBackend([observed(.off)])
            backend.sampleErrorAt = failureIndex
            if failureIndex < 2 {
                XCTAssertThrowsError(try CameraController(backend: backend).toggle())
                XCTAssertTrue(backend.presses.isEmpty)
            } else {
                assertUncertain(try CameraController(backend: backend).toggle(), reason: "action_outcome_unknown")
                XCTAssertEqual(backend.presses.count, 1)
            }
        }
    }

    func testTogglePressErrorIsUncertainAndNeverRetried() throws {
        let backend = FakeCameraBackend([observed(.off)])
        backend.throwOnPress = true
        assertUncertain(try CameraController(backend: backend).toggle(), reason: "action_outcome_unknown")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.sampleCount, 2)
        XCTAssertEqual(backend.waitCount, 0)
    }

    func testBothCommandsAreIdempotentEvenWhileControlIsDisabled() throws {
        for target in [CameraTarget.on, .off] {
            let backend = FakeCameraBackend([observed(target.state, ready: false)])
            let result = try CameraController(backend: backend).set(target)
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

    func testBothDirectionsPressOnceAndConfirmTwoReadySamples() throws {
        for target in [CameraTarget.on, .off] {
            let initial: CameraState = target == .on ? .off : .on
            let backend = FakeCameraBackend([
                observed(initial), observed(initial), observed(target.state), observed(target.state),
            ])
            let result = try CameraController(backend: backend).set(target)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, target.state)
            XCTAssertEqual(result.changed, true)
            XCTAssertTrue(result.actionAttempted)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.presses.first?.targetID, "call-a")
            XCTAssertEqual(backend.presses.first?.expectedState, initial)
            XCTAssertEqual(backend.sampleCount, 4)
            XCTAssertEqual(backend.waitCount, 2)
        }
    }

    func testCameraStartupWaitsThroughOldAndDesiredLabelsWhileDisabled() throws {
        let backend = FakeCameraBackend(
            [observed(.off), observed(.off)] +
            Array(repeating: observed(.off, ready: false), count: 8) +
            Array(repeating: observed(.on, ready: false), count: 8) +
            [observed(.on), observed(.on)])
        let result = try CameraController(backend: backend).set(.on)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.state, .on)
        XCTAssertEqual(result.changed, true)
        XCTAssertEqual(backend.waitCount, 18)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testDisabledSampleBetweenReadySamplesResetsConfirmation() throws {
        let backend = FakeCameraBackend([
            observed(.off), observed(.off), observed(.on), observed(.on, ready: false),
            observed(.on), observed(.on),
        ])
        XCTAssertTrue(try CameraController(backend: backend).set(.on).success)
        XCTAssertEqual(backend.waitCount, 4)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testPermanentDisabledDesiredStateIsUncertainAndNeverRetried() throws {
        let backend = FakeCameraBackend([observed(.off), observed(.off), observed(.on, ready: false)])
        assertUncertain(try CameraController(backend: backend).set(.on), reason: "verification_timeout")
        XCTAssertEqual(backend.waitCount, 160)
        XCTAssertEqual(backend.sampleCount, 161)
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testUnchangedStateAndOneLateMatchCannotEstablishSuccess() throws {
        for observations in [
            [observed(.off)],
            Array(repeating: observed(.off), count: 160) + [observed(.on)],
        ] {
            let backend = FakeCameraBackend(observations)
            assertUncertain(try CameraController(backend: backend).set(.on), reason: "verification_timeout")
            XCTAssertEqual(backend.waitCount, 160)
            XCTAssertEqual(backend.presses.count, 1)
        }
    }

    func testExternalChangeToDesiredStateBeforePressBecomesANoop() throws {
        let backend = FakeCameraBackend([observed(.off), observed(.on, ready: false)])
        let result = try CameraController(backend: backend).set(.on)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.changed, false)
        XCTAssertFalse(result.actionAttempted)
        XCTAssertTrue(backend.presses.isEmpty)
    }

    func testDisabledControlBeforeDispatchIsRefused() throws {
        let backend = FakeCameraBackend([observed(.off), observed(.off, ready: false)])
        assertNotAttempted(try CameraController(backend: backend).set(.on), reason: "control_unavailable")
        XCTAssertTrue(backend.presses.isEmpty)
    }

    func testMissingIdentityAndReplacementCallsCannotReceiveOrConfirmAction() throws {
        let missing = FakeCameraBackend([observed(.on, id: nil)])
        assertNotAttempted(try CameraController(backend: missing).set(.on), reason: "control_unavailable")
        XCTAssertTrue(missing.presses.isEmpty)

        let before = FakeCameraBackend([observed(.off), observed(.on, id: "call-b")])
        assertNotAttempted(try CameraController(backend: before).set(.on), reason: "target_changed")
        XCTAssertTrue(before.presses.isEmpty)

        let after = FakeCameraBackend([observed(.off), observed(.off), observed(.on, id: "call-b")])
        assertUncertain(try CameraController(backend: after).set(.on), reason: "target_changed")
        XCTAssertEqual(after.presses.count, 1)
    }

    func testInvalidCallSelectionsNeverPressInitiallyOrAfterRecheck() throws {
        let invalid: [(CameraObservation, String)] = [
            (classified([]), "no_call_controls"),
            (classified([call(1, .off, held: true)]), "all_calls_on_hold"),
            (classified([call(1, .off), call(2, .off)]), "multiple_call_windows"),
            (classified([call(1, .off)], complete: false), "inspection_incomplete"),
            (classified([call(1, .unknown)]), "unrecognized_camera_label"),
        ]
        for (observation, reason) in invalid {
            for samples in [[observation], [observed(.off), observation]] {
                let backend = FakeCameraBackend(samples)
                assertNotAttempted(try CameraController(backend: backend).set(.on), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty)
            }
        }
    }

    func testHeldExclusionAndChangingWindowIndexPreserveStableCallIdentity() throws {
        let backend = FakeCameraBackend([
            classified([call(1, .off, held: true), call(2, .off)]),
            classified([call(1, .off, held: true), call(3, .off)]),
            classified([call(1, .off, held: true), call(3, .on)]),
            classified([call(1, .off, held: true), call(3, .on)]),
        ])
        let result = try CameraController(backend: backend).set(.on)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.windows, [WindowCameraStatus(window: 3, state: .on)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 1, reason: "on_hold")])
        XCTAssertEqual(backend.presses.count, 1)
    }

    func testHeldOrUnreadableCallAfterPressCannotBeConfirmed() throws {
        for (observation, reason) in [
            (classified([call(1, .on, held: true)]), "all_calls_on_hold"),
            (classified([call(1, .unknown)]), "unrecognized_camera_label"),
        ] {
            let backend = FakeCameraBackend([observed(.off), observed(.off), observation])
            assertUncertain(try CameraController(backend: backend).set(.on), reason: reason)
            XCTAssertEqual(backend.presses.count, 1)
        }
    }

    func testUnconfirmedFocusBeforeActionRefusesAndAfterActionStopsVerification() throws {
        let failures: [(Bool?, String)] = [(false, "focus_changed"), (nil, "focus_unavailable")]
        for (focus, reason) in failures {
            for values in [[focus], [true, focus]] {
                let backend = FakeCameraBackend([observed(.off)], focusValues: values)
                assertNotAttempted(try CameraController(backend: backend).set(.on), reason: reason)
                XCTAssertTrue(backend.presses.isEmpty)
            }
            for values in [[true, true, focus], [true, true, true, focus]] {
                let backend = FakeCameraBackend([
                    observed(.off), observed(.off), observed(.on, ready: false),
                ], focusValues: values)
                assertUncertain(try CameraController(backend: backend).set(.on), reason: reason)
                XCTAssertEqual(backend.presses.count, 1)
                XCTAssertLessThanOrEqual(backend.waitCount, 1)
            }
        }
    }

    func testPreDispatchRejectionsRemainKnownNotToHaveActed() throws {
        for reason in ["preflight_failed", "target_changed", "camera_state_changed", "control_unavailable"] {
            let backend = FakeCameraBackend([observed(.off)])
            backend.rejectionReason = reason
            let result = try CameraController(backend: backend).set(.on)
            assertNotAttempted(result, reason: reason)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(backend.presses.count, 1)
            XCTAssertEqual(backend.waitCount, 0)
        }
    }

    func testSamplingErrorsBeforeActionPropagateAndAfterActionAreUncertain() throws {
        for index in [0, 1] {
            let backend = FakeCameraBackend([observed(.off)])
            backend.sampleErrorAt = index
            XCTAssertThrowsError(try CameraController(backend: backend).set(.on))
            XCTAssertTrue(backend.presses.isEmpty)
        }
        let after = FakeCameraBackend([observed(.off)])
        after.sampleErrorAt = 2
        assertUncertain(try CameraController(backend: after).set(.on), reason: "action_outcome_unknown")
        XCTAssertEqual(after.presses.count, 1)
    }

    func testDispatchErrorIsUncertainAndNeverRetried() throws {
        let backend = FakeCameraBackend([observed(.off)])
        backend.throwOnPress = true
        assertUncertain(try CameraController(backend: backend).set(.on), reason: "action_outcome_unknown")
        XCTAssertEqual(backend.presses.count, 1)
        XCTAssertEqual(backend.waitCount, 0)
    }

    private func assertNotAttempted(_ result: CameraActionResult, reason: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertEqual(result.changed, false, file: file, line: line)
        XCTAssertFalse(result.actionAttempted, file: file, line: line)
    }

    private func assertUncertain(_ result: CameraActionResult, reason: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, .unknown, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertNil(result.changed, file: file, line: line)
        XCTAssertTrue(result.actionAttempted, file: file, line: line)
    }

    private func observed(_ state: CameraState, id: String? = "call-a", ready: Bool = true) -> CameraObservation {
        CameraObservation(assessment: CameraAssessment(
            state: state, reason: nil, windows: [WindowCameraStatus(window: 1, state: state)]
        ), targetID: id, canPress: ready)
    }

    private func classified(_ windows: [WindowSnapshot], complete: Bool = true) -> CameraObservation {
        CameraObservation(assessment: CameraClassifier.assess(windows, complete: complete),
                          targetID: "call-a", canPress: true)
    }

    private func call(_ index: Int, _ state: CameraState, held: Bool = false) -> WindowSnapshot {
        var controls = [
            ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave"),
            ControlSnapshot(role: "AXButton", identifier: "video-button",
                            label: state == .off ? "Turn camera on" : state == .on ? "Turn camera off" : "Camera"),
        ]
        if held { controls.append(ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")) }
        return WindowSnapshot(index: index, controls: controls)
    }
}

private final class FakeCameraBackend: CameraBackend {
    struct Press {
        let targetID: String
        let expectedState: CameraState
    }

    enum Failure: Error { case expected }

    let observations: [CameraObservation]
    let focusValues: [Bool?]
    var sampleCount = 0
    var focusCount = 0
    var waitCount = 0
    var presses: [Press] = []
    var sampleErrorAt: Int?
    var throwOnPress = false
    var rejectionReason: String?

    init(_ observations: [CameraObservation], focusValues: [Bool?] = [true]) {
        self.observations = observations
        self.focusValues = focusValues
    }

    func sample() throws -> CameraObservation {
        let index = sampleCount
        sampleCount += 1
        if sampleErrorAt == index { throw Failure.expected }
        return observations[min(index, observations.count - 1)]
    }

    func press(targetID: String, expectedState: CameraState) throws {
        presses.append(Press(targetID: targetID, expectedState: expectedState))
        if let rejectionReason { throw CameraPressRejected(reason: rejectionReason) }
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
