import XCTest
@testable import TeamsCore

final class TeamsAccessibilityExposureTests: XCTestCase {
    func testAlreadyEnabledExposureNeverWritesIncludingRestorationAndDeinit() throws {
        let client = ScriptedExposureClient()
        client.value = true
        var exposure: TeamsAccessibilityExposure? = try TeamsAccessibilityExposure(client: client)
        XCTAssertTrue(exposure!.restore())
        XCTAssertTrue(exposure!.restore())
        exposure = nil
        XCTAssertTrue(client.writes.isEmpty)
        XCTAssertEqual(client.readCount, 1)
    }

    func testMissingOriginalValueOrGenerationCannotEnableExposure() {
        for failure in ["value", "gone", "unknown"] {
            let client = ScriptedExposureClient()
            if failure == "value" { client.value = nil }
            if failure == "gone" { client.generation = false }
            if failure == "unknown" { client.generation = nil }
            assertCommandError(.accessibilitySetupUnavailable) {
                try TeamsAccessibilityExposure(client: client)
            }
            XCTAssertTrue(client.writes.isEmpty)
        }
    }

    func testSuccessfulSetupRestoresOriginalValueAndCachesSuccessThroughDeinit() throws {
        let client = ScriptedExposureClient()
        var exposure: TeamsAccessibilityExposure? = try TeamsAccessibilityExposure(client: client)
        XCTAssertEqual(client.value, true)
        XCTAssertTrue(exposure!.restore())
        XCTAssertEqual(client.value, false)
        let reads = client.readCount
        // A later external change must not trigger another cleanup write.
        client.value = true
        XCTAssertTrue(exposure!.restore())
        exposure = nil
        XCTAssertEqual(client.readCount, reads)
        XCTAssertEqual(client.writes, [true, false])
    }

    func testSetupWriteThatDoesNotApplyFailsWithoutRedundantRestorationWrite() {
        let client = ScriptedExposureClient()
        client.applyWrites = false
        assertCommandError(.accessibilitySetupUnavailable) {
            try TeamsAccessibilityExposure(client: client)
        }
        XCTAssertEqual(client.writes, [true])
        XCTAssertEqual(client.value, false)
    }

    func testUnconfirmedSetupRestoresBeforeThrowing() {
        for setupResult in [AccessibilityExposureReadiness.Result.timedOut, .unavailable] {
            let client = ScriptedExposureClient()
            client.waitResults = [setupResult, .confirmed]
            assertCommandError(.accessibilitySetupUnavailable) {
                try TeamsAccessibilityExposure(client: client)
            }
            XCTAssertEqual(client.writes, [true, false])
            XCTAssertEqual(client.value, false)
        }
    }

    func testProcessDisappearingDuringSetupDoesNotReceiveRestorationWrite() {
        let client = ScriptedExposureClient()
        client.waitResults = [.processGone]
        client.onWait = { [weak client] _ in client?.generation = false }
        assertCommandError(.accessibilitySetupUnavailable) {
            try TeamsAccessibilityExposure(client: client)
        }
        XCTAssertEqual(client.writes, [true])
        XCTAssertEqual(client.readCount, 1)
    }

    func testSetupCleanupFailureTakesPrecedenceAndIsNotRetriedByDeinit() {
        let client = ScriptedExposureClient()
        client.waitResults = [.timedOut, .timedOut]
        assertCommandError(.accessibilityCleanupFailed) {
            try TeamsAccessibilityExposure(client: client)
        }
        XCTAssertEqual(client.writes, [true, false])
    }

    func testAlreadyRestoredValueDoesNotNeedAnotherWrite() throws {
        let client = ScriptedExposureClient()
        let exposure = try TeamsAccessibilityExposure(client: client)
        client.value = false
        XCTAssertTrue(exposure.restore())
        XCTAssertEqual(client.writes, [true])
    }

    func testGoneOrUnknownProcessPreventsCleanupReadsAndWrites() throws {
        for generation: Bool? in [false, nil] {
            let client = ScriptedExposureClient()
            let exposure = try TeamsAccessibilityExposure(client: client)
            let reads = client.readCount
            client.generation = generation
            XCTAssertEqual(exposure.restore(), generation == false)
            XCTAssertEqual(client.readCount, reads)
            XCTAssertEqual(client.writes, [true])
        }
    }

    func testProcessReplacementOrLostGenerationDuringReadPreventsCleanupWrite() throws {
        for generation: Bool? in [false, nil] {
            let client = ScriptedExposureClient()
            let exposure = try TeamsAccessibilityExposure(client: client)
            client.onRead = { [weak client] in client?.generation = generation }
            XCTAssertEqual(exposure.restore(), generation == false)
            XCTAssertEqual(client.writes, [true])
        }
    }

    func testCleanupReadbackDeterminesResultAndCachesFailureAsWellAsSuccess() throws {
        for outcome in [AccessibilityExposureReadiness.Result.confirmed, .processGone, .unavailable, .timedOut] {
            let client = ScriptedExposureClient()
            var exposure: TeamsAccessibilityExposure? = try TeamsAccessibilityExposure(client: client)
            client.waitResults = [outcome]
            let expected = outcome == .confirmed || outcome == .processGone
            XCTAssertEqual(exposure!.restore(), expected)
            let reads = client.readCount
            XCTAssertEqual(exposure!.restore(), expected)
            exposure = nil
            XCTAssertEqual(client.readCount, reads)
            XCTAssertEqual(client.writes, [true, false])
        }
    }

    func testUnavailableCleanupReadStillAttemptsRestorationForSameProcess() throws {
        let client = ScriptedExposureClient()
        let exposure = try TeamsAccessibilityExposure(client: client)
        client.value = nil
        XCTAssertTrue(exposure.restore())
        XCTAssertEqual(client.writes, [true, false])
    }

    func testDeinitRestoresWhenCallerDoesNotFinalize() throws {
        let client = ScriptedExposureClient()
        var exposure: TeamsAccessibilityExposure? = try TeamsAccessibilityExposure(client: client)
        XCTAssertNotNil(exposure)
        XCTAssertEqual(client.writes, [true])
        exposure = nil
        XCTAssertEqual(client.writes, [true, false])
        XCTAssertEqual(client.value, false)
    }
}
