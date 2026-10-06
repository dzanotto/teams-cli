import XCTest
@testable import TeamsCore

final class AccessibilityExposureReadinessTests: XCTestCase {
    func testAlreadyMatchingValueReturnsWithoutWaitingForSetupAndCleanup() {
        for expected in [true, false] {
            let backend = FakeExposureReadiness(values: [expected])
            XCTAssertEqual(backend.poller.waitFor(expected), .confirmed)
            XCTAssertEqual(backend.readTimes, [0])
            XCTAssertTrue(backend.waits.isEmpty)
        }
    }

    func testDelayedReadbackReturnsAsSoonAsItMatchesInEitherDirection() {
        for expected in [true, false] {
            let backend = FakeExposureReadiness(values: [!expected, !expected, expected])
            XCTAssertEqual(backend.poller.waitFor(expected), .confirmed)
            XCTAssertEqual(backend.time, 0.05, accuracy: 0.000_001)
            XCTAssertEqual(backend.waits, [0.025, 0.025])
        }
    }

    func testTransientUnavailableReadCanRecoverWithinBudget() {
        let backend = FakeExposureReadiness(values: [nil, true])
        XCTAssertEqual(backend.poller.waitFor(true), .confirmed)
        XCTAssertEqual(backend.time, 0.025, accuracy: 0.000_001)
    }

    func testWrongOrUnavailableReadbackTimesOutWithinBudget() {
        for value: Bool? in [false, nil] {
            let backend = FakeExposureReadiness(values: [value])
            XCTAssertEqual(backend.poller.waitFor(true), .timedOut)
            XCTAssertEqual(backend.time, 0.4, accuracy: 0.000_001)
            XCTAssertTrue(backend.readTimes.allSatisfy { $0 < 0.4 })
            XCTAssertTrue(backend.waits.allSatisfy { $0 > 0 && $0 <= 0.025 })
        }
    }

    func testProcessGoneIsDistinctFromConfirmedAndDoesNotRead() {
        let backend = FakeExposureReadiness(values: [true])
        backend.sameGeneration = false
        XCTAssertEqual(backend.poller.waitFor(true), .processGone)
        XCTAssertTrue(backend.readTimes.isEmpty)
        XCTAssertTrue(backend.waits.isEmpty)
    }

    func testUnknownGenerationFailsWithoutReading() {
        let backend = FakeExposureReadiness(values: [true])
        backend.sameGeneration = nil
        XCTAssertEqual(backend.poller.waitFor(true), .unavailable)
        XCTAssertTrue(backend.readTimes.isEmpty)
        XCTAssertTrue(backend.waits.isEmpty)
    }

    func testProcessReplacementDuringReadCannotConfirmTheOldProcess() {
        let backend = FakeExposureReadiness(values: [true])
        backend.afterRead = { [unowned backend] in backend.sameGeneration = false }
        XCTAssertEqual(backend.poller.waitFor(true), .processGone)
        XCTAssertTrue(backend.waits.isEmpty)
    }

    func testLostGenerationEvidenceDuringReadCannotConfirmReadiness() {
        let backend = FakeExposureReadiness(values: [true])
        backend.afterRead = { [unowned backend] in backend.sameGeneration = nil }
        XCTAssertEqual(backend.poller.waitFor(true), .unavailable)
        XCTAssertTrue(backend.waits.isEmpty)
    }

    func testProcessReplacementWhileWaitingStopsFurtherReads() {
        let backend = FakeExposureReadiness(values: [false, true])
        backend.afterWait = { [unowned backend] in backend.sameGeneration = false }
        XCTAssertEqual(backend.poller.waitFor(true), .processGone)
        XCTAssertEqual(backend.readTimes.count, 1)
    }

    func testReadTimeoutUsesRemainingBudgetAndWaitIsClippedAtDeadline() {
        let backend = FakeExposureReadiness(values: [false])
        backend.readDuration = 0.18
        XCTAssertEqual(backend.poller.waitFor(true), .timedOut)
        XCTAssertEqual(backend.readTimeouts.count, 2)
        XCTAssertEqual(backend.readTimeouts[0], 0.25, accuracy: 0.000_001)
        XCTAssertEqual(backend.readTimeouts[1], 0.195, accuracy: 0.000_001)
        XCTAssertEqual(backend.waits.last!, 0.015, accuracy: 0.000_001)
        XCTAssertEqual(backend.time, 0.4, accuracy: 0.000_001)
    }

    func testSlowReadCannotConfirmReadinessAfterDeadline() {
        let backend = FakeExposureReadiness(values: [true])
        backend.readDuration = 0.5
        XCTAssertEqual(backend.poller.waitFor(true), .timedOut)
        XCTAssertEqual(backend.readTimes.count, 1)
        XCTAssertTrue(backend.waits.isEmpty)
    }

    func testRunLoopOvershootDoesNotStartAnotherRead() {
        let backend = FakeExposureReadiness(values: [false, true])
        backend.waitOvershoot = 0.5
        XCTAssertEqual(backend.poller.waitFor(true), .timedOut)
        XCTAssertEqual(backend.readTimes.count, 1)
    }

    func testGenerationChecksAreIncludedInTheDeadline() {
        let backend = FakeExposureReadiness(values: [true])
        backend.generationCheckDuration = 0.21
        XCTAssertEqual(backend.poller.waitFor(true), .timedOut)
        XCTAssertEqual(backend.readTimeouts[0], 0.19, accuracy: 0.000_001)
        XCTAssertTrue(backend.waits.isEmpty)
    }
}

/// Virtual time and scripted AX readback; these tests never contact Teams.
private final class FakeExposureReadiness {
    var values: [Bool?]
    var sameGeneration: Bool? = true
    var time: TimeInterval = 0
    var readDuration: TimeInterval = 0
    var generationCheckDuration: TimeInterval = 0
    var waitOvershoot: TimeInterval = 0
    var readTimes: [TimeInterval] = []
    var readTimeouts: [TimeInterval] = []
    var waits: [TimeInterval] = []
    var afterRead: (() -> Void)?
    var afterWait: (() -> Void)?

    init(values: [Bool?]) { self.values = values }

    var poller: AccessibilityExposureReadiness {
        AccessibilityExposureReadiness(sameGeneration: {
            self.time += self.generationCheckDuration
            return self.sameGeneration
        }, read: { timeout in
            self.readTimes.append(self.time)
            self.readTimeouts.append(timeout)
            self.time += self.readDuration
            let value = self.values.count > 1 ? self.values.removeFirst() : self.values[0]
            self.afterRead?()
            return value
        }, now: { self.time }, wait: { duration in
            self.waits.append(duration)
            self.time += duration + self.waitOvershoot
            self.afterWait?()
        })
    }
}
