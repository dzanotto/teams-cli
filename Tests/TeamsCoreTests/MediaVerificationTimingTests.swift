import XCTest
@testable import TeamsCore

final class MediaVerificationTimingTests: XCTestCase {
    func testFastToggleAndSetStillRequireTwoFullConfirmationsWith50MillisecondWaits() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            for target: Bool? in [nil, false, true] {
                let requested = target ?? true
                let before = CommandFrame(active: !requested)
                let after = CommandFrame(active: requested)
                let harness = try MediaCommandHarness([before, before, after, after])
                let result = try command.run(harness, target: target)
                XCTAssertTrue(result.success)
                XCTAssertEqual(result.state, command.state(active: requested))
                XCTAssertEqual(harness.waitDurations, [0.05, 0.05])
                XCTAssertEqual(harness.accessibility.reads.count, 4)
                XCTAssertEqual(harness.accessibility.readsAtPress, 2)
                XCTAssertEqual(harness.accessibility.pressed, [command.button])
                harness.assertFinalized()
            }
        }
    }

    func testSlowTransitionsCanUseRemainingCommandTimeBeyondOldAttemptLimits() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            let before = CommandFrame(active: false)
            let after = CommandFrame(active: true)
            let harness = try MediaCommandHarness([before, before, before])
            let client = harness.accessibility
            client.onRead = { [unowned client] in
                // Include real discovery cost in the virtual clock. A late camera
                // label change is insufficient until the same button is ready.
                client.uptime += 0.1
                if client.reads.count > 2 {
                    if client.uptime >= 106.5 {
                        client.frames[2] = after
                    } else if command == .camera && client.uptime >= 103 {
                        client.frames[2] = CommandFrame(active: true, ready: false)
                    }
                }
            }
            let result = try command.run(harness)
            XCTAssertTrue(result.success)
            XCTAssertGreaterThan(harness.waits, 20)
            XCTAssertGreaterThan(client.uptime, 106.5)
            XCTAssertLessThan(client.uptime, 108)
            XCTAssertEqual(client.pressed, [command.button])
            XCTAssertTrue(harness.waitDurations.allSatisfy { $0 == 0.05 })
            harness.assertFinalized()
        }
    }

    func testFinalWaitIsCappedAndDoesNotStartAReadAtOrAfterDeadline() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            for overshoot in [0.0, 0.1] {
                let harness = try MediaCommandHarness([CommandFrame(active: false)])
                let client = harness.accessibility
                client.onPress = { [unowned client] in client.uptime = 107.98 }
                harness.onWait = { _ in client.uptime += overshoot }
                assertTimeout(try command.run(harness))
                XCTAssertEqual(harness.waits, 1)
                XCTAssertEqual(try XCTUnwrap(harness.waitDurations.first), 0.02, accuracy: 0.000_001)
                XCTAssertEqual(client.reads.count, 2)
                XCTAssertEqual(client.pressed, [command.button])
                harness.assertFinalized()
            }
        }
    }

    func testFocusChangeDuringFinalWaitTakesPrecedenceOverTimeout() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            let client = harness.accessibility
            let focus = harness.lifecycle.focus
            client.onPress = { [unowned client] in client.uptime = 107.98 }
            harness.onWait = { _ in focus.result = false }
            let result = try command.run(harness)
            XCTAssertFalse(result.success)
            XCTAssertEqual(result.reason, "focus_changed")
            XCTAssertTrue(result.attempted)
            XCTAssertNil(result.changed)
            XCTAssertEqual(client.reads.count, 2)
            XCTAssertEqual(client.pressed, [command.button])
            harness.assertFinalized()
        }
    }

    func testReadReturningSecondMatchAtOrBeyondDeadlineCannotConfirmSuccess() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            for returnedAt in [108.0, 108.2] {
                let before = CommandFrame(active: false)
                let after = CommandFrame(active: true)
                let harness = try MediaCommandHarness([before, before, after, after])
                let client = harness.accessibility
                client.onRead = { [unowned client] in
                    if client.reads.count == 4 { client.uptime = returnedAt }
                }
                assertTimeout(try command.run(harness))
                XCTAssertEqual(client.reads.count, 4)
                XCTAssertEqual(harness.waitDurations, [0.05, 0.05])
                XCTAssertEqual(client.pressed, [command.button])
                harness.assertFinalized()
            }
        }
    }

    func testDiscoveryAndDispatchConsumeTheSameBudgetAsVerification() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            let client = harness.accessibility
            client.onRead = { [unowned client] in
                if client.reads.count <= 2 { client.uptime += 3.9 }
            }
            assertTimeout(try command.run(harness))
            XCTAssertEqual(client.uptime, 108, accuracy: 0.000_001)
            XCTAssertLessThanOrEqual(harness.waits, 5)
            XCTAssertEqual(harness.waitDurations.reduce(0, +), 0.2, accuracy: 0.000_001)
            XCTAssertTrue(client.reads.dropFirst(2).allSatisfy { $0.timeout > 0 && $0.timeout < 0.2 })
            XCTAssertEqual(client.pressed, [command.button])
            harness.assertFinalized()
        }
    }

    func testNoVerificationReadStartsIfPressConsumesRemainingBudget() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            let harness = try MediaCommandHarness([CommandFrame(active: false)])
            let client = harness.accessibility
            client.onPress = { [unowned client] in client.uptime = 108 }
            assertTimeout(try command.run(harness))
            XCTAssertTrue(harness.waitDurations.isEmpty)
            XCTAssertEqual(client.reads.count, 2)
            XCTAssertEqual(client.pressed, [command.button])
            harness.assertFinalized()
        }
    }

    func testTwoMatchesJustBeforeDeadlineStillSucceedWithCappedReadTimeouts() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            let before = CommandFrame(active: false)
            let after = CommandFrame(active: true)
            let harness = try MediaCommandHarness([before, before, after, after])
            let client = harness.accessibility
            client.onPress = { [unowned client] in client.uptime = 107.85 }
            XCTAssertTrue(try command.run(harness).success)
            XCTAssertEqual(client.uptime, 107.95, accuracy: 0.000_001)
            let verification = Array(client.reads.dropFirst(2))
            XCTAssertEqual(verification.count, 2)
            XCTAssertEqual(verification[0].timeout, 0.1, accuracy: 0.000_001)
            XCTAssertEqual(verification[1].timeout, 0.05, accuracy: 0.000_001)
            XCTAssertEqual(client.pressed, [command.button])
            harness.assertFinalized()
        }
    }

    func testHandRetains150MillisecondWaitsAndEightSamples() throws {
        let before = CommandFrame(active: false)
        let after = CommandFrame(active: true)
        let success = try MediaCommandHarness([before, before, after, after])
        XCTAssertTrue(try CommandUnderTest.hand.run(success).success)
        XCTAssertEqual(success.waitDurations, [0.15, 0.15])
        let timeout = try MediaCommandHarness([before])
        assertTimeout(try CommandUnderTest.hand.run(timeout))
        XCTAssertEqual(timeout.waitDurations, Array(repeating: 0.15, count: 8))
    }

    private func assertTimeout(_ result: CommandTestResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, "unknown", file: file, line: line)
        XCTAssertEqual(result.reason, "verification_timeout", file: file, line: line)
        XCTAssertTrue(result.attempted, file: file, line: line)
        XCTAssertNil(result.changed, file: file, line: line)
    }
}
