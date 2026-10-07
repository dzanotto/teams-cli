import ApplicationServices
import XCTest
@testable import TeamsCore

final class MediaCommandFinalizationTests: XCTestCase {
    func testPermissionDenialPreventsBackendCreationForSetAndToggle() throws {
        for command in CommandUnderTest.allCases {
            for target: Bool? in [nil, true] {
                let harness = try MediaCommandHarness([CommandFrame(active: false)])
                harness.lifecycle.trusted = false
                XCTAssertThrowsError(try command.run(harness, target: target)) { error in
                    guard case TeamsReadError.accessibilityDenied = error else { return XCTFail("Unexpected error: \(error)") }
                }
                XCTAssertEqual(harness.lifecycle.events, ["permission"])
                XCTAssertTrue(harness.accessibility.reads.isEmpty)
                XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            }
        }
    }

    func testBusyLockPreventsExposureAndBackendCreationForEveryCommand() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            let held = try MediaCommandLock(path: harness.lifecycle.path)
            defer { held.release() }
            assertCommandError(.commandInProgress) { try command.run(harness) }
            XCTAssertEqual(harness.lifecycle.events, ["permission", "lock"])
            XCTAssertTrue(harness.lifecycle.client.writes.isEmpty)
            XCTAssertTrue(harness.accessibility.reads.isEmpty)
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
        }
    }

    func testAllControlsContendOnTheSameLifecycleLockAndCanRunAfterRelease() throws {
        let before = CommandFrame(active: false)
        let after = CommandFrame(active: true)
        let harness = try MediaCommandHarness([before, before, after, after])
        harness.accessibility.onRead = { [unowned harness] in
            for competing in CommandUnderTest.allCases {
                assertCommandError(.commandInProgress) { try competing.run(harness, target: true) }
            }
        }
        XCTAssertTrue(try CommandUnderTest.microphone.run(harness).success)
        XCTAssertEqual(harness.accessibility.pressed, [CommandUnderTest.microphone.button])
        XCTAssertEqual(harness.lifecycle.events.filter { $0 == "backend" }.count, 1)
        harness.accessibility.onRead = nil
        for command in CommandUnderTest.allCases {
            let result = try command.run(harness, target: true)
            XCTAssertTrue(result.success)
            XCTAssertFalse(result.attempted)
        }
        XCTAssertEqual(harness.accessibility.pressed.count, 1)
        harness.lifecycle.assertUnlocked()
    }

    func testSetupFailureRestoresAndStopsBeforeConstructingAnyBackend() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            harness.lifecycle.client.waitResults = [.timedOut, .confirmed]
            assertCommandError(.accessibilitySetupUnavailable) { try command.run(harness) }
            XCTAssertFalse(harness.lifecycle.events.contains("backend"))
            XCTAssertTrue(harness.accessibility.reads.isEmpty)
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            harness.assertFinalized()
        }
    }

    func testInitialAndPreflightReadErrorsPropagateAfterCleanup() throws {
        for command in CommandUnderTest.allCases {
            for failureRead in [1, 2] {
                let harness = try MediaCommandHarness([CommandFrame(active: false)])
                harness.accessibility.readErrors[failureRead] = .accessibilityFailure(-25204)
                XCTAssertThrowsError(try command.run(harness)) { error in
                    guard case TeamsReadError.accessibilityFailure(let code) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(code, -25204)
                }
                XCTAssertEqual(harness.accessibility.reads.count, failureRead)
                XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                harness.assertFinalized()
            }
        }
    }

    func testCleanupFailureOverridesReadErrorAndStillReleasesTheLock() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            harness.accessibility.readErrors[1] = .accessibilityFailure(-25204)
            harness.lifecycle.client.waitResults = [.confirmed, .timedOut]
            assertCommandError(.accessibilityCleanupFailed) { try command.run(harness) }
            XCTAssertEqual(harness.accessibility.reads.count, 1)
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            harness.assertFinalized()
        }
    }

    func testCleanupFailureAfterVerifiedChangePreservesAttemptAndMakesChangeUnknown() throws {
        for command in CommandUnderTest.allCases {
            for finalFocus: Bool? in [true, false, nil] {
                let harness = try actionHarness()
                configureFinalization(harness, restored: false, focus: finalFocus)
                let result = try command.run(harness, target: true)
                assertFinalFailure(result, reason: "accessibility_cleanup_failed", attempted: true, focus: finalFocus)
                assertWindowDetails(result, state: command.state(active: true))
                XCTAssertEqual(harness.accessibility.pressed, [command.button])
                XCTAssertEqual(harness.accessibility.reads.count, 4)
                harness.assertFinalized()
            }
        }
    }

    func testPostCleanupFocusFailureAfterVerifiedTogglePreservesAttemptMetadata() throws {
        for command in CommandUnderTest.allCases {
            for finalFocus: Bool? in [false, nil] {
                let harness = try actionHarness()
                configureFinalization(harness, restored: true, focus: finalFocus)
                let result = try command.run(harness)
                assertFinalFailure(result, reason: finalFocus == nil ? "focus_unavailable" : "focus_changed",
                                   attempted: true, focus: finalFocus)
                assertWindowDetails(result, state: command.state(active: true))
                XCTAssertEqual(harness.accessibility.pressed, [command.button])
                XCTAssertEqual(harness.accessibility.reads.count, 4)
                harness.assertFinalized()
            }
        }
    }

    func testFinalizationFailureAfterNoOpKeepsChangedAndAttemptedFalse() throws {
        for command in CommandUnderTest.allCases {
            for restored in [true, false] {
                for finalFocus: Bool? in [true, false, nil] where !restored || finalFocus != true {
                    let harness = try MediaCommandHarness([CommandFrame(active: true, ready: false)])
                    configureFinalization(harness, restored: restored, focus: finalFocus)
                    let result = try command.run(harness, target: true)
                    let focusReason = finalFocus == nil ? "focus_unavailable" : "focus_changed"
                    assertFinalFailure(result, reason: restored ? focusReason : "accessibility_cleanup_failed",
                                       attempted: false, focus: finalFocus)
                    assertWindowDetails(result, state: command.state(active: true))
                    XCTAssertEqual(harness.accessibility.reads.count, 1)
                    XCTAssertTrue(harness.accessibility.pressed.isEmpty)
                    harness.assertFinalized()
                }
            }
        }
    }

    func testCleanupFailureAfterRefusalPreservesObservedWindowState() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false, ready: false)])
            configureFinalization(harness, restored: false, focus: true)
            let result = try command.run(harness)
            assertFinalFailure(result, reason: "accessibility_cleanup_failed", attempted: false, focus: true)
            assertWindowDetails(result, state: command.state(active: false))
            XCTAssertTrue(harness.accessibility.pressed.isEmpty)
            harness.assertFinalized()
        }
    }

    func testCleanupFailureAfterUncertainPressNeverErasesAttemptOrRetries() throws {
        for command in CommandUnderTest.allCases {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            harness.accessibility.pressError = .cannotComplete
            configureFinalization(harness, restored: false, focus: nil)
            let result = try command.run(harness)
            assertFinalFailure(result, reason: "accessibility_cleanup_failed", attempted: true, focus: nil)
            assertWindowDetails(result, state: command.state(active: false))
            XCTAssertEqual(harness.accessibility.pressed, [command.button])
            XCTAssertEqual(harness.accessibility.reads.count, 2)
            XCTAssertEqual(harness.waits, 0)
            harness.assertFinalized()
        }
    }

    private func actionHarness() throws -> MediaCommandHarness {
        let before = CommandFrame(active: false)
        let after = CommandFrame(active: true)
        return try MediaCommandHarness([before, before, after, after])
    }

    private func configureFinalization(_ harness: MediaCommandHarness, restored: Bool, focus: Bool?) {
        harness.lifecycle.client.waitResults = [.confirmed, restored ? .confirmed : .timedOut]
        let monitor = harness.lifecycle.focus
        harness.lifecycle.client.onWait = { [unowned monitor] expected in
            // The operation sees preserved focus; only the final cleanup readback changes it.
            if !expected { monitor.result = focus }
        }
    }

    private func assertFinalFailure(_ result: CommandTestResult, reason: String, attempted: Bool, focus: Bool?,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, "unknown", file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
        XCTAssertEqual(result.attempted, attempted, file: file, line: line)
        XCTAssertEqual(result.changed, attempted ? nil : false, file: file, line: line)
        XCTAssertEqual(result.focus, focus, file: file, line: line)
    }

    private func assertWindowDetails(_ result: CommandTestResult, state: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.indices, [7], file: file, line: line)
        XCTAssertEqual(result.states, [state], file: file, line: line)
        XCTAssertEqual(result.excluded, [.init(window: 12, reason: "on_hold")], file: file, line: line)
    }
}
