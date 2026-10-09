import ApplicationServices
import XCTest
@testable import TeamsCore

final class AccessibilityTimingsTests: XCTestCase {
    func testDiscoveryCountsNativeCallsWithoutRecordingLabelsOrChangingReads() throws {
        func makeStub() -> AccessibilityReaderStub {
            let stub = AccessibilityReaderStub()
            stub.window([stub.button(label: "Private title"), stub.button("hangup-button", label: "Private participant")])
            let helper = stub.node("AXApplication")
            stub.helpers = [stub.application(helper, executable: "Microsoft Teams WebView")]
            stub.onBatchRead = { _, _ in stub.now += 0.01 }
            return stub
        }
        let baseline = makeStub()
        let instrumented = makeStub()
        let timings = CommandTimings(clock: { instrumented.now })
        let expected = try baseline.read()
        let actual = try TeamsAccessibilityReader(environment: instrumented.environment, timings: timings).read()
        XCTAssertEqual(actual.windows, expected.windows)
        XCTAssertEqual(actual.complete, expected.complete)
        XCTAssertEqual(instrumented.events, baseline.events)
        XCTAssertEqual(instrumented.singleReads.map(\.name), baseline.singleReads.map(\.name))
        XCTAssertEqual(instrumented.batchReads.map(\.names), baseline.batchReads.map(\.names))
        XCTAssertEqual(instrumented.messagingTimeouts.map(\.seconds), baseline.messagingTimeouts.map(\.seconds))
        let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
        XCTAssertEqual(discovery.counters, ["visited_nodes": 3, "attribute_calls": 9,
                                            "batch_attribute_calls": 7, "scan_attempts": 1])
        XCTAssertEqual(discovery.details["complete"], "true")
        XCTAssertEqual(discovery.durationMS, 70, accuracy: 0.0001)
        XCTAssertEqual(timings.spans.filter { $0.name == "reader_focus_check" }.count, 2)
        try timings.emit(command: "mic toggle", exitCode: 0) { text in
            XCTAssertFalse(text.contains("Private"))
            XCTAssertFalse(text.contains("AXDOMIdentifier"))
            XCTAssertFalse(text.contains("Microsoft Teams WebView"))
        }
    }

    func testRetryWaitAndBothScansAreIncludedInSameDiscovery() throws {
        let stub = AccessibilityReaderStub()
        stub.window()
        let timings = CommandTimings(clock: { stub.now })
        let snapshot = try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read()
        XCTAssertTrue(snapshot.complete)
        let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
        XCTAssertEqual(discovery.counters, ["visited_nodes": 2, "attribute_calls": 4,
                                            "batch_attribute_calls": 2, "scan_attempts": 2])
        let wait = try XCTUnwrap(timings.spans.first { $0.name == "discovery_retry_wait" })
        XCTAssertEqual(wait.parentID, discovery.id)
        XCTAssertEqual(wait.durationMS, 250)
        XCTAssertEqual(discovery.durationMS, 250)
        XCTAssertEqual(stub.sleeps, [0.25])
    }

    func testIncompleteAndThrowingDiscoveryRetainPartialCounters() throws {
        for throwing in [false, true] {
            let stub = AccessibilityReaderStub()
            stub.window([stub.button()])
            if throwing { stub.singleErrors[stub.root] = .cannotComplete }
            else { stub.batchOverride = { _, _ in (nil, .cannotComplete) } }
            let timings = CommandTimings(clock: { stub.now })
            let reader = TeamsAccessibilityReader(environment: stub.environment, timings: timings)
            if throwing { XCTAssertThrowsError(try reader.read()) }
            else { XCTAssertFalse(try reader.read().complete) }
            let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
            XCTAssertEqual(discovery.threw, throwing)
            XCTAssertEqual(discovery.counters["scan_attempts"], 1)
            XCTAssertEqual(discovery.counters["visited_nodes"], throwing ? 0 : 1)
            XCTAssertEqual(discovery.counters["attribute_calls"], throwing ? 1 : 2)
            XCTAssertEqual(discovery.details["complete"], throwing ? nil : "false")
        }
    }
}
