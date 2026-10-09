import ApplicationServices
import XCTest
@testable import TeamsCore

final class MediaCommandIntegrationTests: XCTestCase {
    func testSetBothStatesDispatchesCorrectControlAndVerifiesTwice() throws {
        for command in CommandUnderTest.allCases {
            for target in [false, true] {
                let before = CommandFrame(active: !target)
                let after = CommandFrame(active: target)
                let harness = try MediaCommandHarness([before, before, after, after])
                let result = try command.run(harness, target: target)
                assertSuccess(result, state: command.state(active: target), changed: true)
                XCTAssertEqual(result.indices, [7])
                XCTAssertEqual(result.states, [command.state(active: target)])
                XCTAssertEqual(result.excluded, [.init(window: 12, reason: "on_hold")])
                XCTAssertEqual(harness.accessibility.reads.map(\.control), Array(repeating: command.control, count: 4))
                XCTAssertTrue(harness.accessibility.reads.allSatisfy { $0.timeout > 0 && $0.timeout <= 1.5 })
                XCTAssertEqual(harness.accessibility.pressed, [command.button])
                XCTAssertEqual(harness.accessibility.readsAtPress, 2)
                XCTAssertEqual(harness.waits, 2)
                harness.assertFinalized()
            }
        }
    }

    func testToggleResolvesBothDirectionsThroughTheCorrectClassifier() throws {
        for command in CommandUnderTest.allCases {
            for initial in [false, true] {
                let before = CommandFrame(active: initial)
                let after = CommandFrame(active: !initial)
                let harness = try MediaCommandHarness([before, before, after, after])
                let result = try command.run(harness)
                assertSuccess(result, state: command.state(active: !initial), changed: true)
                XCTAssertEqual(harness.accessibility.reads.map(\.control), Array(repeating: command.control, count: 4))
                XCTAssertEqual(harness.accessibility.pressed, [command.button])
                XCTAssertEqual(harness.accessibility.readsAtPress, 2)
                XCTAssertEqual(harness.waits, 2)
                harness.assertFinalized()
            }
        }
    }

    func testAlreadyRequestedStateIsANoOpEvenWhenControlIsDisabled() throws {
        for command in CommandUnderTest.allCases {
            for target in [false, true] {
                let harness = try MediaCommandHarness([CommandFrame(active: target, ready: false)])
                let result = try command.run(harness, target: target)
                assertSuccess(result, state: command.state(active: target), changed: false)
                XCTAssertEqual(harness.accessibility.reads.count, 1)
                XCTAssertTrue(harness.accessibility.directReads.isEmpty)
                XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                XCTAssertEqual(harness.waits, 0)
                harness.assertFinalized()
            }
        }
    }

    func testConcurrentChangeToResolvedToggleTargetAvoidsPressing() throws {
        for command in CommandUnderTest.allCases {
            for initial in [false, true] {
                let harness = try MediaCommandHarness([CommandFrame(active: initial), CommandFrame(active: !initial)])
                let result = try command.run(harness)
                assertSuccess(result, state: command.state(active: !initial), changed: false)
                XCTAssertEqual(harness.accessibility.reads.count, 2)
                XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                XCTAssertEqual(harness.waits, 0)
                harness.assertFinalized()
            }
        }
    }

    func testBackendStartsAfterExposureAndKeepsLockThroughPressAndCleanup() throws {
        for command in CommandUnderTest.allCases {
            let before = CommandFrame(active: false)
            let after = CommandFrame(active: true)
            let harness = try MediaCommandHarness([before, before, after, after])
            let lifecycle = harness.lifecycle
            harness.accessibility.onRead = { [unowned lifecycle] in
                lifecycle.assertLocked()
                XCTAssertEqual(lifecycle.client.value, true)
            }
            harness.accessibility.onPress = { [unowned lifecycle] in lifecycle.assertLocked() }
            lifecycle.client.onWrite = { [unowned lifecycle] _ in lifecycle.assertLocked() }
            lifecycle.focus.onStop = { [unowned lifecycle] in lifecycle.assertLocked() }
            XCTAssertTrue(try command.run(harness).success)
            XCTAssertEqual(Array(lifecycle.events.prefix(8)), [
                "permission", "lock", "focus.start", "expose", "read", "write true", "verify true", "backend"
            ])
            XCTAssertEqual(lifecycle.events.filter { $0 == "backend" }.count, 1)
            harness.assertFinalized()
        }
    }

    func testHeldAmbiguousAndIncompleteDiscoveryRefuseWithoutPressing() throws {
        let normal = CommandFrame(active: false)
        var held = normal
        held.snapshot = TeamsSnapshot(windows: [normal.snapshot.windows[1]], complete: true,
                                      focusUnchanged: true, handles: [:])
        var ambiguous = normal
        ambiguous.snapshot = TeamsSnapshot(windows: normal.snapshot.windows + [
            WindowSnapshot(index: 20, controls: normal.snapshot.windows[0].controls)
        ], complete: true, focusUnchanged: true, handles: normal.snapshot.handles)
        let cases = [(held, "all_calls_on_hold"), (ambiguous, "multiple_call_windows"),
                     (CommandFrame(active: false, complete: false), "inspection_incomplete")]
        for command in CommandUnderTest.allCases {
            for (frame, reason) in cases {
                for duringPreflight in [false, true] {
                    let harness = try MediaCommandHarness(duringPreflight ? [normal, frame] : [frame])
                    let result = try command.run(harness)
                    assertRefused(result, reason: reason)
                    XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                    XCTAssertEqual(harness.accessibility.reads.count, duringPreflight ? 2 : 1)
                    harness.assertFinalized()
                }
            }
        }
    }

    func testReadableStateWithoutNativeHandlesCannotAuthorizeAnAction() throws {
        for command in CommandUnderTest.allCases {
            var frame = CommandFrame(active: false)
            frame.snapshot.handles = [:]
            let harness = try MediaCommandHarness([frame])
            assertRefused(try command.run(harness), reason: "control_unavailable")
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            harness.assertFinalized()
        }
    }

    func testFreshStateChangeReturnsEachControlsSpecificRejectionReason() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            harness.accessibility.directValues = CommandFrame(active: true).values
            assertRefused(try command.run(harness), reason: command.changedReason)
            XCTAssertTrue(harness.accessibility.directReads.contains(command.button))
            if command == .hand {
                XCTAssertTrue(harness.accessibility.directReads.contains(AXUIElementCreateApplication(15)))
            }
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            XCTAssertEqual(harness.accessibility.reads.count, 2)
            harness.assertFinalized()
        }
    }

    func testFreshRoleOrIdentifierChangeCannotDispatch() throws {
        for command in CommandUnderTest.allCases {
            for change in [["AXRole": "AXStaticText"], ["AXDOMIdentifier": "other-control"]] {
                let harness = try MediaCommandHarness([CommandFrame(active: false)])
                harness.accessibility.directValues[command.button] = change
                assertRefused(try command.run(harness), reason: command.changedReason)
                XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                harness.assertFinalized()
            }
        }
    }

    func testChangedOrUnavailableFocusDuringDirectReadsPreventsDispatch() throws {
        for command in CommandUnderTest.allCases {
            for focus: Bool? in [false, nil] {
                let harness = try MediaCommandHarness([CommandFrame(active: false)])
                let monitor = harness.lifecycle.focus
                harness.accessibility.onValueRead = { [unowned monitor] in monitor.result = focus }
                let result = try command.run(harness)
                assertRefused(result, reason: focus == nil ? "focus_unavailable" : "focus_changed")
                XCTAssertEqual(result.focus, focus)
                XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                harness.assertFinalized()
            }
        }
    }

    func testUncertainNativePressIsNeverRetriedOrReportedAsChanged() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            harness.accessibility.pressError = .cannotComplete
            let result = try command.run(harness)
            assertUncertain(result, reason: "action_outcome_unknown")
            XCTAssertEqual(harness.accessibility.pressed, [command.button])
            XCTAssertEqual(harness.accessibility.reads.count, 2)
            XCTAssertEqual(harness.waits, 0)
            harness.assertFinalized()
        }
    }

    func testSuccessfulPressWithoutVerifiedStateRemainsUncertain() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            let result = try command.run(harness)
            assertUncertain(result, reason: "verification_timeout")
            XCTAssertEqual(harness.accessibility.pressed, [command.button])
            if command == .hand {
                XCTAssertEqual(harness.waits, 8)
                XCTAssertEqual(harness.accessibility.reads.count, harness.waits + 2)
            } else {
                XCTAssertEqual(harness.accessibility.uptime, 108, accuracy: 0.000_001)
                XCTAssertGreaterThanOrEqual(harness.waits, 160)
                XCTAssertLessThanOrEqual(harness.waits, 161)
                XCTAssertEqual(harness.accessibility.reads.count, harness.waits + 1)
            }
            harness.assertFinalized()
        }
    }

    func testConsecutiveVerificationResetsWhenStateReverts() throws {
        for command in CommandUnderTest.allCases {
            let before = CommandFrame(active: false)
            let after = CommandFrame(active: true)
            let harness = try MediaCommandHarness([before, before, after, before, after, after])
            assertSuccess(try command.run(harness), state: command.state(active: true), changed: true)
            XCTAssertEqual(harness.accessibility.pressed, [command.button])
            XCTAssertEqual(harness.waits, 4)
            XCTAssertEqual(harness.accessibility.reads.count, 6)
            harness.assertFinalized()
        }
    }

    func testReplacementWindowCannotInheritActionBeforeOrAfterPress() throws {
        for command in CommandUnderTest.allCases {
            for afterPress in [false, true] {
                let before = CommandFrame(active: false)
                let replacement = CommandFrame(active: afterPress, window: 20)
                let harness = try MediaCommandHarness(afterPress ? [before, before, replacement] : [before, replacement])
                let result = try command.run(harness)
                XCTAssertFalse(result.success)
                XCTAssertEqual(result.state, "unknown")
                XCTAssertEqual(result.reason, "target_changed")
                XCTAssertEqual(result.attempted, afterPress)
                XCTAssertEqual(result.changed, afterPress ? nil : false)
                XCTAssertEqual(harness.accessibility.pressed, afterPress ? [command.button] : [])
                harness.assertFinalized()
            }
        }
    }

    func testWindowReorderingPreservesTargetAndReportsLatestIndex() throws {
        for command in CommandUnderTest.allCases {
            let before = CommandFrame(active: false)
            let after = CommandFrame(active: true, index: 9)
            let harness = try MediaCommandHarness([before, CommandFrame(active: false, index: 3), after, after])
            let result = try command.run(harness)
            assertSuccess(result, state: command.state(active: true), changed: true)
            XCTAssertEqual(result.indices, [9])
            XCTAssertEqual(harness.accessibility.pressed, [command.button])
            harness.assertFinalized()
        }
    }

    func testCameraWaitsForTwoReadyObservationsAfterStartup() throws {
        let before = CommandFrame(active: false)
        let after = CommandFrame(active: true)
        let disabled = CommandFrame(active: true, ready: false)
        let harness = try MediaCommandHarness([before, before, disabled, after, disabled, after, after])
        assertSuccess(try CommandUnderTest.camera.run(harness), state: "on", changed: true)
        XCTAssertEqual(harness.waits, 5)
        XCTAssertEqual(harness.accessibility.reads.count, 7)
        XCTAssertEqual(harness.accessibility.pressed, [CommandUnderTest.camera.button])
        harness.assertFinalized()
    }

    func testHandRetriesIncompleteVerificationAndRequiresTwoFreshConfirmations() throws {
        let before = CommandFrame(active: false)
        let after = CommandFrame(active: true)
        let harness = try MediaCommandHarness([before, before, after, CommandFrame(active: true, complete: false), after, after])
        assertSuccess(try CommandUnderTest.hand.run(harness), state: "raised", changed: true)
        XCTAssertEqual(harness.waits, 4)
        XCTAssertEqual(harness.accessibility.reads.count, 6)
        XCTAssertEqual(harness.accessibility.pressed, [CommandUnderTest.hand.button])
        harness.assertFinalized()
    }

    func testMicrophoneAndCameraStopOnIncompleteVerificationWithoutRetryingPress() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            let before = CommandFrame(active: false)
            let harness = try MediaCommandHarness([before, before, CommandFrame(active: true, complete: false)])
            assertUncertain(try command.run(harness), reason: "inspection_incomplete")
            XCTAssertEqual(harness.waits, 1)
            XCTAssertEqual(harness.accessibility.pressed, [command.button])
            harness.assertFinalized()
        }
    }

    func testHandUsesOwnVideoEvidenceEvenWhenButtonLabelRemainsStale() throws {
        let before = CommandFrame(active: false)
        let after = CommandFrame(active: true)
        XCTAssertEqual(before.values[CommandUnderTest.hand.button], after.values[CommandUnderTest.hand.button])
        let harness = try MediaCommandHarness([before, before, after, after])
        assertSuccess(try CommandUnderTest.hand.run(harness), state: "raised", changed: true)
        XCTAssertTrue(harness.accessibility.directReads.contains(AXUIElementCreateApplication(15)))
        harness.assertFinalized()
    }

    func testVerificationReadErrorPreservesAttemptedActionAndCleansUp() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            harness.accessibility.readErrors[3] = .accessibilityFailure(-25204)
            let result = try command.run(harness)
            assertUncertain(result, reason: "action_outcome_unknown")
            XCTAssertEqual(result.indices, [7])
            XCTAssertEqual(result.states, [command.state(active: false)])
            XCTAssertEqual(harness.accessibility.pressed, [command.button])
            XCTAssertEqual(harness.waits, 1)
            harness.assertFinalized()
        }
    }

    private func assertSuccess(_ result: CommandTestResult, state: String, changed: Bool,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.success, file: file, line: line)
        XCTAssertEqual(result.state, state, file: file, line: line)
        XCTAssertNil(result.reason, file: file, line: line)
        XCTAssertEqual(result.changed, changed, file: file, line: line)
        XCTAssertEqual(result.attempted, changed, file: file, line: line)
        XCTAssertEqual(result.focus, true, file: file, line: line)
    }

    private func assertRefused(_ result: CommandTestResult, reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertFalse(result.attempted, file: file, line: line)
        XCTAssertEqual(result.changed, false, file: file, line: line)
    }

    private func assertUncertain(_ result: CommandTestResult, reason: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, "unknown", file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertTrue(result.attempted, file: file, line: line)
        XCTAssertNil(result.changed, file: file, line: line)
    }
}
