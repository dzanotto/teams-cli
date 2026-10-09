import ApplicationServices
import XCTest
@testable import TeamsCore

final class CommandTimingsTests: XCTestCase {
    enum Failure: Error { case expected }

    func testNestedSpansUseMonotonicClockAndCloseAfterThrow() throws {
        var now: TimeInterval = 10
        let timings = CommandTimings(clock: { now })
        XCTAssertThrowsError(try timings.measure("outer") {
            now += 0.5
            try timings.measure("inner") {
                now += 0.25
                timings.increment("attempts")
                timings.detail("complete", "false")
                throw Failure.expected
            }
        })
        timings.measure("cleanup") { now += 0.125 }
        let spans = timings.spans
        XCTAssertEqual(spans.map(\.name), ["command", "outer", "inner", "cleanup"])
        XCTAssertEqual(spans.map(\.parentID), [nil, 0, 1, 0])
        XCTAssertEqual(spans.map(\.startMS), [0, 0, 500, 750])
        XCTAssertEqual(spans.dropFirst().map(\.durationMS), [750, 250, 125])
        XCTAssertEqual(spans.map(\.threw), [false, true, true, false])
        XCTAssertEqual(spans[2].counters, ["attempts": 1])
        XCTAssertEqual(spans[2].details, ["complete": "false"])
        try timings.emit(command: "mic toggle", exitCode: 6) { text in
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(record["elapsed_ms"] as? Double, 875)
            now += 100
        }
        XCTAssertEqual(timings.spans[0].durationMS, 875)
    }

    func testDisabledRecorderExecutesBodyAndPreservesThrownError() {
        let timings: CommandTimings? = nil
        XCTAssertEqual(timings.measure("value") { 42 }, 42)
        XCTAssertThrowsError(try timings.measure("throw") { throw Failure.expected }) { error in
            XCTAssertTrue(error is Failure)
        }
        var recordedDurations: [Double] = []
        XCTAssertEqual(timings.measureAggregate("value", record: { recordedDurations.append($0) }) { 42 }, 42)
        XCTAssertThrowsError(try timings.measureAggregate("throw") { throw Failure.expected }) { error in
            XCTAssertTrue(error is Failure)
        }
        XCTAssertTrue(recordedDurations.isEmpty)
    }

    func testRepeatedMeasurementsAggregatePerParentIncludingFailedRequests() throws {
        var now: TimeInterval = 10
        let timings = CommandTimings(clock: { now })
        try timings.measure("first_scan") {
            for _ in 0..<100 {
                timings.measureAggregate("nodes") { now += 0.001 }
            }
            timings.measureAggregate("labels") { now += 0.002 }
            XCTAssertThrowsError(try timings.measureAggregate("nodes") {
                now += 0.003
                throw Failure.expected
            })
        }
        timings.measure("second_scan") {
            XCTAssertEqual(timings.measureAggregate("nodes") {
                now += 0.004
                return 42
            }, 42)
        }
        XCTAssertEqual(timings.spans.map(\.name), ["command", "first_scan", "second_scan"])
        XCTAssertTrue(timings.spans[0].aggregates.isEmpty)
        let first = try XCTUnwrap(timings.spans[1].aggregates["nodes"])
        XCTAssertEqual(first.count, 101)
        XCTAssertEqual(first.durationMS, 103, accuracy: 0.0001)
        let labels = try XCTUnwrap(timings.spans[1].aggregates["labels"])
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels.durationMS, 2, accuracy: 0.0001)
        let second = try XCTUnwrap(timings.spans[2].aggregates["nodes"])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.durationMS, 4, accuracy: 0.0001)
        try timings.emit(command: "mic toggle", exitCode: 0) { text in
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let spans = try XCTUnwrap(record["spans"] as? [[String: Any]])
            let aggregates = try XCTUnwrap(spans[1]["aggregates"] as? [String: [String: Any]])
            XCTAssertEqual(aggregates["nodes"]?["count"] as? Int, 101)
            XCTAssertEqual(try XCTUnwrap(aggregates["nodes"]?["duration_ms"] as? Double), 103, accuracy: 0.0001)
        }
    }

    func testBothToggleDirectionsKeepEventsReadsWaitsAndResultsUnchanged() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            for initial in [false, true] {
                let before = CommandFrame(active: initial)
                let after = CommandFrame(active: !initial)
                let baseline = try MediaCommandHarness([before, before, after, after])
                let instrumented = try MediaCommandHarness([before, before, after, after])
                let timings = CommandTimings(clock: { instrumented.accessibility.uptime })
                let expected = try command.run(baseline)
                let actual = try command.run(instrumented, timings: timings)
                assertSameResult(actual, expected)
                XCTAssertEqual(instrumented.lifecycle.events, baseline.lifecycle.events)
                XCTAssertEqual(instrumented.accessibility.reads.map(\.timeout), baseline.accessibility.reads.map(\.timeout))
                XCTAssertEqual(instrumented.accessibility.directReads, baseline.accessibility.directReads)
                XCTAssertEqual(instrumented.accessibility.pressed, baseline.accessibility.pressed)
                XCTAssertEqual(instrumented.waits, baseline.waits)
                instrumented.assertFinalized()
                let phases = timings.spans.filter { $0.name.hasSuffix("_observation") }
                XCTAssertEqual(phases.map(\.name), ["initial_observation", "preflight_observation",
                                                  "verification_observation", "verification_observation"])
                XCTAssertEqual(phases.map { $0.details["state"] }, [command.state(active: initial), command.state(active: initial),
                                                                   command.state(active: !initial), command.state(active: !initial)])
                XCTAssertEqual(timings.spans.filter { $0.name == "ax_press" }.count, 1)
                for wait in timings.spans.filter({ $0.name == "verification_wait" }) {
                    XCTAssertEqual(wait.durationMS, 50, accuracy: 0.0001)
                }
                for read in timings.spans.filter({ $0.name == "accessibility_read" }) {
                    XCTAssertEqual(read.details["complete"], "true")
                    XCTAssertTrue(phases.contains { $0.id == read.parentID })
                }
                try timings.emit(command: "toggle", exitCode: 0) { _ in
                    instrumented.lifecycle.assertUnlocked()
                    XCTAssertEqual(instrumented.lifecycle.events.last, "focus.stop")
                    XCTAssertEqual(timings.spans.suffix(3).map(\.name), ["focus_check", "focus_stop", "lock_release"])
                }
            }
        }
    }

    func testCameraTraceDistinguishesDesiredStateFromControlReadiness() throws {
        let before = CommandFrame(active: false)
        let after = CommandFrame(active: true)
        let harness = try MediaCommandHarness([before, before, CommandFrame(active: true, ready: false), after, after])
        let timings = CommandTimings(clock: { harness.accessibility.uptime })
        XCTAssertTrue(try CommandUnderTest.camera.run(harness, timings: timings).success)
        let verification = timings.spans.filter { $0.name == "verification_observation" }
        XCTAssertEqual(verification.map { $0.details["state"] }, ["on", "on", "on"])
        XCTAssertEqual(verification.map { $0.details["can_press"] }, ["false", "true", "true"])
        XCTAssertEqual(harness.waits, 3)
        harness.assertFinalized()
    }

    func testRefusalUncertaintyTimeoutAndCleanupFailurePreserveBehavior() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            for scenario in ["refusal", "uncertain", "timeout", "incomplete", "read_error", "cleanup", "no_op", "replacement", "focus"] {
                func makeHarness() throws -> MediaCommandHarness {
                    let before = CommandFrame(active: false)
                    let after = CommandFrame(active: true)
                    let frames: [CommandFrame]
                    switch scenario {
                    case "cleanup": frames = [before, before, after, after]
                    case "incomplete": frames = [before, before, CommandFrame(active: true, complete: false)]
                    case "no_op": frames = [before, after]
                    case "replacement": frames = [before, CommandFrame(active: false, window: 21)]
                    default: frames = [before]
                    }
                    let harness = try MediaCommandHarness(frames)
                    switch scenario {
                    case "refusal": harness.accessibility.sameProcess = false
                    case "uncertain": harness.accessibility.pressError = .cannotComplete
                    case "read_error": harness.accessibility.readErrors[3] = .accessibilityFailure(-25204)
                    case "cleanup": harness.lifecycle.client.waitResults = [.confirmed, .timedOut]
                    case "focus": harness.lifecycle.focus.result = false
                    default: break
                    }
                    return harness
                }
                let baseline = try makeHarness()
                let instrumented = try makeHarness()
                let timings = CommandTimings(clock: { instrumented.accessibility.uptime })
                let expected = try command.run(baseline)
                let actual = try command.run(instrumented, timings: timings)
                assertSameResult(actual, expected)
                XCTAssertEqual(instrumented.lifecycle.events, baseline.lifecycle.events, scenario)
                XCTAssertEqual(instrumented.accessibility.reads.map(\.timeout), baseline.accessibility.reads.map(\.timeout))
                XCTAssertEqual(instrumented.accessibility.pressed, baseline.accessibility.pressed)
                XCTAssertEqual(instrumented.waits, baseline.waits)
                XCTAssertEqual(timings.spans.last?.name, "lock_release")
                if scenario == "refusal" {
                    XCTAssertTrue(try XCTUnwrap(timings.spans.first { $0.name == "dispatch_validation" }).threw)
                    XCTAssertFalse(timings.spans.contains { $0.name == "ax_press" })
                }
                if scenario == "read_error" {
                    XCTAssertTrue(try XCTUnwrap(timings.spans.last { $0.name == "verification_observation" }).threw)
                }
                if scenario == "cleanup" { XCTAssertEqual(actual.reason, "accessibility_cleanup_failed") }
                instrumented.lifecycle.assertUnlocked()
            }
        }
    }

    func testEarlyThrowsCloseSpansAndStillFinalize() throws {
        for command in [CommandUnderTest.microphone, .camera] {
            for scenario in ["permission", "lock", "setup", "initial_read"] {
                let harness = try MediaCommandHarness([CommandFrame(active: false)])
                let timings = CommandTimings(clock: { harness.accessibility.uptime })
                var heldLock: MediaCommandLock?
                switch scenario {
                case "permission": harness.lifecycle.trusted = false
                case "lock": heldLock = try MediaCommandLock(path: harness.lifecycle.path)
                case "setup": harness.lifecycle.client.value = nil
                default: harness.accessibility.readErrors[1] = .accessibilityFailure(-25204)
                }
                XCTAssertThrowsError(try command.run(harness, timings: timings))
                if scenario == "permission" { XCTAssertEqual(timings.spans.count, 1) }
                if scenario == "lock" { XCTAssertEqual(timings.spans.last?.name, "lock_acquire") }
                if scenario == "setup" || scenario == "initial_read" {
                    XCTAssertEqual(timings.spans.last?.name, "lock_release")
                    XCTAssertEqual(harness.lifecycle.events.last, "focus.stop")
                }
                if scenario != "permission" { XCTAssertTrue(timings.spans.contains(where: \.threw)) }
                heldLock?.release()
                try timings.emit(command: "toggle", exitCode: 6) { _ in harness.lifecycle.assertUnlocked() }
            }
        }
    }

    private func assertSameResult(_ actual: CommandTestResult, _ expected: CommandTestResult,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.state, expected.state, file: file, line: line)
        XCTAssertEqual(actual.reason, expected.reason, file: file, line: line)
        XCTAssertEqual(actual.changed, expected.changed, file: file, line: line)
        XCTAssertEqual(actual.attempted, expected.attempted, file: file, line: line)
        XCTAssertEqual(actual.success, expected.success, file: file, line: line)
        XCTAssertEqual(actual.focus, expected.focus, file: file, line: line)
        XCTAssertEqual(actual.indices, expected.indices, file: file, line: line)
        XCTAssertEqual(actual.states, expected.states, file: file, line: line)
        XCTAssertEqual(actual.excluded, expected.excluded, file: file, line: line)
    }
}
