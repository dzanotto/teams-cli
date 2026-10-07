import XCTest
@testable import TeamsCore

final class TeamsMediaCommandSupportTests: XCTestCase {
    func testPermissionDenialDoesNotAcquireLockOrStartSetup() throws {
        let harness = try CommandLifecycleHarness()
        harness.trusted = false
        XCTAssertThrowsError(try harness.perform()) { error in
            guard case TeamsReadError.accessibilityDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(harness.events, ["permission"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.path))
    }

    func testBusyLockPreventsFocusSetupAndOperation() throws {
        let harness = try CommandLifecycleHarness()
        let held = try MediaCommandLock(path: harness.path)
        defer { held.release() }
        assertCommandError(.commandInProgress) { try harness.perform() }
        XCTAssertEqual(harness.events, ["permission", "lock"])
        XCTAssertTrue(harness.client.writes.isEmpty)
    }

    func testUnavailableLockPreventsFocusSetupAndOperation() throws {
        let harness = try CommandLifecycleHarness()
        try FileManager.default.createDirectory(atPath: harness.path, withIntermediateDirectories: false)
        assertCommandError(.lockUnavailable) { try harness.perform() }
        XCTAssertEqual(harness.events, ["permission", "lock"])
        XCTAssertTrue(harness.client.writes.isEmpty)
    }

    func testSuccessRestoresBeforeFinalFocusAndHoldsLockThroughFinalizationAndStop() throws {
        let harness = try CommandLifecycleHarness()
        harness.focus.onStop = { harness.assertLocked() }
        let result = try TeamsMediaCommandSupport.perform({ focus in
            XCTAssertTrue(focus === harness.focus)
            harness.events.append("operation")
            harness.assertLocked()
            return 42
        }, environment: harness.environment, onFinalization: { result, restored, focus in
            harness.events.append("finalize")
            harness.assertLocked()
            XCTAssertEqual(harness.client.value, false)
            XCTAssertTrue(restored)
            XCTAssertEqual(focus, true)
            return result
        })
        harness.focus.onStop = nil
        XCTAssertEqual(result, 42)
        XCTAssertEqual(harness.events, [
            "permission", "lock", "focus.start", "expose", "read", "write true", "verify true",
            "operation", "read", "write false", "verify false", "focus.read", "finalize", "focus.stop"
        ])
        harness.assertUnlocked()
    }

    func testSetupFailuresDrainFocusStopMonitoringAndReleaseLockWithoutActing() throws {
        for cleanupFails in [false, true] {
            let harness = try CommandLifecycleHarness()
            harness.client.waitResults = [.timedOut, cleanupFails ? .timedOut : .confirmed]
            assertCommandError(cleanupFails ? .accessibilityCleanupFailed : .accessibilitySetupUnavailable) {
                try harness.perform()
            }
            XCTAssertEqual(harness.events, [
                "permission", "lock", "focus.start", "expose", "read", "write true", "verify true",
                "read", "write false", "verify false", "focus.read", "focus.stop"
            ])
            XCTAssertEqual(harness.client.writes, [true, false])
            harness.assertUnlocked()
        }
    }

    func testUnavailableSetupDoesNotWriteOrRunOperation() throws {
        let harness = try CommandLifecycleHarness()
        harness.client.value = nil
        assertCommandError(.accessibilitySetupUnavailable) { try harness.perform() }
        XCTAssertEqual(harness.events, [
            "permission", "lock", "focus.start", "expose", "read", "focus.read", "focus.stop"
        ])
        XCTAssertTrue(harness.client.writes.isEmpty)
        harness.assertUnlocked()
    }

    func testOperationErrorIsRethrownAfterCleanupAndFinalFocus() throws {
        let harness = try CommandLifecycleHarness()
        harness.operationError = true
        XCTAssertThrowsError(try harness.perform()) { error in
            guard case CommandLifecycleHarness.Failure.operation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(Array(harness.events.suffix(6)), [
            "operation", "read", "write false", "verify false", "focus.read", "focus.stop"
        ])
        XCTAssertEqual(harness.client.writes, [true, false])
        harness.assertUnlocked()
    }

    func testCleanupFailureOverridesOperationErrorWithoutRetryingEither() throws {
        let harness = try CommandLifecycleHarness()
        harness.operationError = true
        harness.client.waitResults = [.confirmed, .timedOut]
        assertCommandError(.accessibilityCleanupFailed) { try harness.perform() }
        XCTAssertEqual(harness.events.filter { $0 == "operation" }.count, 1)
        XCTAssertEqual(harness.client.writes, [true, false])
        XCTAssertEqual(Array(harness.events.suffix(2)), ["focus.read", "focus.stop"])
        harness.assertUnlocked()
    }

    func testStrictFinalizationUsesPostCleanupFocusAndPrioritizesCleanupFailure() throws {
        for restored in [true, false] {
            for finalFocus: Bool? in [true, false, nil] {
                let harness = try CommandLifecycleHarness()
                harness.client.waitResults = [.confirmed, restored ? .confirmed : .timedOut]
                harness.client.onWrite = { value in
                    if !value { harness.focus.result = finalFocus }
                }
                var failures: [String] = []
                let result = try TeamsMediaCommandSupport.perform({ _ in
                    harness.events.append("operation")
                    XCTAssertEqual(harness.focus.result, true)
                    return 42
                }, environment: harness.environment, onFinalizationFailure: { result, reason, focus in
                    XCTAssertEqual(result, 42)
                    XCTAssertEqual(focus, finalFocus)
                    failures.append(reason)
                    return -1
                })
                harness.client.onWrite = nil
                let expectedReason: String? = !restored ? "accessibility_cleanup_failed" :
                    (finalFocus == true ? nil : (finalFocus == nil ? "focus_unavailable" : "focus_changed"))
                XCTAssertEqual(failures, expectedReason.map { [$0] } ?? [])
                XCTAssertEqual(result, expectedReason == nil ? 42 : -1)
                XCTAssertEqual(harness.client.writes, [true, false])
                harness.assertUnlocked()
            }
        }
    }

    func testCleanupFailurePassesAttemptedActionUnchangedToFailureFinalizer() throws {
        for attempted in [true, false] {
            let harness = try CommandLifecycleHarness()
            harness.client.waitResults = [.confirmed, .timedOut]
            var finalizations = 0
            let result = try TeamsMediaCommandSupport.perform({ _ in
                harness.events.append("operation")
                return MicrophoneActionResult(state: .muted, reason: nil, changed: attempted,
                                             actionAttempted: attempted, focusUnchanged: true,
                                             windows: [], excludedWindows: [], success: true)
            }, environment: harness.environment, onFinalizationFailure: { result, reason, focus in
                finalizations += 1
                XCTAssertEqual(result.actionAttempted, attempted)
                XCTAssertEqual(result.changed, attempted)
                XCTAssertEqual(reason, "accessibility_cleanup_failed")
                XCTAssertEqual(focus, true)
                return result
            })
            XCTAssertEqual(result.actionAttempted, attempted)
            XCTAssertEqual(finalizations, 1)
            XCTAssertEqual(harness.events.filter { $0 == "operation" }.count, 1)
            XCTAssertEqual(harness.client.writes, [true, false])
            harness.assertUnlocked()
        }
    }

    func testCallEndFinalizationAllowsFocusChangesButStillRequiresRestoration() throws {
        for restored in [true, false] {
            for focus: Bool? in [true, false, nil] {
                let harness = try CommandLifecycleHarness()
                harness.focus.result = focus
                harness.client.waitResults = [.confirmed, restored ? .confirmed : .timedOut]
                let result = try TeamsMediaCommandSupport.perform({ _ in
                    CallEndResult(state: .ended, reason: nil, changed: true, actionAttempted: true,
                                  focusUnchanged: true, windows: [], excludedWindows: [], success: true)
                }, environment: harness.environment, onFinalization: { result, restored, focus in
                    result.finalized(restored: restored, focus: focus)
                })
                XCTAssertEqual(result.success, restored)
                XCTAssertEqual(result.state, restored ? .ended : .unknown)
                XCTAssertEqual(result.focusUnchanged, focus)
                XCTAssertTrue(result.actionAttempted)
                XCTAssertEqual(result.changed, restored ? true : nil)
                harness.assertUnlocked()
            }
        }
    }

    func testSecondCommandCannotEnterWhileFirstIsRunningAndCanEnterAfterward() throws {
        let harness = try CommandLifecycleHarness()
        let result = try TeamsMediaCommandSupport.perform({ _ in
            assertCommandError(.commandInProgress) { try harness.perform() }
            return 42
        }, environment: harness.environment, onFinalization: { result, _, _ in result })
        XCTAssertEqual(result, 42)
        XCTAssertFalse(harness.events.contains("operation"))
        XCTAssertEqual(try harness.perform(), 42)
        XCTAssertEqual(harness.events.filter { $0 == "operation" }.count, 1)
        XCTAssertEqual(harness.client.writes, [true, false, true, false])
    }
}

private final class LifecycleFocus: MediaCommandFocus {
    var result: Bool? = true
    var record: (String) -> Void = { _ in }
    var onStop: (() -> Void)?

    func preserved() -> Bool? {
        record("focus.read")
        return result
    }

    func stop() {
        record("focus.stop")
        onStop?()
    }
}

private final class CommandLifecycleHarness {
    enum Failure: Error { case operation }
    let directory: URL
    var path: String { directory.appendingPathComponent("command.lock").path }
    let client = ScriptedExposureClient()
    let focus = LifecycleFocus()
    var trusted = true
    var operationError = false
    var events: [String] = []

    init() throws {
        directory = try temporaryCommandDirectory()
        client.record = { [weak self] in self?.events.append($0) }
        focus.record = { [weak self] in self?.events.append($0) }
    }

    var environment: MediaCommandEnvironment<LifecycleFocus> {
        MediaCommandEnvironment(isTrusted: {
            self.events.append("permission")
            return self.trusted
        }, acquireLock: {
            self.events.append("lock")
            return try MediaCommandLock(path: self.path)
        }, makeFocus: {
            self.events.append("focus.start")
            return self.focus
        }, makeExposure: {
            self.events.append("expose")
            return try TeamsAccessibilityExposure(client: self.client)
        })
    }

    func perform() throws -> Int {
        try TeamsMediaCommandSupport.perform({ _ in
            self.events.append("operation")
            if self.operationError { throw Failure.operation }
            return 42
        }, environment: environment, onFinalization: { result, _, _ in
            self.events.append("finalize")
            return result
        })
    }

    func assertLocked(file: StaticString = #filePath, line: UInt = #line) {
        assertCommandError(.commandInProgress, file: file, line: line) { try MediaCommandLock(path: path) }
    }

    func assertUnlocked(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try MediaCommandLock(path: path).release(), file: file, line: line)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
