import ApplicationServices
import XCTest
@testable import TeamsCore

final class CallEndCommandIntegrationTests: XCTestCase {
    func testVerifiedClosurePressesOnlyLeaveAndPreservesHeldWindowDetails() throws {
        for held in [true, false] {
            let harness = try actionHarness(held: held)
            let result = try TeamsCallCommands.end(environment: harness.environment)
            assertEnded(result, focus: true, held: held)
            XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
            XCTAssertEqual(harness.accessibility.readsAtPress, 3)
            XCTAssertEqual(harness.accessibility.reads.map(\.control), Array(repeating: .call, count: 5))
            XCTAssertEqual(harness.accessibility.reads.map(\.timeout), Array(repeating: 1.5, count: 5))
            XCTAssertEqual(Set(harness.accessibility.directReads), [leaveButton])
            XCTAssertEqual(harness.waits, 2)
            harness.assertFinalized()
        }
    }

    func testVerifiedClosureAllowsFocusChangesAtEveryCommandStage() throws {
        for focus: Bool? in [false, nil] {
            for stage in ["initial", "dispatch", "press", "cleanup"] {
                let harness = try actionHarness()
                let monitor = harness.lifecycle.focus
                switch stage {
                case "initial": monitor.result = focus
                case "dispatch": harness.accessibility.onValueRead = { monitor.result = focus }
                case "press": harness.accessibility.onPress = { monitor.result = focus }
                default:
                    harness.lifecycle.client.onWait = { expected in
                        if !expected { monitor.result = focus }
                    }
                }
                let result = try TeamsCallCommands.end(environment: harness.environment)
                assertEnded(result, focus: focus)
                XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
                XCTAssertEqual(harness.waits, 2)
                harness.assertFinalized()
            }
        }
    }

    func testBackendStartsAfterExposureAndLockCoversDispatchCleanupAndFocusStop() throws {
        let harness = try actionHarness()
        let lifecycle = harness.lifecycle
        var lockedChecks = 0
        let checkLock = { [unowned lifecycle] in
            lifecycle.assertLocked()
            lockedChecks += 1
        }
        harness.accessibility.onRead = checkLock
        harness.accessibility.onValueRead = checkLock
        harness.accessibility.onPress = checkLock
        lifecycle.client.onWrite = { _ in checkLock() }
        lifecycle.client.onWait = { _ in checkLock() }
        lifecycle.focus.onStop = checkLock

        assertEnded(try TeamsCallCommands.end(environment: harness.environment), focus: true)
        XCTAssertGreaterThan(lockedChecks, 10)
        XCTAssertEqual(Array(lifecycle.events.prefix(9)),
                       ["permission", "lock", "focus.start", "expose", "read", "write true", "verify true", "backend", "sample"])
        XCTAssertEqual(lifecycle.events.filter { $0 == "backend" }.count, 1)
        harness.assertFinalized()
    }

    func testPermissionDenialPreventsLockExposureAndBackendCreation() throws {
        let harness = try actionHarness()
        harness.lifecycle.trusted = false
        XCTAssertThrowsError(try TeamsCallCommands.end(environment: harness.environment)) { error in
            guard case TeamsReadError.accessibilityDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(harness.lifecycle.events, ["permission"])
        XCTAssertTrue(harness.lifecycle.client.writes.isEmpty)
        XCTAssertTrue(harness.accessibility.reads.isEmpty)
        XCTAssertTrue(harness.accessibility.pressed.isEmpty)
        harness.lifecycle.assertUnlocked()
    }

    func testBusyLockPreventsExposureAndBackendCreation() throws {
        let harness = try actionHarness()
        let held = try MediaCommandLock(path: harness.lifecycle.path)
        defer { held.release() }
        assertCommandError(.commandInProgress) { try TeamsCallCommands.end(environment: harness.environment) }
        XCTAssertEqual(harness.lifecycle.events, ["permission", "lock"])
        XCTAssertTrue(harness.lifecycle.client.writes.isEmpty)
        XCTAssertTrue(harness.accessibility.reads.isEmpty)
        XCTAssertTrue(harness.accessibility.pressed.isEmpty)
    }

    func testCallEndBlocksEveryCompetingCommandUntilItsLockIsReleased() throws {
        let before = CommandFrame(active: false)
        let after = closedFrame()
        let harness = try MediaCommandHarness([before, before, before, after, after, before])
        harness.accessibility.onRead = { [unowned harness] in
            assertCommandError(.commandInProgress) { try TeamsCallCommands.end(environment: harness.environment) }
            for command in CommandUnderTest.allCases {
                assertCommandError(.commandInProgress) { try command.run(harness, target: false) }
            }
        }
        assertEnded(try TeamsCallCommands.end(environment: harness.environment), focus: true)
        XCTAssertEqual(harness.lifecycle.events.filter { $0 == "backend" }.count, 1)
        XCTAssertEqual(harness.accessibility.reads.count, 5)
        harness.assertFinalized()

        harness.accessibility.onRead = nil
        for command in CommandUnderTest.allCases {
            let result = try command.run(harness, target: false)
            XCTAssertTrue(result.success)
            XCTAssertFalse(result.attempted)
        }
        XCTAssertEqual(harness.lifecycle.events.filter { $0 == "backend" }.count, 4)
        XCTAssertEqual(harness.lifecycle.client.writes, Array(repeating: [true, false], count: 4).flatMap { $0 })
        XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
        harness.lifecycle.assertUnlocked()
    }

    func testEachMediaCommandBlocksCallEndAndAllowsItAfterRelease() throws {
        for command in CommandUnderTest.allCases {
            let before = CommandFrame(active: false)
            let harness = try MediaCommandHarness([before, before, before, before, closedFrame()])
            harness.accessibility.onRead = { [unowned harness] in
                assertCommandError(.commandInProgress) { try TeamsCallCommands.end(environment: harness.environment) }
            }
            let result = try command.run(harness, target: false)
            XCTAssertTrue(result.success)
            XCTAssertFalse(result.attempted)
            XCTAssertEqual(harness.lifecycle.events.filter { $0 == "backend" }.count, 1)
            harness.assertFinalized()

            harness.accessibility.onRead = nil
            assertEnded(try TeamsCallCommands.end(environment: harness.environment), focus: true)
            XCTAssertEqual(harness.lifecycle.events.filter { $0 == "backend" }.count, 2)
            XCTAssertEqual(harness.lifecycle.client.writes, [true, false, true, false])
            XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
            harness.lifecycle.assertUnlocked()
        }
    }

    func testSetupFailureRestoresAndStopsBeforeConstructingBackend() throws {
        for restored in [true, false] {
            let harness = try actionHarness()
            harness.lifecycle.client.waitResults = [.timedOut, restored ? .confirmed : .timedOut]
            assertCommandError(restored ? .accessibilitySetupUnavailable : .accessibilityCleanupFailed) {
                try TeamsCallCommands.end(environment: harness.environment)
            }
            XCTAssertFalse(harness.lifecycle.events.contains("backend"))
            XCTAssertTrue(harness.accessibility.reads.isEmpty)
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            harness.assertFinalized()
        }
    }

    func testInitialAndPreflightReadErrorsPropagateAfterCleanup() throws {
        for failedRead in [1, 2] {
            let harness = try actionHarness()
            harness.accessibility.readErrors[failedRead] = .accessibilityFailure(-25204)
            XCTAssertThrowsError(try TeamsCallCommands.end(environment: harness.environment)) { error in
                guard case TeamsReadError.accessibilityFailure(-25204) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(harness.accessibility.reads.count, failedRead)
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            XCTAssertEqual(harness.waits, 0)
            harness.assertFinalized()
        }
    }

    func testCleanupFailureOverridesReadErrorAndStillReleasesResources() throws {
        for failedRead in [1, 2] {
            let harness = try actionHarness()
            harness.accessibility.readErrors[failedRead] = .accessibilityFailure(-25204)
            configureFinalization(harness, restored: false, focus: nil)
            assertCommandError(.accessibilityCleanupFailed) { try TeamsCallCommands.end(environment: harness.environment) }
            XCTAssertEqual(harness.accessibility.reads.count, failedRead)
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            harness.assertFinalized()
        }
    }

    func testDispatchReadErrorIsFinalizedAsARefusalWithoutAPress() throws {
        let harness = try actionHarness()
        harness.accessibility.readErrors[3] = .accessibilityFailure(-25204)
        configureFinalization(harness, restored: true, focus: false)
        let result = try TeamsCallCommands.end(environment: harness.environment)
        assertFailure(result, reason: "preflight_failed", attempted: false, focus: false)
        assertActiveWindowDetails(result)
        XCTAssertEqual(harness.accessibility.reads.count, 3)
        XCTAssertTrue(harness.accessibility.pressed.isEmpty)
        XCTAssertEqual(harness.waits, 0)
        harness.assertFinalized()
    }

    func testUncertainPressIsNeverRetriedAndCleanupPreservesAttemptMetadata() throws {
        for restored in [true, false] {
            for focus: Bool? in [true, false, nil] {
                let harness = try actionHarness()
                harness.accessibility.pressError = .cannotComplete
                configureFinalization(harness, restored: restored, focus: focus)
                let result = try TeamsCallCommands.end(environment: harness.environment)
                assertFailure(result, reason: restored ? "action_outcome_unknown" : "accessibility_cleanup_failed",
                              attempted: true, focus: focus)
                assertActiveWindowDetails(result)
                XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
                XCTAssertEqual(harness.accessibility.reads.count, 3)
                XCTAssertEqual(harness.waits, 0)
                harness.assertFinalized()
            }
        }
    }

    func testCleanupFailureOverridesVerifiedClosureAndRetainsAttemptAndHeldWindows() throws {
        for focus: Bool? in [true, false, nil] {
            let harness = try actionHarness()
            configureFinalization(harness, restored: false, focus: focus)
            let result = try TeamsCallCommands.end(environment: harness.environment)
            assertFailure(result, reason: "accessibility_cleanup_failed", attempted: true, focus: focus)
            XCTAssertTrue(result.windows.isEmpty)
            XCTAssertEqual(result.excludedWindows, [.init(window: 12, reason: "on_hold")])
            XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
            XCTAssertEqual(harness.accessibility.reads.count, 5)
            XCTAssertEqual(harness.waits, 2)
            harness.assertFinalized()
        }
    }

    func testRefusalFinalizationKeepsChangedFalseAndReportsFinalFocus() throws {
        for restored in [true, false] {
            for focus: Bool? in [true, false, nil] {
                let harness = try MediaCommandHarness([CommandFrame(active: false, ready: false)])
                configureFinalization(harness, restored: restored, focus: focus)
                let result = try TeamsCallCommands.end(environment: harness.environment)
                assertFailure(result, reason: restored ? "control_unavailable" : "accessibility_cleanup_failed",
                              attempted: false, focus: focus)
                assertActiveWindowDetails(result)
                XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                XCTAssertEqual(harness.accessibility.reads.count, 2)
                XCTAssertEqual(harness.waits, 0)
                harness.assertFinalized()
            }
        }
    }

    func testVerificationReadFailureKeepsAttemptUncertainThroughCleanup() throws {
        for restored in [true, false] {
            let harness = try actionHarness()
            harness.accessibility.readErrors[4] = .accessibilityFailure(-25204)
            configureFinalization(harness, restored: restored, focus: false)
            let result = try TeamsCallCommands.end(environment: harness.environment)
            assertFailure(result, reason: restored ? "action_outcome_unknown" : "accessibility_cleanup_failed",
                          attempted: true, focus: false)
            assertActiveWindowDetails(result)
            XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
            XCTAssertEqual(harness.accessibility.reads.count, 4)
            XCTAssertEqual(harness.waits, 1)
            harness.assertFinalized()
        }
    }

    func testEmptyWindowListTimesOutWithoutConfirmingClosureOrRetryingPress() throws {
        let before = CommandFrame(active: false)
        let harness = try MediaCommandHarness([before, before, before, emptyFrame()])
        let result = try TeamsCallCommands.end(environment: harness.environment)
        assertFailure(result, reason: "verification_timeout", attempted: true, focus: true)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.excludedWindows.isEmpty)
        XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
        XCTAssertEqual(harness.accessibility.reads.count, 23)
        XCTAssertEqual(harness.waits, 20)
        harness.assertFinalized()
    }

    func testUnconfirmedReadResetsConsecutiveClosureEvidenceWithinTheCommand() throws {
        let before = CommandFrame(active: false)
        let after = closedFrame()
        let harness = try MediaCommandHarness([before, before, before, after, emptyFrame(), after, after])
        assertEnded(try TeamsCallCommands.end(environment: harness.environment), focus: true)
        XCTAssertEqual(harness.accessibility.pressed, [leaveButton])
        XCTAssertEqual(harness.accessibility.reads.count, 7)
        XCTAssertEqual(harness.waits, 4)
        harness.assertFinalized()
    }

    private var leaveButton: AXUIElement { AXUIElementCreateApplication(12) }

    private func actionHarness(held: Bool = true) throws -> MediaCommandHarness {
        let before = CommandFrame(active: false)
        return try MediaCommandHarness([before, before, before, closedFrame(held: held)])
    }

    /// The original call window disappears, while an inspectable window of the
    /// same process survives. It may contain a different call that is on hold.
    private func closedFrame(held: Bool = true) -> CommandFrame {
        var frame = CommandFrame(active: false)
        let controls = held ? frame.snapshot.windows[1].controls : []
        let handles = CallWindowHandles(application: .current, window: AXUIElementCreateApplication(20),
                                        hangups: held ? [AXUIElementCreateApplication(22)] : [])
        frame.snapshot = TeamsSnapshot(windows: [WindowSnapshot(index: 12, controls: controls)], complete: true,
                                       focusUnchanged: true, handles: [12: handles])
        frame.values = [:]
        return frame
    }

    private func emptyFrame() -> CommandFrame {
        var frame = CommandFrame(active: false)
        frame.snapshot = TeamsSnapshot(windows: [], complete: true, focusUnchanged: true)
        frame.values = [:]
        return frame
    }

    private func configureFinalization(_ harness: MediaCommandHarness, restored: Bool, focus: Bool?) {
        harness.lifecycle.client.waitResults = [.confirmed, restored ? .confirmed : .timedOut]
        let monitor = harness.lifecycle.focus
        harness.lifecycle.client.onWait = { expected in
            if !expected { monitor.result = focus }
        }
    }

    private func assertEnded(_ result: CallEndResult, focus: Bool?, held: Bool = true,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.success, file: file, line: line)
        XCTAssertEqual(result.state, .ended, file: file, line: line)
        XCTAssertNil(result.reason, file: file, line: line)
        XCTAssertTrue(result.actionAttempted, file: file, line: line)
        XCTAssertEqual(result.changed, true, file: file, line: line)
        XCTAssertEqual(result.focusUnchanged, focus, file: file, line: line)
        XCTAssertTrue(result.windows.isEmpty, file: file, line: line)
        XCTAssertEqual(result.excludedWindows, held ? [.init(window: 12, reason: "on_hold")] : [], file: file, line: line)
    }

    private func assertFailure(_ result: CallEndResult, reason: String, attempted: Bool, focus: Bool?,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, .unknown, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertEqual(result.actionAttempted, attempted, file: file, line: line)
        XCTAssertEqual(result.changed, attempted ? nil : false, file: file, line: line)
        XCTAssertEqual(result.focusUnchanged, focus, file: file, line: line)
    }

    private func assertActiveWindowDetails(_ result: CallEndResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.windows, [.init(window: 7, state: .active)], file: file, line: line)
        XCTAssertEqual(result.excludedWindows, [.init(window: 12, reason: "on_hold")], file: file, line: line)
    }
}
