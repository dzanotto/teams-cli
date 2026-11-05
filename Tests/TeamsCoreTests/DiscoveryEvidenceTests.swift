import ApplicationServices
import XCTest
@testable import TeamsCore

final class DiscoveryEvidenceTests: XCTestCase {
    func testEvidenceAndAccessibilityReadsAreIdenticalWithAndWithoutTimings() throws {
        for mode in [TeamsAccessibilityReader.DiscoveryMode.normal, .full, .audit] {
            for scenario in ["separate", "conflicting", "required_failure", "recognition_failure", "empty"] {
                let context = "\(mode), \(scenario)"
                let baseline = tree(scenario)
                let recorded = tree(scenario)
                let timings = CommandTimings(clock: { recorded.now })
                let expected = try TeamsAccessibilityReader(environment: baseline.environment, mode: mode).readWithEvidence()
                let actual = try TeamsAccessibilityReader(environment: recorded.environment, timings: timings,
                                                          mode: mode).readWithEvidence()
                XCTAssertEqual(actual.scans, expected.scans, context)
                XCTAssertEqual(actual.snapshot.windows, expected.snapshot.windows, context)
                XCTAssertEqual(actual.snapshot.complete, expected.snapshot.complete, context)
                XCTAssertEqual(actual.snapshot.focusUnchanged, expected.snapshot.focusUnchanged, context)
                XCTAssertEqual(recorded.events, baseline.events, context)
                XCTAssertEqual(recorded.traversed, baseline.traversed, context)
                XCTAssertEqual(recorded.batchReads.map(\.names), baseline.batchReads.map(\.names), context)
                XCTAssertEqual(recorded.messagingTimeouts.map(\.seconds), baseline.messagingTimeouts.map(\.seconds), context)
                XCTAssertEqual(actual.scans, timingEvidence(timings), context)
            }
        }
    }

    func testAuditRetainsEarlierConflictsAndRecognitionFailuresAcrossRetry() throws {
        for scenario in ["conflicting", "recognition_failure", "unknown"] {
            for recordTimings in [false, true] {
                let stub = AccessibilityReaderStub()
                let profile = stub.button("idna-me-control-avatar-trigger")
                let search = stub.node("AXComboBox", attributes: ["AXDOMIdentifier": "ms-searchux-input"])
                var initial = [profile, search]
                if scenario == "conflicting" { initial.append(stub.button("video-button")) }
                if scenario == "recognition_failure" {
                    stub.values[search]?["AXDOMIdentifier"] = readerAXError(.cannotComplete)
                }
                if scenario == "unknown" { initial = [] }
                stub.window(initial)
                let finalMain = stub.node("AXWindow", children: [stub.button("idna-me-control-avatar-trigger"),
                    stub.node("AXComboBox", attributes: ["AXDOMIdentifier": "ms-searchux-input"])])
                let finalCall = stub.node("AXWindow", children: [stub.button()])
                stub.onSleep = { stub.values[stub.root]?[kAXWindowsAttribute] = [finalMain, finalCall] }
                let timings = recordTimings ? CommandTimings(clock: { stub.now }) : nil
                let result = try TeamsAccessibilityReader(environment: stub.environment, timings: timings,
                                                          mode: .audit).readWithEvidence()
                XCTAssertEqual(stub.sleeps, [0.25])
                XCTAssertEqual(result.scans.count, 2)
                XCTAssertTrue(result.scans.allSatisfy(\.complete))
                XCTAssertEqual(result.scans.map { $0.windows.map(\.window) }, [[1], [1, 2]])
                let initialRecognition: TeamsMainWindowRecognition.Result = scenario == "conflicting" ? .conflicting :
                    (scenario == "recognition_failure" ? .incomplete : .unknown)
                XCTAssertEqual(result.scans[0].windows[0].mainWindowRecognition, initialRecognition)
                XCTAssertEqual(result.scans[1].windows.map(\.mainWindowRecognition), [.mainShell, .callSurface])
                XCTAssertTrue(result.snapshot.complete)
                XCTAssertEqual(result.snapshot.handles[1]?.window, finalMain)
                XCTAssertEqual(result.snapshot.handles[2]?.window, finalCall)
                XCTAssertEqual(result.mainWindowAuditPassed, scenario == "unknown")
                if let timings { XCTAssertEqual(result.scans, timingEvidence(timings)) }
            }
        }
    }

    func testIncompleteScansCannotPassAuditWithoutTimingDiagnostics() throws {
        for scenario in ["required_failure", "recognition_failure", "deadline"] {
            let stub = tree(scenario)
            if scenario == "deadline" { stub.onBatchRead = { _, _ in stub.now += 1 } }
            let result = try TeamsAccessibilityReader(environment: stub.environment, mode: .audit)
                .readWithEvidence(timeout: 0.5)
            XCTAssertFalse(result.mainWindowAuditPassed, scenario)
            let scan = try XCTUnwrap(result.scans.last)
            XCTAssertEqual(scan.complete, result.snapshot.complete, scenario)
            XCTAssertTrue(scan.windows.contains { $0.mainWindowRecognition == .incomplete }, scenario)
            // Search identity is optional for control discovery, but required to qualify the layout.
            XCTAssertEqual(result.snapshot.complete, scenario == "recognition_failure", scenario)
        }
    }

    func testThrowingRetryRetainsBothTimingAttemptsWithoutReturningPartialEvidence() throws {
        let stub = AccessibilityReaderStub()
        stub.window([stub.button("idna-me-control-avatar-trigger"),
                     stub.node("AXComboBox", attributes: ["AXDOMIdentifier": "ms-searchux-input"])])
        stub.onSleep = { stub.singleErrors[stub.root] = .cannotComplete }
        let timings = CommandTimings(clock: { stub.now })
        XCTAssertThrowsError(try TeamsAccessibilityReader(environment: stub.environment, timings: timings,
                                                         mode: .audit).readWithEvidence()) { error in
            guard case TeamsReadError.accessibilityFailure(AXError.cannotComplete.rawValue) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
        XCTAssertTrue(discovery.threw)
        XCTAssertEqual(discovery.discoveryScans.count, 2)
        XCTAssertTrue(discovery.discoveryScans[0].complete)
        XCTAssertEqual(discovery.discoveryScans[0].windows[0].mainWindowRecognition, .mainShell)
        XCTAssertFalse(discovery.discoveryScans[1].complete)
        XCTAssertTrue(discovery.discoveryScans[1].windows.isEmpty)
    }

    func testTimingJSONKeepsItsExistingFlatWindowEvidenceFields() throws {
        let stub = tree("separate")
        let timings = CommandTimings(clock: { stub.now })
        _ = try TeamsAccessibilityReader(environment: stub.environment, timings: timings, mode: .audit).readWithEvidence()
        try timings.emit(command: "main-window-audit", exitCode: 0) { text in
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(record["schema_version"] as? Int, 1)
            let spans = try XCTUnwrap(record["spans"] as? [[String: Any]])
            let discovery = try XCTUnwrap(spans.first { $0["name"] as? String == "discovery" })
            let scans = try XCTUnwrap(discovery["discovery_scans"] as? [[String: Any]])
            XCTAssertEqual(Set(scans[0].keys), ["complete", "windows"])
            let windows = try XCTUnwrap(scans[0]["windows"] as? [[String: Any]])
            XCTAssertEqual(Set(windows[0].keys), ["window", "complete", "duration_ms", "visited_nodes", "aggregates",
                                                 "branches", "main_window_recognition", "excluded_main_window"])
            XCTAssertEqual(windows[0]["window"] as? Int, 1)
            XCTAssertEqual(windows[0]["complete"] as? Bool, true)
            XCTAssertEqual(windows[0]["main_window_recognition"] as? String, "main_shell")
            XCTAssertEqual(windows[0]["excluded_main_window"] as? Bool, false)
            XCTAssertFalse(text.contains("Private"))
        }
    }

    private func timingEvidence(_ timings: CommandTimings) -> [DiscoveryScanEvidence] {
        timings.spans.flatMap(\.discoveryScans).map { scan in
            DiscoveryScanEvidence(complete: scan.complete, windows: scan.windows.map { window in
                WindowDiscoveryEvidence(window: window.window, complete: window.complete,
                                        mainWindowRecognition: window.mainWindowRecognition,
                                        excludedMainWindow: window.excludedMainWindow)
            })
        }
    }

    private func tree(_ scenario: String) -> AccessibilityReaderStub {
        let stub = AccessibilityReaderStub()
        if scenario == "empty" { return stub }
        let profile = stub.button("idna-me-control-avatar-trigger")
        let search = stub.node("AXComboBox", attributes: ["AXDOMIdentifier": "ms-searchux-input"])
        var children = [profile, search, stub.node("AXStaticText", attributes: [kAXTitleAttribute: "Private title"])]
        if scenario == "conflicting" { children.append(stub.button("video-button", label: "Private label")) }
        if scenario == "required_failure" { stub.values[profile]?[kAXChildrenAttribute] = readerAXError(.cannotComplete) }
        if scenario == "recognition_failure" { stub.values[search]?["AXDOMIdentifier"] = readerAXError(.cannotComplete) }
        stub.window(children)
        stub.window([stub.button(), stub.button("hangup-button", label: "Leave")])
        return stub
    }
}
