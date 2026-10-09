import ApplicationServices
import XCTest
@testable import TeamsCore

final class TeamsMainWindowExclusionTests: XCTestCase {
    func testMediaReadsSkipRecognizedMainContentAndKeepCallHandlesAndWindowNumbers() throws {
        for control in [MediaControl.microphone, .camera] {
            let stub = AccessibilityReaderStub()
            let content = stub.node(children: (0..<500).map { _ in stub.node() })
            let main = mainWindow(stub, content: content)
            let microphone = stub.button()
            let camera = stub.button("video-button", label: "Turn camera off")
            let call = stub.window([microphone, camera, stub.button("hangup-button", label: "Leave")])
            let timings = CommandTimings(clock: { stub.now })
            let result = try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read(control: control)
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.focusUnchanged, true)
            XCTAssertEqual(result.windows.map(\.index), [1, 2])
            XCTAssertTrue(result.windows[0].controls.isEmpty)
            XCTAssertEqual(result.handles[1]?.window, main)
            XCTAssertEqual(result.handles[2]?.window, call)
            XCTAssertEqual(result.handles[2]?.microphones, [microphone])
            XCTAssertEqual(result.handles[2]?.cameras, [camera])
            XCTAssertFalse(stub.traversed.contains(content))
            let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
            XCTAssertEqual(discovery.counters["excluded_main_windows"], 1)
            let windows = try XCTUnwrap(discovery.discoveryScans.first?.windows)
            XCTAssertEqual(windows.map(\.excludedMainWindow), [true, false])
            XCTAssertEqual(windows.map(\.mainWindowRecognition), [.mainShell, .callSurface])
            XCTAssertEqual(windows[0].visitedNodes, 3)
            XCTAssertTrue(windows.allSatisfy(\.complete))
        }
    }

    func testMissingOrWrongRoleMarkersFallBackWithoutRestartingTheTraversal() throws {
        for missing in ["profile", "search", "profile_role", "search_role"] {
            let stub = AccessibilityReaderStub()
            let content = stub.node(children: [stub.button(), stub.button("hangup-button", label: "Leave")])
            let main = mainWindow(stub, content: content)
            let children = try XCTUnwrap(stub.values[main]?[kAXChildrenAttribute] as? [AXUIElement])
            let marker = children[missing.hasPrefix("profile") ? 0 : 1]
            if missing.hasSuffix("role") {
                stub.values[marker]?[kAXRoleAttribute] = "AXStaticText"
            } else {
                stub.values[marker]?["AXDOMIdentifier"] = nil
            }
            let result = try stub.read()
            XCTAssertTrue(result.complete, missing)
            XCTAssertTrue(stub.traversed.contains(content), missing)
            XCTAssertEqual(Set(stub.traversed).count, stub.traversed.count, missing)
            XCTAssertEqual(MicrophoneClassifier.assess(result.windows, complete: result.complete).state, .unmuted)
        }
    }

    func testMarkersFromDifferentWindowsCannotCombineIntoAnExclusion() throws {
        let stub = AccessibilityReaderStub()
        let firstContent = stub.node()
        let secondContent = stub.node()
        stub.window([stub.button("idna-me-control-avatar-trigger"), firstContent])
        stub.window([stub.node("AXComboBox", attributes: ["AXDOMIdentifier": "ms-searchux-input"]), secondContent])
        stub.window([stub.button(), stub.button("hangup-button", label: "Leave")])
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertTrue(stub.traversed.contains(firstContent))
        XCTAssertTrue(stub.traversed.contains(secondContent))
    }

    func testExclusionMatchesFullScanResultsForSeparateCallLayoutWithLessTraversal() throws {
        let stub = AccessibilityReaderStub()
        mainWindow(stub, content: stub.node(children: (0..<500).map { _ in stub.node() }))
        stub.window([stub.button(), stub.button("hangup-button", label: "Leave")])
        let expected = try TeamsAccessibilityReader(environment: stub.environment, excludeMainWindows: false).read()
        let fullCount = stub.traversed.count
        let actual = try stub.read()
        let fastCount = stub.traversed.count - fullCount
        XCTAssertEqual(actual.windows, expected.windows)
        XCTAssertEqual(actual.complete, expected.complete)
        XCTAssertEqual(actual.focusUnchanged, expected.focusUnchanged)
        XCTAssertEqual(actual.handles[2]?.microphones, expected.handles[2]?.microphones)
        XCTAssertEqual(fullCount - fastCount, 501)
    }

    func testAlreadyObservedCallOrHeldControlsPreventExclusion() throws {
        for identifier in ["microphone-button", "video-button", "hangup-button", "resume-button", "raisehands-button"] {
            let stub = AccessibilityReaderStub()
            let content = stub.node(children: [stub.button()])
            let main = mainWindow(stub, content: content)
            let children = try XCTUnwrap(stub.values[main]?[kAXChildrenAttribute] as? [AXUIElement])
            let callControl = stub.button(identifier)
            stub.values[main]?[kAXChildrenAttribute] = [callControl] + children
            let result = try stub.read()
            XCTAssertTrue(result.complete, identifier)
            XCTAssertTrue(stub.traversed.contains(content), identifier)
            XCTAssertEqual(Set(stub.traversed).count, stub.traversed.count)
        }
    }

    func testOptionalSearchReadFailureFallsBackWhileRequiredReadFailuresStayIncomplete() throws {
        for failure in ["search", "profile", "node"] {
            let stub = AccessibilityReaderStub()
            let content = stub.node(children: [stub.button()])
            let main = mainWindow(stub, content: content)
            let children = try XCTUnwrap(stub.values[main]?[kAXChildrenAttribute] as? [AXUIElement])
            let failedNode = failure == "search" ? children[1] : children[0]
            let attribute = failure == "node" ? kAXChildrenAttribute : "AXDOMIdentifier"
            stub.values[failedNode]?[attribute] = readerAXError(.cannotComplete)
            let result = try stub.read()
            XCTAssertEqual(result.complete, failure == "search", failure)
            XCTAssertTrue(stub.traversed.contains(content), failure)
        }
    }

    func testClassificationLimitsFallBackToFullDiscovery() throws {
        for limit in ["nodes", "depth"] {
            let stub = AccessibilityReaderStub()
            let content = stub.node(children: [stub.button()])
            let main = mainWindow(stub, content: content)
            let children = try XCTUnwrap(stub.values[main]?[kAXChildrenAttribute] as? [AXUIElement])
            if limit == "nodes" {
                let prefix = (0..<256).map { _ in stub.node() }
                stub.values[main]?[kAXChildrenAttribute] = prefix + children
            } else {
                var shell = stub.node(children: children)
                for _ in 0..<24 { shell = stub.node(children: [shell]) }
                stub.values[main]?[kAXChildrenAttribute] = [shell]
            }
            let result = try stub.read()
            XCTAssertTrue(result.complete, limit)
            XCTAssertTrue(stub.traversed.contains(content), limit)
        }
    }

    func testDeadlineDuringRecognitionCannotBecomeACompleteExclusion() throws {
        let stub = AccessibilityReaderStub()
        mainWindow(stub, content: stub.node())
        stub.onBatchRead = { element, names in
            if stub.values[element]?[kAXRoleAttribute] as? String == "AXComboBox" && names.contains("AXDOMIdentifier") {
                stub.now += 1
            }
        }
        let timings = CommandTimings(clock: { stub.now })
        let result = try TeamsAccessibilityReader(environment: stub.environment, timings: timings).read(timeout: 0.5)
        XCTAssertFalse(result.complete)
        let window = try XCTUnwrap(timings.spans.first { $0.name == "discovery" }?.discoveryScans.first?.windows.first)
        XCTAssertFalse(window.complete)
        XCTAssertFalse(window.excludedMainWindow)
        XCTAssertEqual(window.mainWindowRecognition, .incomplete)
        XCTAssertTrue(stub.sleeps.isEmpty)
    }

    func testHeldAndMultipleCallSelectionStillIncludesEverySeparateWindow() throws {
        for held in [false, true] {
            let stub = AccessibilityReaderStub()
            mainWindow(stub, content: stub.node())
            stub.window([stub.button(), stub.button("hangup-button", label: "Leave")])
            var other = [stub.button(), stub.button("hangup-button", label: "Leave")]
            if held { other.append(stub.button("resume-button", label: "Resume")) }
            stub.window(other)
            let snapshot = try stub.read()
            let result = MicrophoneClassifier.assess(snapshot.windows, complete: snapshot.complete)
            XCTAssertTrue(snapshot.complete)
            if held {
                XCTAssertEqual(result.state, .unmuted)
                XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 3, reason: "on_hold")])
            } else {
                XCTAssertEqual(result.reason, "multiple_call_windows")
            }
        }
    }

    func testEveryReadReclassifiesReorderedReplacedAndChangedWindows() throws {
        let stub = AccessibilityReaderStub()
        let main = mainWindow(stub, content: stub.node())
        let call = stub.window([stub.button(), stub.button("hangup-button", label: "Leave")])
        let reader = TeamsAccessibilityReader(environment: stub.environment)
        XCTAssertEqual(try reader.read().handles[2]?.window, call)
        stub.values[stub.root]?[kAXWindowsAttribute] = [call, main]
        XCTAssertEqual(try reader.read().handles[1]?.window, call)
        let replacement = stub.node("AXWindow", children: [stub.button(), stub.button("hangup-button", label: "Leave")])
        stub.values[stub.root]?[kAXWindowsAttribute] = [call, replacement]
        let replaced = try reader.read()
        XCTAssertEqual(replaced.handles[2]?.window, replacement)
        XCTAssertEqual(MicrophoneClassifier.assess(replaced.windows, complete: replaced.complete).reason, "multiple_call_windows")
        let changedControls = [stub.button(), stub.button("hangup-button", label: "Leave")]
        stub.values[main]?[kAXChildrenAttribute] = changedControls
        stub.values[stub.root]?[kAXWindowsAttribute] = [main]
        XCTAssertEqual(try reader.read().handles[1]?.microphones.count, 1)
    }

    func testRetryRechecksMarkersAndQueuedNodesAreNotDiscardedFromLaterWindows() throws {
        let stub = AccessibilityReaderStub()
        let microphone = stub.button()
        let main = mainWindow(stub, content: microphone)
        stub.onSleep = { stub.values[main]?[kAXChildrenAttribute] = [microphone] }
        let result = try stub.read()
        XCTAssertEqual(stub.sleeps, [0.25])
        XCTAssertEqual(result.handles[1]?.microphones, [microphone])

        let shared = AccessibilityReaderStub()
        let pending = shared.button()
        mainWindow(shared, content: pending)
        shared.window([pending, shared.button("hangup-button", label: "Leave")])
        XCTAssertEqual(try shared.read().handles[2]?.microphones, [pending])
    }

    func testHandCallAndExplicitFullScansDoNotApplyTheMediaExclusion() throws {
        for control in [MediaControl.microphone, .camera, .hand, .call] {
            let stub = AccessibilityReaderStub()
            let content = stub.node(children: [stub.button(control.rawValue)])
            mainWindow(stub, content: content)
            let reader = TeamsAccessibilityReader(environment: stub.environment,
                                                 excludeMainWindows: control == .hand || control == .call)
            let result = try reader.read(control: control)
            XCTAssertTrue(result.complete)
            XCTAssertTrue(stub.traversed.contains(content))
            XCTAssertEqual(result.handles[1]?.buttons(for: control).count, 1)
            XCTAssertFalse(stub.batchReads.contains { $0.names.contains("AXDOMIdentifier") &&
                stub.values[$0.element]?[kAXRoleAttribute] as? String == "AXComboBox" })
        }
    }

    func testAuditFindsCallControlsAfterTheMarkersAndDoesNotExposePrivateStrings() throws {
        let stub = AccessibilityReaderStub()
        let content = stub.node(children: [stub.button(label: "Private label"), stub.button("hangup-button", label: "Private meeting")])
        mainWindow(stub, content: content)
        let timings = CommandTimings(clock: { stub.now })
        let result = try TeamsAccessibilityReader(environment: stub.environment, timings: timings,
                                                 auditMainWindows: true).read()
        XCTAssertTrue(result.complete)
        XCTAssertTrue(stub.traversed.contains(content))
        let discovery = try XCTUnwrap(timings.spans.first { $0.name == "discovery" })
        let window = try XCTUnwrap(discovery.discoveryScans.first?.windows.first)
        XCTAssertEqual(window.mainWindowRecognition, .conflicting)
        XCTAssertFalse(window.excludedMainWindow)
        XCTAssertEqual(discovery.counters["excluded_main_windows"], 0)
        XCTAssertEqual(discovery.aggregates["main_window_identifiers"]?.count, 1)
        try timings.emit(command: "main-window-audit", exitCode: 0) { text in
            XCTAssertFalse(text.contains("Private"))
            XCTAssertFalse(text.contains("idna-me-control-avatar-trigger"))
            XCTAssertFalse(text.contains("ms-searchux-input"))
            XCTAssertTrue(text.contains("\"main_window_recognition\":\"conflicting\""))
        }
    }

    @discardableResult
    private func mainWindow(_ stub: AccessibilityReaderStub, content: AXUIElement) -> AXUIElement {
        let profile = stub.button("idna-me-control-avatar-trigger")
        let search = stub.node("AXComboBox", attributes: ["AXDOMIdentifier": "ms-searchux-input"])
        return stub.window([profile, search, content])
    }
}
