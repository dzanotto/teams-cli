import ApplicationServices
import XCTest
@testable import TeamsCore

final class AccessibilityDiscoveryTimingsTests: XCTestCase {
    func testWindowAndExclusiveBranchCostsPreserveReadsAcrossWrapperChainsAndNestedForks() throws {
        func makeStub() -> AccessibilityReaderStub {
            let stub = AccessibilityReaderStub()
            let thirdFork = stub.node(children: [stub.node("AXStaticText"), stub.node("AXStaticText")])
            let secondFork = stub.node(children: [thirdFork, stub.node("AXStaticText")])
            let sidebar = stub.node(children: [secondFork])
            let firstFork = stub.node(children: [sidebar, stub.node("AXImage")])
            stub.window([stub.node("AXWebArea", children: [firstFork])])
            stub.window([stub.button(), stub.button("hangup-button", label: "Leave")])
            stub.onBatchRead = { _, names in
                stub.now += names.contains(kAXChildrenAttribute) ? 0.001 : names.contains("AXDOMIdentifier") ? 0.002 : 0.003
            }
            return stub
        }
        let baseline = makeStub()
        let recorded = makeStub()
        let timings = CommandTimings(clock: { recorded.now })
        let expected = try baseline.read()
        let actual = try TeamsAccessibilityReader(environment: recorded.environment, timings: timings).read()
        XCTAssertEqual(actual.windows, expected.windows)
        XCTAssertEqual(actual.complete, expected.complete)
        XCTAssertEqual(actual.focusUnchanged, expected.focusUnchanged)
        XCTAssertEqual(recorded.events, baseline.events)
        XCTAssertEqual(recorded.batchReads.map(\.names), baseline.batchReads.map(\.names))
        XCTAssertEqual(recorded.traversed, baseline.traversed)
        XCTAssertEqual(recorded.messagingTimeouts.map(\.seconds), baseline.messagingTimeouts.map(\.seconds))

        let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
        let scan = try XCTUnwrap(discovery.discoveryScans.first)
        XCTAssertTrue(scan.complete)
        XCTAssertEqual(scan.windows.map(\.window), [1, 2])
        XCTAssertEqual(scan.windows.map(\.visitedNodes), [10, 3])
        XCTAssertTrue(scan.windows.allSatisfy(\.complete))
        XCTAssertEqual(scan.windows[0].durationMS, 10, accuracy: 0.0001)
        XCTAssertEqual(scan.windows[1].durationMS, 13, accuracy: 0.0001)
        let branches = scan.windows[0].branches
        XCTAssertEqual(branches.map(\.parentID), [nil, 0, 0, 1, 1])
        XCTAssertEqual(branches.map(\.rootDepth), [0, 3, 3, 5, 5])
        XCTAssertEqual(branches.map(\.visitedNodes), [3, 2, 1, 3, 1])
        XCTAssertEqual(branches[3].maxDepth, 6)
        XCTAssertEqual(branches[3].rootRole, "AXGroup")
        XCTAssertEqual(branches[3].roles, ["AXGroup": 1, "AXStaticText": 2])
        XCTAssertEqual(scan.windows[1].branches[1].controls, ["microphone-button": 1])
        XCTAssertEqual(scan.windows[1].branches[2].controls, ["hangup-button": 1])
        XCTAssertEqual(discovery.counters["visited_nodes"], scan.windows.reduce(0) { $0 + $1.visitedNodes })
        for (group, aggregate) in discovery.aggregates {
            XCTAssertEqual(aggregate.count, scan.windows.reduce(0) { $0 + ($1.aggregates[group]?.count ?? 0) })
            XCTAssertEqual(aggregate.durationMS,
                           scan.windows.reduce(0) { $0 + ($1.aggregates[group]?.durationMS ?? 0) }, accuracy: 0.0001)
        }
        for window in scan.windows { assertBranchTotals(window) }
    }

    func testOverflowCapsMetadataWithoutSkippingNodesOrRecordingPrivateStrings() throws {
        let stub = AccessibilityReaderStub()
        let children = (0..<100).map { _ in stub.node("Private role", attributes: [kAXTitleAttribute: "Private title"]) }
        stub.window(children + [stub.button(label: "Private microphone"), stub.button("hangup-button", label: "Private name")])
        let timings = CommandTimings(clock: { stub.now })
        let snapshot = try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read()
        let window = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans.first?.windows.first)
        XCTAssertTrue(snapshot.complete)
        XCTAssertTrue(window.complete)
        XCTAssertEqual(window.visitedNodes, 103)
        XCTAssertEqual(stub.traversed.count, 103)
        XCTAssertEqual(window.branches.count, 64)
        let overflow = try XCTUnwrap(window.branches.last)
        XCTAssertTrue(overflow.overflow)
        XCTAssertNil(overflow.parentID)
        XCTAssertNil(overflow.rootDepth)
        XCTAssertNil(overflow.rootRole)
        XCTAssertEqual(overflow.visitedNodes, 40)
        XCTAssertEqual(overflow.controls, ["microphone-button": 1, "hangup-button": 1])
        XCTAssertEqual(window.branches[1].rootRole, "other")
        assertBranchTotals(window)
        try timings.emit(command: "mic toggle", exitCode: 0) { text in
            XCTAssertFalse(text.contains("Private"))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let spans = try XCTUnwrap(record["spans"] as? [[String: Any]])
            let discovery = try XCTUnwrap(spans.first { $0["name"] as? String == "discovery" })
            let scans = try XCTUnwrap(discovery["discovery_scans"] as? [[String: Any]])
            let windows = try XCTUnwrap(scans[0]["windows"] as? [[String: Any]])
            XCTAssertEqual(windows[0]["visited_nodes"] as? Int, 103)
            let branches = try XCTUnwrap(windows[0]["branches"] as? [[String: Any]])
            XCTAssertEqual(branches.last?["overflow"] as? Bool, true)
        }
    }

    func testSharedNodesAndCyclesAreAttributedOnceToFirstScheduledBranch() throws {
        let stub = AccessibilityReaderStub()
        let button = stub.button()
        let first = stub.node(children: [button])
        let second = stub.node(children: [button])
        let root = stub.window([first, second])
        stub.values[button]?[kAXChildrenAttribute] = [root]
        let timings = CommandTimings(clock: { stub.now })
        XCTAssertTrue(try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read().complete)
        let window = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans.first?.windows.first)
        XCTAssertEqual(window.visitedNodes, 4)
        XCTAssertEqual(window.branches.map(\.visitedNodes), [1, 2, 1])
        XCTAssertEqual(window.branches[1].controls, ["microphone-button": 1])
        XCTAssertTrue(window.branches[2].controls.isEmpty)
        assertBranchTotals(window)
    }

    func testRetryKeepsSeparateProfilesAndFreshLocalWindowNumbers() throws {
        let stub = AccessibilityReaderStub()
        stub.window()
        let replacement = stub.node("AXWindow", children: [stub.button()])
        stub.onSleep = { stub.values[stub.root]?[kAXWindowsAttribute] = [replacement] }
        let timings = CommandTimings(clock: { stub.now })
        XCTAssertTrue(try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read().complete)
        let scans = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans)
        XCTAssertEqual(scans.count, 2)
        XCTAssertTrue(scans.allSatisfy(\.complete))
        XCTAssertEqual(scans.map { $0.windows[0].window }, [1, 1])
        XCTAssertEqual(scans.map { $0.windows[0].visitedNodes }, [1, 2])
        XCTAssertEqual(scans[1].windows[0].branches[0].controls, ["microphone-button": 1])
        XCTAssertEqual(stub.sleeps, [0.25])
    }

    func testDeadlineKeepsPartialWindowProfilesAndDoesNotChangeReadSequence() throws {
        func makeStub() -> AccessibilityReaderStub {
            let stub = AccessibilityReaderStub()
            stub.window([stub.button(), stub.node()])
            stub.window([stub.button()])
            stub.onBatchRead = { _, _ in stub.now += 0.6 }
            return stub
        }
        let baseline = makeStub()
        let recorded = makeStub()
        let timings = CommandTimings(clock: { recorded.now })
        let expected = try baseline.read(timeout: 1)
        let actual = try TeamsAccessibilityReader(environment: recorded.environment, timings: timings).read(timeout: 1)
        XCTAssertEqual(actual.windows, expected.windows)
        XCTAssertEqual(actual.complete, expected.complete)
        XCTAssertEqual(recorded.events, baseline.events)
        XCTAssertEqual(recorded.traversed, baseline.traversed)
        let scan = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans.first)
        XCTAssertFalse(scan.complete)
        XCTAssertEqual(scan.windows.map(\.complete), [false, false])
        XCTAssertEqual(scan.windows.map(\.visitedNodes), [2, 0])
        XCTAssertEqual(scan.windows[0].durationMS, 2_400, accuracy: 0.0001)
        XCTAssertEqual(scan.windows[1].durationMS, 0)
    }

    func testFailedAttributesMarkTheirWindowIncompleteAndRetainRequestCosts() throws {
        for attribute in [kAXRoleAttribute, kAXChildrenAttribute, kAXIdentifierAttribute, kAXHelpAttribute] {
            let stub = AccessibilityReaderStub()
            let button = stub.button()
            stub.values[button]?[attribute] = readerAXError(.cannotComplete)
            stub.window([button])
            stub.onBatchRead = { _, _ in stub.now += 0.001 }
            let timings = CommandTimings(clock: { stub.now })
            XCTAssertFalse(try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read().complete)
            let scan = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans.first)
            XCTAssertFalse(scan.complete)
            XCTAssertFalse(scan.windows[0].complete)
            if attribute == kAXRoleAttribute {
                XCTAssertEqual(scan.windows[0].branches[0].roles["unavailable"], 1)
            }
            assertBranchTotals(scan.windows[0])
        }
    }

    func testLaterApplicationFailureRetainsTheCompletedWindowButMarksScanIncomplete() throws {
        let stub = AccessibilityReaderStub()
        stub.window([stub.button()])
        let other = stub.node("AXApplication")
        stub.applications.append(stub.application(other))
        stub.singleErrors[other] = .cannotComplete
        let timings = CommandTimings(clock: { stub.now })
        XCTAssertThrowsError(try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read())
        let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
        let scan = try XCTUnwrap(discovery.discoveryScans.first)
        XCTAssertTrue(discovery.threw)
        XCTAssertFalse(scan.complete)
        XCTAssertEqual(scan.windows.count, 1)
        XCTAssertTrue(scan.windows[0].complete)
        XCTAssertEqual(scan.windows[0].visitedNodes, 2)
    }

    func testNodeAndDepthLimitsRemainIncompleteWithProfilingEnabled() throws {
        for limit in ["nodes", "depth"] {
            let stub = AccessibilityReaderStub()
            if limit == "nodes" {
                stub.window((0..<12_000).map { _ in stub.node() })
                stub.window()
            } else {
                var child = stub.button()
                for _ in 0..<81 { child = stub.node(children: [child]) }
                stub.window([child])
            }
            let timings = CommandTimings(clock: { stub.now })
            XCTAssertFalse(try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read().complete)
            let scan = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans.first)
            XCTAssertFalse(scan.complete)
            XCTAssertTrue(scan.windows.allSatisfy { !$0.complete })
            XCTAssertEqual(scan.windows[0].visitedNodes, limit == "nodes" ? 12_000 : 81)
            for window in scan.windows { assertBranchTotals(window) }
        }
    }

    func testHandImageRequestsAreIncludedWithoutRecordingImageDescriptions() throws {
        let stub = AccessibilityReaderStub()
        let image = stub.node("AXImage", attributes: [kAXDescriptionAttribute: "Myself video, Private user"])
        stub.window([stub.button("raisehands-button"), image])
        stub.onBatchRead = { _, _ in stub.now += 0.001 }
        let timings = CommandTimings(clock: { stub.now })
        XCTAssertTrue(try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read(control: .hand).complete)
        let window = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans.first?.windows.first)
        XCTAssertEqual(window.branches[2].aggregates["image_labels"]?.count, 1)
        XCTAssertEqual(try XCTUnwrap(window.aggregates["image_labels"]?.durationMS), 1, accuracy: 0.0001)
        assertBranchTotals(window)
        try timings.emit(command: "test", exitCode: 0) { XCTAssertFalse($0.contains("Private")) }
    }

    private func assertBranchTotals(_ window: AccessibilityDiscoveryTimings.Window,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.visitedNodes, window.branches.reduce(0) { $0 + $1.visitedNodes }, file: file, line: line)
        for (group, aggregate) in window.aggregates {
            XCTAssertEqual(aggregate.count, window.branches.reduce(0) { $0 + ($1.aggregates[group]?.count ?? 0) },
                           file: file, line: line)
            XCTAssertEqual(aggregate.durationMS,
                           window.branches.reduce(0) { $0 + ($1.aggregates[group]?.durationMS ?? 0) },
                           accuracy: 0.0001, file: file, line: line)
        }
    }
}
